import Base
import ./http.bend as H
import ./h2.bend as T
import ./sys.bend as Y

# HTTP/2 over a socket
# ====================
#
# Drives h2.bend's state machine over a connection (TCP or Unix, plain
# h2c). Each connection runs three computations: a reader, which owns
# one handle on the socket and passes what it reads to the manager; a
# writer, which owns a second handle (Sys.dup) and writes what the
# manager hands it; and the manager, which owns the connection's state
# and hears, on one channel (its inbox), both the reader's bytes and the
# application's requests. So nothing waits on two things at once, and a
# slow peer never stops the manager from reading.
#
# The application talks to a connection through its inbox:
#   MOpen: (a client) opens a stream; its events go to back, the first
#          SOpened{sid} (or SGone when no stream can open)
#   MSend: queues headers or data on a stream
#   MReset: resets a stream
#   MClose: ends the connection (GOAWAY, NO_ERROR)
# and hears each stream's events on that stream's channel: SGot{ev} for
# its headers, data and reset, SGone when the connection ends. A server
# hands each new stream to the application as an H2Req on its requests
# channel.

type SEv is Data:
  SOpened{sid: U32}
  SGot{ev: T.H2Ev}
  SGone{why: String}

type H2Msg is Data:
  MIn{bs: List<&2, U32>}
  MEof{}
  MOpen{hs: List<&2, H.Header>, end: Bool, back: Chan(SEv)}
  MSend{sid: U32, ch: T.Chunk}
  MReset{sid: U32, code: U32}
  MClose{}

# A stream a client opened on a server: its id, its events (the request's
# headers first), and the connection to answer on.
type H2Req is Data:
  H2Req{sid: U32, evs: Chan(SEv), conn: Chan(H2Msg)}

type Route is Data:
  Route{sid: U32, ch: Chan(SEv)}

# Each loop runs on two counters of fuel: 2^64 turns.
def H2io.fuel() -> Nat:
  4294967295n

# The reader
# ----------

type REv is Type:
  REv{s: Socket, r: Result<&1, &1, U32 & String, Maybe<&1, List<&2, U32>>>}

def REv.of(p: Socket & Result<&1, &1, U32 & String, Maybe<&1, List<&2, U32>>>) -> REv:
  match p:
    case (s, r):
      REv{s, r}

def H2io.reader(outer: Nat, fuel: Nat, ev: REv, +inbox: Chan(H2Msg)) -> IO(Unit):
  match outer fuel ev:
    case 0n 0n REv{s, r}:
      Socket.close(s)
    case 1n+o 0n e:
      H2io.reader(o, H2io.fuel(), e, inbox)
    case o 1n+f REv{s, Done{Some{bs}}}:
      do IO<Unit>:
        sent : Result<&1, &1, H2Msg, Unit> <- Chan.send(H2Msg, inbox, MIn{bs})
        p : Socket & Result<&1, &1, U32 & String, Maybe<&1, List<&2, U32>>> <- TCP.recv_bytes(s, 65536)
        H2io.reader(o, f, REv.of(p), inbox)
    case o 1n+f REv{s, r}:
      do IO<Unit>:
        sent : Result<&1, &1, H2Msg, Unit> <- Chan.send(H2Msg, inbox, MEof{})
        Socket.close(s)

# Reads s until it ends, passing each read to inbox, then MEof.
def H2io.read(s: Socket, +inbox: Chan(H2Msg)) -> IO(Unit):
  do IO<Unit>:
    p : Socket & Result<&1, &1, U32 & String, Maybe<&1, List<&2, U32>>> <- TCP.recv_bytes(s, 65536)
    H2io.reader(H2io.fuel(), H2io.fuel(), REv.of(p), inbox)

# The writer
# ----------

type WEv is Type:
  WGot{s: Socket, m: Maybe<&1, List<&2, U32>>}
  WSent{s: Socket, r: Result<&1, &1, (U32 & String) & List<&2, U32>, Unit>}

def WEv.sent(p: Socket & Result<&1, &1, (U32 & String) & List<&2, U32>, Unit>) -> WEv:
  match p:
    case (s, r):
      WSent{s, r}

def H2io.hang_up(s: Socket) -> IO(Unit):
  do IO<Unit>:
    s2 : Socket <- Y.Sys.shutdown(s)
    Socket.close(s2)

def H2io.writer(outer: Nat, fuel: Nat, ev: WEv, +wr: Chan(List<&2, U32>)) -> IO(Unit):
  match outer fuel ev:
    case 0n 0n WGot{s, m}:
      H2io.hang_up(s)
    case 0n 0n WSent{s, r}:
      H2io.hang_up(s)
    case 1n+o 0n e:
      H2io.writer(o, H2io.fuel(), e, wr)
    case o 1n+f WGot{s, None{}}:
      H2io.hang_up(s)
    case o 1n+f WGot{s, Some{bs}}:
      do IO<Unit>:
        p : Socket & Result<&1, &1, (U32 & String) & List<&2, U32>, Unit> <- TCP.send_bytes(s, bs)
        H2io.writer(o, f, WEv.sent(p), wr)
    case o 1n+f WSent{s, Done{u}}:
      do IO<Unit>:
        m : Maybe<&1, List<&2, U32>> <- Chan.recv(List<&2, U32>, wr)
        H2io.writer(o, f, WGot{s, m}, wr)
    case o 1n+f WSent{s, Fail{e}}:
      # the peer is gone: no more writes, and the reader hears the end
      do IO<Unit>:
        Chan.close(List<&2, U32>, wr)
        H2io.hang_up(s)

# Writes what wr carries to s, until wr closes; then hangs up.
def H2io.write(s: Socket, +wr: Chan(List<&2, U32>)) -> IO(Unit):
  do IO<Unit>:
    m : Maybe<&1, List<&2, U32>> <- Chan.recv(List<&2, U32>, wr)
    H2io.writer(H2io.fuel(), H2io.fuel(), WGot{s, m}, wr)

# The manager
# -----------

type Applied is Data:
  Applied{c: T.H2, routes: List<&2, Route>, closing: Bool}

def H2io.route.pick(+ch: Chan(SEv), rest: Maybe<&2, Chan(SEv)>, hit: Bool) -> Maybe<&2, Chan(SEv)>:
  match hit:
    case True{}:
      Some{ch}
    case False{}:
      rest

def H2io.route(rs: List<&2, Route>, +sid: U32) -> Maybe<&2, Chan(SEv)>:
  match rs:
    case Nil{}:
      None{}
    case Con{Route{+id, +ch}, t}:
      H2io.route.pick(ch, H2io.route(t, sid), U32.is_eq(id, sid))

def H2io.unroute.pick(r: Route, rest: List<&2, Route>, hit: Bool) -> List<&2, Route>:
  match hit:
    case True{}:
      rest
    case False{}:
      Con{r, rest}

def H2io.unroute(rs: List<&2, Route>, +sid: U32) -> List<&2, Route>:
  match rs:
    case Nil{}:
      Nil{}
    case Con{Route{+id, ch}, t}:
      H2io.unroute.pick(Route{id, ch}, H2io.unroute(t, sid), U32.is_eq(id, sid))

def H2io.tell(+ch: Chan(SEv), e: SEv) -> IO(Unit):
  do IO<Unit>:
    r : Result<&1, &1, SEv, Unit> <- Chan.send(SEv, ch, e)
    return Unit{}

def H2io.tell_all(rs: List<&2, Route>, +e: SEv) -> IO(Unit):
  match rs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{Route{id, ch}, t}:
      do IO<Unit>:
        H2io.tell(ch, e)
        H2io.tell_all(t, e)

def H2io.keep(rs: List<&2, Route>, +sid: U32, done: Bool) -> List<&2, Route>:
  match done:
    case True{}:
      H2io.unroute(rs, sid)
    case False{}:
      rs

# A new stream from the peer: its channel, handed to the application.
def H2io.accept(q: Maybe<&2, Chan(H2Req)>, +sid: U32, e: SEv, done: Bool, rs: List<&2, Route>,
  +inbox: Chan(H2Msg)) -> IO(List<&2, Route>):
  match q:
    case None{}:
      IO.pure(List<&2, Route>, rs)
    case Some{+reqs}:
      do IO<List<&2, Route>>:
        +ch : Chan(SEv) <- Chan.new(SEv, 256)
        r : Result<&1, &1, H2Req, Unit> <- Chan.send(H2Req, reqs, H2Req{sid, ch, inbox})
        H2io.tell(ch, e)
        return H2io.keep(Con{Route{sid, ch}, rs}, sid, done)

def H2io.to(m: Maybe<&2, Chan(SEv)>, +sid: U32, e: SEv, +done: Bool, rs: List<&2, Route>, +inbox: Chan(H2Msg),
  q: Maybe<&2, Chan(H2Req)>, fresh: Bool) -> IO(List<&2, Route>):
  match m fresh:
    case Some{ch} x:
      do IO<List<&2, Route>>:
        H2io.tell(ch, e)
        return H2io.keep(rs, sid, done)
    case None{} True{}:
      H2io.accept(q, sid, e, done, rs, inbox)
    case None{} False{}:
      IO.pure(List<&2, Route>, rs)

# One event of the connection, to its stream's channel; a server's new
# stream goes to the application first.
def H2io.deliver1(e: T.H2Ev, +rs: List<&2, Route>, +inbox: Chan(H2Msg), q: Maybe<&2, Chan(H2Req)>) ->
  IO(List<&2, Route>):
  match e:
    case T.EvHeaders{+sid, hs, +end}:
      H2io.to(H2io.route(rs, sid), sid, SGot{T.EvHeaders{sid, hs, end}}, end, rs, inbox, q, True{})
    case T.EvData{+sid, bs, +end}:
      H2io.to(H2io.route(rs, sid), sid, SGot{T.EvData{sid, bs, end}}, end, rs, inbox, q, False{})
    case T.EvRst{+sid, code}:
      H2io.to(H2io.route(rs, sid), sid, SGot{T.EvRst{sid, code}}, True{}, rs, inbox, q, False{})
    case T.EvGoaway{last, code}:
      do IO<List<&2, Route>>:
        H2io.tell_all(rs, SGot{T.EvGoaway{last, code}})
        return rs
    case T.EvFatal{code, why}:
      do IO<List<&2, Route>>:
        H2io.tell_all(rs, SGone{why})
        return Nil{}

def H2io.deliver(evs: List<&2, T.H2Ev>, rs: List<&2, Route>, +inbox: Chan(H2Msg), +q: Maybe<&2, Chan(H2Req)>) ->
  IO(List<&2, Route>):
  match evs:
    case Nil{}:
      IO.pure(List<&2, Route>, rs)
    case Con{e, t}:
      IO.bind(List<&2, Route>, List<&2, Route>, H2io.deliver1(e, rs, inbox, q), rs2 => H2io.deliver(t, rs2, inbox, q))

def H2io.send_out(bs: List<&2, U32>, +wr: Chan(List<&2, U32>), empty: Bool) -> IO(Unit):
  match empty:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      do IO<Unit>:
        r : Result<&1, &1, List<&2, U32>, Unit> <- Chan.send(List<&2, U32>, wr, bs)
        return Unit{}

def H2io.start_close(+wr: Chan(List<&2, U32>), now: Bool) -> IO(Unit):
  match now:
    case True{}:
      Chan.close(List<&2, U32>, wr)
    case False{}:
      IO.pure(Unit, Unit{})

# After a message: the bytes to the writer, the events to their streams,
# and, once the connection is over, the writer closed (it hangs up after
# the last bytes, which ends the reader, whose MEof ends the manager).
def H2io.flush.go(t: T.H2Take, rs: List<&2, Route>, +cl: Bool, +wr: Chan(List<&2, U32>), +inbox: Chan(H2Msg),
  +q: Maybe<&2, Chan(H2Req)>) -> IO(Applied):
  match t:
    case T.H2Take{+c, +bs, evs}:
      do IO<Applied>:
        H2io.send_out(bs, wr, List.is_empty(&2, U32, bs))
        rs2 : List<&2, Route> <- H2io.deliver(evs, rs, inbox, q)
        H2io.start_close(wr, T.H2.over(c) && Bool.not(cl))
        return Applied{c, rs2, cl || T.H2.over(c)}

def H2io.flush(a: Applied, +wr: Chan(List<&2, U32>), +inbox: Chan(H2Msg), +q: Maybe<&2, Chan(H2Req)>) -> IO(Applied):
  match a:
    case Applied{c, rs, cl}:
      H2io.flush.go(T.H2.take(c), rs, cl, wr, inbox, q)

def H2io.opened.go(c: T.H2, +sid: U32, rs: List<&2, Route>, cl: Bool, +back: Chan(SEv), none: Bool) -> IO(Applied):
      match none:
        case True{}:
          do IO<Applied>:
            H2io.tell(back, SGone{"the connection takes no new streams"})
            return Applied{c, rs, cl}
        case False{}:
          do IO<Applied>:
            H2io.tell(back, SOpened{sid})
            return Applied{c, Con{Route{sid, back}, rs}, cl}

def H2io.opened(o: T.H2Opened, rs: List<&2, Route>, cl: Bool, +back: Chan(SEv)) -> IO(Applied):
  match o:
    case T.H2Opened{c, +sid}:
      H2io.opened.go(c, sid, rs, cl, back, U32.is_zero(sid))

# One message to the connection.
def H2io.apply(c: T.H2, rs: List<&2, Route>, cl: Bool, m: H2Msg) -> IO(Applied):
  match m:
    case MIn{bs}:
      IO.pure(Applied, Applied{T.H2.feed(c, bs), rs, cl})
    case MEof{}:
      IO.pure(Applied, Applied{c, rs, cl})
    case MOpen{hs, end, back}:
      H2io.opened(T.H2.open(c, hs, end), rs, cl, back)
    case MSend{sid, ch}:
      IO.pure(Applied, Applied{T.H2.send(c, sid, ch), rs, cl})
    case MReset{+sid, code}:
      IO.pure(Applied, Applied{T.H2.reset(c, sid, code), H2io.unroute(rs, sid), cl})
    case MClose{}:
      IO.pure(Applied, Applied{T.H2.close(c, T.H2.no_error()), rs, cl})

type MEv is Type:
  MEv{a: Applied, m: Maybe<&1, H2Msg>}

def MEv.of(a: Applied, m: Maybe<&1, H2Msg>) -> MEv:
  MEv{a, m}

# The connection ended: every stream hears it, and the channels close.
def H2io.end(rs: List<&2, Route>, +wr: Chan(List<&2, U32>), +inbox: Chan(H2Msg), cl: Bool) -> IO(Unit):
  do IO<Unit>:
    H2io.tell_all(rs, SGone{"the connection ended"})
    H2io.start_close(wr, Bool.not(cl))
    Chan.close(H2Msg, inbox)

def H2io.mgr(outer: Nat, fuel: Nat, ev: MEv, +inbox: Chan(H2Msg), +wr: Chan(List<&2, U32>),
  +q: Maybe<&2, Chan(H2Req)>) -> IO(Unit):
  match outer fuel ev:
    case 0n 0n MEv{Applied{c, rs, cl}, m}:
      H2io.end(rs, wr, inbox, cl)
    case 1n+o 0n e:
      H2io.mgr(o, H2io.fuel(), e, inbox, wr, q)
    case o 1n+f MEv{Applied{c, rs, cl}, None{}}:
      H2io.end(rs, wr, inbox, cl)
    case o 1n+f MEv{Applied{c, rs, cl}, Some{MEof{}}}:
      H2io.end(rs, wr, inbox, cl)
    case o 1n+f MEv{Applied{c, rs, cl}, Some{msg}}:
      do IO<Unit>:
        a : Applied <- H2io.apply(c, rs, cl, msg)
        b : Applied <- H2io.flush(a, wr, inbox, q)
        m : Maybe<&1, H2Msg> <- Chan.recv(H2Msg, inbox)
        H2io.mgr(o, f, MEv.of(b, m), inbox, wr, q)

def H2io.split(p: Socket & Result<&1, &1, U32 & String, Socket>, cfg: T.H2Cfg, +q: Maybe<&2, Chan(H2Req)>,
  +inbox: Chan(H2Msg), +wr: Chan(List<&2, U32>)) -> IO(Unit):
  match p:
    case (s, Done{s2}):
      do IO<Unit>:
        IO.spawn(Unit, H2io.read(s, inbox))
        IO.spawn(Unit, H2io.write(s2, wr))
        IO.spawn(Unit, H2io.mgr(H2io.fuel(), H2io.fuel(), MEv{Applied{T.H2.new(cfg), Nil{}, False{}}, Some{MIn{Nil{}}}},
          inbox, wr, q))
    case (s, Fail{e}):
      do IO<Unit>:
        Socket.close(s)
        Chan.close(H2Msg, inbox)

# Runs an HTTP/2 connection on s with our settings cfg; a server's new
# streams go to q. Answers the connection's inbox at once.
def H2io.conn(s: Socket, cfg: T.H2Cfg, +q: Maybe<&2, Chan(H2Req)>) -> IO(Chan(H2Msg)):
  do IO<Chan(H2Msg)>:
    +inbox : Chan(H2Msg) <- Chan.new(H2Msg, 1024)
    wr : Chan(List<&2, U32>) <- Chan.new(List<&2, U32>, 1024)
    p : Socket & Result<&1, &1, U32 & String, Socket> <- Y.Sys.dup(s)
    H2io.split(p, cfg, q, inbox, wr)
    return inbox

# Serving
# -------

type AEv is Type:
  AGot{l: Listener, r: Result<&1, &1, U32 & String, Socket>}

def AEv.of(p: Listener & Result<&1, &1, U32 & String, Socket>) -> AEv:
  match p:
    case (l, r):
      AGot{l, r}

def H2io.serve1(r: Result<&1, &1, U32 & String, Socket>, +reqs: Chan(H2Req)) -> IO(Unit):
  match r:
    case Done{s}:
      do IO<Unit>:
        inbox : Chan(H2Msg) <- H2io.conn(s, T.H2.cfg(True{}), Some{reqs})
        return Unit{}
    case Fail{e}:
      IO.pure(Unit, Unit{})

def H2io.accepting(outer: Nat, fuel: Nat, ev: AEv, +reqs: Chan(H2Req)) -> IO(Unit):
  match outer fuel ev:
    case 0n 0n AGot{l, r}:
      Listener.close(l)
    case 1n+o 0n e:
      H2io.accepting(o, H2io.fuel(), e, reqs)
    case o 1n+f AGot{l, r}:
      do IO<Unit>:
        H2io.serve1(r, reqs)
        p : Listener & Result<&1, &1, U32 & String, Socket> <- TCP.accept(l)
        H2io.accepting(o, f, AEv.of(p), reqs)

# Serves HTTP/2 on l (TCP.listen, Y.Sys.listen or Y.Sys.unix_listen),
# each stream a client opens going to reqs.
def H2io.serve(l: Listener, +reqs: Chan(H2Req)) -> IO(Unit):
  do IO<Unit>:
    p : Listener & Result<&1, &1, U32 & String, Socket> <- TCP.accept(l)
    H2io.accepting(H2io.fuel(), H2io.fuel(), AEv.of(p), reqs)

# A client connection on s (TCP.connect or Y.Sys.unix_connect).
def H2io.client(s: Socket) -> IO(Chan(H2Msg)):
  H2io.conn(s, T.H2.cfg(False{}), None{})

# Calls
# -----

# A whole response: its headers, body and trailers.
type H2Resp is Data:
  H2Resp{headers: List<&2, H.Header>, body: List<&2, U32>, trailers: List<&2, H.Header>}

def H2io.got_headers(r: H2Resp, hs: List<&2, H.Header>) -> H2Resp:
  match r:
    case H2Resp{Nil{}, b, t}:
      H2Resp{hs, b, t}
    case H2Resp{h, b, t}:
      H2Resp{h, b, List.append(&2, H.Header, t, hs)}

# While a response is collected, its body is kept reversed, so each DATA
# frame costs its own length; H2io.fin turns it round.
def H2io.got_data(r: H2Resp, bs: List<&2, U32>) -> H2Resp:
  match r:
    case H2Resp{h, b, t}:
      H2Resp{h, List.append(&2, U32, List.reverse(&2, U32, bs), b), t}

def H2io.fin(r: H2Resp) -> H2Resp:
  match r:
    case H2Resp{h, b, t}:
      H2Resp{h, List.reverse(&2, U32, b), t}

type CEv is Type:
  CEv{r: H2Resp, m: Maybe<&1, SEv>}

def H2io.collect(outer: Nat, fuel: Nat, ev: CEv, +back: Chan(SEv)) -> IO(Result<&2, &2, String, H2Resp>):
  match outer fuel ev:
    case 0n 0n CEv{r, m}:
      IO.pure(Result<&2, &2, String, H2Resp>, Fail{"the response never ended"})
    case 1n+o 0n e:
      H2io.collect(o, H2io.fuel(), e, back)
    case o 1n+f CEv{r, Some{SGot{T.EvHeaders{sid, hs, True{}}}}}:
      IO.pure(Result<&2, &2, String, H2Resp>, Done{H2io.fin(H2io.got_headers(r, hs))})
    case o 1n+f CEv{r, Some{SGot{T.EvData{sid, bs, True{}}}}}:
      IO.pure(Result<&2, &2, String, H2Resp>, Done{H2io.fin(H2io.got_data(r, bs))})
    case o 1n+f CEv{r, Some{SGot{T.EvHeaders{sid, hs, False{}}}}}:
      do IO<Result<&2, &2, String, H2Resp>>:
        m : Maybe<&1, SEv> <- Chan.recv(SEv, back)
        H2io.collect(o, f, CEv{H2io.got_headers(r, hs), m}, back)
    case o 1n+f CEv{r, Some{SGot{T.EvData{sid, bs, False{}}}}}:
      do IO<Result<&2, &2, String, H2Resp>>:
        m : Maybe<&1, SEv> <- Chan.recv(SEv, back)
        H2io.collect(o, f, CEv{H2io.got_data(r, bs), m}, back)
    case o 1n+f CEv{r, Some{SGot{T.EvRst{sid, code}}}}:
      IO.pure(Result<&2, &2, String, H2Resp>, Fail{"the stream was reset with code " ++ U32.show(code)})
    case o 1n+f CEv{r, Some{SGone{why}}}:
      IO.pure(Result<&2, &2, String, H2Resp>, Fail{why})
    case o 1n+f CEv{r, Some{x}}:
      do IO<Result<&2, &2, String, H2Resp>>:
        m : Maybe<&1, SEv> <- Chan.recv(SEv, back)
        H2io.collect(o, f, CEv{r, m}, back)
    case o 1n+f CEv{r, None{}}:
      IO.pure(Result<&2, &2, String, H2Resp>, Fail{"the connection ended"})

def H2io.call.opened(m: Maybe<&1, SEv>, +conn: Chan(H2Msg), +back: Chan(SEv), body: List<&2, U32>) ->
  IO(Result<&2, &2, String, H2Resp>):
  match m:
    case Some{SOpened{+sid}}:
      do IO<Result<&2, &2, String, H2Resp>>:
        r : Result<&1, &1, H2Msg, Unit> <- Chan.send(H2Msg, conn, MSend{sid, T.CData{body, True{}}})
        n : Maybe<&1, SEv> <- Chan.recv(SEv, back)
        H2io.collect(H2io.fuel(), H2io.fuel(), CEv{H2Resp{Nil{}, Nil{}, Nil{}}, n}, back)
    case Some{SGone{why}}:
      IO.pure(Result<&2, &2, String, H2Resp>, Fail{why})
    case _:
      IO.pure(Result<&2, &2, String, H2Resp>, Fail{"the connection ended"})

# A request with headers hs and body on conn (H2io.client's), and its
# whole response.
def H2io.call(+conn: Chan(H2Msg), hs: List<&2, H.Header>, body: List<&2, U32>) -> IO(Result<&2, &2, String, H2Resp>):
  do IO<Result<&2, &2, String, H2Resp>>:
    +back : Chan(SEv) <- Chan.new(SEv, 256)
    r : Result<&1, &1, H2Msg, Unit> <- Chan.send(H2Msg, conn, MOpen{hs, False{}, back})
    m : Maybe<&1, SEv> <- Chan.recv(SEv, back)
    H2io.call.opened(m, conn, back, body)
