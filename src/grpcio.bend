import Base
import ./http.bend as H
import ./h2.bend as T
import ./h2io.bend as I
import ./grpc.bend as G

# gRPC over sockets
# =================
#
# Servers and clients for unary and server-streaming calls, on
# h2io.bend's connections (TCP or Unix, h2c).
#
# Serving: Grpc.serve(listener, calls) puts each call on calls as a
# GCall: its method ("/package.Service/Method"), its request headers, its
# one request message, its deadline in milliseconds (0: none) and a sink
# to answer on. Grpc.run(~handler, calls) takes them off, each on its own
# computation, and resets a call whose deadline passes. A handler answers
# with Grpc.send (a message; any number, for server streaming) and then
# Grpc.finish (the status), or with Grpc.reply for a unary call.
#
# Calling: Grpc.unary(conn, method, msg, ms) and Grpc.stream (every
# message of a server-streaming call), on a connection from
# I.H2io.client.

type GSink is Data:
  GSink{sid: U32, conn: Chan(I.H2Msg), started: Bool}

type GCall is Data:
  GCall{method: String, md: List<&2, H.Header>, msg: List<&2, U32>, deadline: U32, sink: GSink}

def Grpc.put(+conn: Chan(I.H2Msg), +sid: U32, ch: T.Chunk) -> IO(Unit):
  do IO<Unit>:
    r : Result<&1, &1, I.H2Msg, Unit> <- Chan.send(I.H2Msg, conn, I.MSend{sid, ch})
    return Unit{}

def Grpc.start(+conn: Chan(I.H2Msg), +sid: U32, started: Bool) -> IO(Unit):
  match started:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      Grpc.put(conn, sid, T.CHead{G.Grpc.reply_headers(), False{}})

# Sends one message of the answer (the headers first, the first time).
def Grpc.send(k: GSink, msg: List<&2, U32>) -> IO(GSink):
  match k:
    case GSink{+sid, +conn, started}:
      do IO<GSink>:
        Grpc.start(conn, sid, started)
        Grpc.put(conn, sid, T.CData{G.Grpc.frame(msg), False{}})
        return GSink{sid, conn, True{}}

# Ends the answer with a status.
def Grpc.finish(k: GSink, st: G.GStatus) -> IO(Unit):
  match k:
    case GSink{+sid, +conn, +started}:
      Grpc.put(conn, sid, T.CHead{G.Grpc.trailers(st, Bool.not(started)), True{}})

# A unary call's answer: its message and OK, or a status.
def Grpc.reply(k: GSink, r: Result<&2, &2, G.GStatus, List<&2, U32>>) -> IO(Unit):
  match r:
    case Fail{st}:
      Grpc.finish(k, st)
    case Done{msg}:
      do IO<Unit>:
        k2 : GSink <- Grpc.send(k, msg)
        Grpc.finish(k2, G.GStatus{0, ""})

# Serving
# -------

def Grpc.deadline(m: Maybe<&2, String>) -> U32:
  match m:
    case None{}:
      0
    case Some{s}:
      Maybe.default(&2, U32, G.Grpc.timeout(s), 0)

def Grpc.one(+hs: List<&2, H.Header>, r: Result<&2, &2, G.GStatus, List<&2, List<&2, U32>>>, +k: GSink,
  +calls: Chan(GCall)) -> IO(Unit):
  match r:
    case Fail{st}:
      Grpc.finish(k, st)
    case Done{[msg]}:
      do IO<Unit>:
        s : Result<&1, &1, GCall, Unit> <- Chan.send(GCall, calls, GCall{Maybe.default(&2, String, G.Grpc.hdr(hs, ":path"), ""),
          hs, msg, Grpc.deadline(G.Grpc.hdr(hs, "grpc-timeout")), k})
        return Unit{}
    case Done{ms}:
      Grpc.finish(k, G.GStatus{G.Grpc.unimplemented(), "a call must send one request message"})

def Grpc.request.go(+sid: U32, +conn: Chan(I.H2Msg), +hs: List<&2, H.Header>, body: List<&2, U32>,
  +calls: Chan(GCall), ok: Bool) -> IO(Unit):
  match ok:
    case True{}:
      Grpc.one(hs, G.Grpc.unframe(body), GSink{sid, conn, False{}}, calls)
    case False{}:
      Grpc.put(conn, sid, T.CHead{[H.Header{":status", "415"}], True{}})

def Grpc.request(+sid: U32, +conn: Chan(I.H2Msg), r: Result<&2, &2, String, I.H2Resp>, +calls: Chan(GCall)) -> IO(Unit):
  match r:
    case Fail{e}:
      IO.pure(Unit, Unit{})
    case Done{I.H2Resp{+hs, body, t}}:
      Grpc.request.go(sid, conn, hs, body, calls, G.Grpc.is_call(hs))

# A stream from the HTTP/2 server: its request read whole, then handed on.
def Grpc.take(q: I.H2Req, +calls: Chan(GCall)) -> IO(Unit):
  match q:
    case I.H2Req{+sid, +evs, +conn}:
      do IO<Unit>:
        m : Maybe<&1, I.SEv> <- Chan.recv(I.SEv, evs)
        r : Result<&2, &2, String, I.H2Resp> <- I.H2io.collect(I.H2io.fuel(), I.H2io.fuel(),
          I.CEv{I.H2Resp{Nil{}, Nil{}, Nil{}}, m}, evs)
        Grpc.request(sid, conn, r, calls)

def Grpc.taken(m: Maybe<&1, I.H2Req>, +calls: Chan(GCall)) -> IO(Unit):
  match m:
    case Some{q}:
      IO.spawn(Unit, Grpc.take(q, calls))
    case None{}:
      IO.pure(Unit, Unit{})

def Grpc.intake(outer: Nat, fuel: Nat, +reqs: Chan(I.H2Req), +calls: Chan(GCall)) -> IO(Unit):
  match outer fuel:
    case 0n 0n:
      IO.pure(Unit, Unit{})
    case 1n+o 0n:
      Grpc.intake(o, I.H2io.fuel(), reqs, calls)
    case o 1n+f:
      do IO<Unit>:
        m : Maybe<&1, I.H2Req> <- Chan.recv(I.H2Req, reqs)
        Grpc.taken(m, calls)
        Grpc.intake(o, f, reqs, calls)

# Serves gRPC on l, each call going to calls.
def Grpc.serve(l: Listener, +calls: Chan(GCall)) -> IO(Unit):
  do IO<Unit>:
    +reqs : Chan(I.H2Req) <- Chan.new(I.H2Req, 256)
    IO.spawn(Unit, Grpc.intake(I.H2io.fuel(), I.H2io.fuel(), reqs, calls))
    I.H2io.serve(l, reqs)

def Grpc.expired(r: Maybe<&1, Unit>, +sid: U32, +conn: Chan(I.H2Msg)) -> IO(Unit):
  match r:
    case Some{u}:
      IO.pure(Unit, Unit{})
    case None{}:
      do IO<Unit>:
        x : Result<&1, &1, I.H2Msg, Unit> <- Chan.send(I.H2Msg, conn, I.MReset{sid, T.H2.cancel()})
        return Unit{}

def Grpc.timed(~h: GCall -> IO(Unit), c: GCall, +ms: U32, +sid: U32, +conn: Chan(I.H2Msg), none: Bool) -> IO(Unit):
  match none:
    case True{}:
      h(c)
    case False{}:
      do IO<Unit>:
        r : Maybe<&1, Unit> <- IO.within(Unit, ms, h(c))
        Grpc.expired(r, sid, conn)

# Runs h on c, and resets the stream if c's deadline passes first.
def Grpc.handle(~h: GCall -> IO(Unit), c: GCall) -> IO(Unit):
  match c:
    case GCall{method, md, msg, +ms, GSink{+sid, +conn, started}}:
      Grpc.timed(~h, GCall{method, md, msg, ms, GSink{sid, conn, started}}, ms, sid, conn, U32.is_zero(ms))

def Grpc.handled(~h: GCall -> IO(Unit), m: Maybe<&1, GCall>) -> IO(Unit):
  match m:
    case Some{c}:
      IO.spawn(Unit, Grpc.handle(~h, c))
    case None{}:
      IO.pure(Unit, Unit{})

def Grpc.loop(~h: GCall -> IO(Unit), outer: Nat, fuel: Nat, +calls: Chan(GCall)) -> IO(Unit):
  match outer fuel:
    case 0n 0n:
      IO.pure(Unit, Unit{})
    case 1n+o 0n:
      Grpc.loop(~h, o, I.H2io.fuel(), calls)
    case o 1n+f:
      do IO<Unit>:
        m : Maybe<&1, GCall> <- Chan.recv(GCall, calls)
        Grpc.handled(~h, m)
        Grpc.loop(~h, o, f, calls)

# Takes calls off calls, each to h on its own computation.
def Grpc.run(~h: GCall -> IO(Unit), +calls: Chan(GCall)) -> IO(Unit):
  Grpc.loop(~h, I.H2io.fuel(), I.H2io.fuel(), calls)

# Calling
# -------

# The status of an answer that is not HTTP 200 (PROTOCOL-HTTP2.md's map).
def Grpc.http_status.go(s: String, missing: Bool, busy: Bool) -> G.GStatus:
  match missing busy:
    case True{} b:
      G.GStatus{G.Grpc.unimplemented(), "HTTP " ++ s}
    case False{} True{}:
      G.GStatus{G.Grpc.unavailable(), "HTTP " ++ s}
    case False{} False{}:
      G.GStatus{G.Grpc.unknown(), "HTTP " ++ s}

def Grpc.http_status(+s: String) -> G.GStatus:
  Grpc.http_status.go(s, String.eq(s, "404"),
    String.eq(s, "503") || String.eq(s, "502") || String.eq(s, "504") || String.eq(s, "429"))

def Grpc.answer.ok(st: G.GStatus, body: List<&2, U32>) -> Result<&2, &2, G.GStatus, List<&2, List<&2, U32>>>:
  match st:
    case G.GStatus{0, m}:
      G.Grpc.unframe(body)
    case G.GStatus{c, m}:
      Fail{G.GStatus{c, m}}

def Grpc.answer.trailers(hs: List<&2, H.Header>, t: List<&2, H.Header>, body: List<&2, U32>) ->
  Result<&2, &2, G.GStatus, List<&2, List<&2, U32>>>:
  match t:
    case Nil{}:
      Grpc.answer.ok(G.Grpc.status_of(hs), body)
    case tt:
      Grpc.answer.ok(G.Grpc.status_of(tt), body)

def Grpc.answer.http.go(+status: String, hs: List<&2, H.Header>, t: List<&2, H.Header>, body: List<&2, U32>, ok: Bool) ->
  Result<&2, &2, G.GStatus, List<&2, List<&2, U32>>>:
  match ok:
    case True{}:
      Grpc.answer.trailers(hs, t, body)
    case False{}:
      Fail{Grpc.http_status(status)}

def Grpc.answer.http(+status: String, hs: List<&2, H.Header>, t: List<&2, H.Header>, body: List<&2, U32>) ->
  Result<&2, &2, G.GStatus, List<&2, List<&2, U32>>>:
  Grpc.answer.http.go(status, hs, t, body, String.eq(status, "200"))

def Grpc.answer(r: Result<&2, &2, String, I.H2Resp>) -> Result<&2, &2, G.GStatus, List<&2, List<&2, U32>>>:
  match r:
    case Fail{e}:
      Fail{G.GStatus{G.Grpc.unavailable(), e}}
    case Done{I.H2Resp{+hs, body, t}}:
      Grpc.answer.http(Maybe.default(&2, String, G.Grpc.hdr(hs, ":status"), ""), hs, t, body)

def Grpc.timely(r: Maybe<&1, Result<&2, &2, String, I.H2Resp>>) -> Result<&2, &2, G.GStatus, List<&2, List<&2, U32>>>:
  match r:
    case None{}:
      Fail{G.GStatus{G.Grpc.deadline_exceeded(), "the deadline passed"}}
    case Some{x}:
      Grpc.answer(x)

def Grpc.call(+conn: Chan(I.H2Msg), +method: String, msg: List<&2, U32>, +ms: U32, none: Bool) ->
  IO(Result<&2, &2, G.GStatus, List<&2, List<&2, U32>>>):
  match none:
    case True{}:
      IO.bind(Result<&2, &2, String, I.H2Resp>, Result<&2, &2, G.GStatus, List<&2, List<&2, U32>>>,
        I.H2io.call(conn, G.Grpc.call_headers(method, 0), G.Grpc.frame(msg)),
        r => IO.pure(Result<&2, &2, G.GStatus, List<&2, List<&2, U32>>>, Grpc.answer(r)))
    case False{}:
      IO.bind(Maybe<&1, Result<&2, &2, String, I.H2Resp>>, Result<&2, &2, G.GStatus, List<&2, List<&2, U32>>>,
        IO.within(Result<&2, &2, String, I.H2Resp>, ms, I.H2io.call(conn, G.Grpc.call_headers(method, ms), G.Grpc.frame(msg))),
        r => IO.pure(Result<&2, &2, G.GStatus, List<&2, List<&2, U32>>>, Grpc.timely(r)))

# Every message of a call to method with msg (a server-streaming call's
# whole stream), within ms milliseconds unless ms is 0.
def Grpc.stream(+conn: Chan(I.H2Msg), +method: String, msg: List<&2, U32>, +ms: U32) ->
  IO(Result<&2, &2, G.GStatus, List<&2, List<&2, U32>>>):
  Grpc.call(conn, method, msg, ms, U32.is_zero(ms))

def Grpc.single(r: Result<&2, &2, G.GStatus, List<&2, List<&2, U32>>>) -> Result<&2, &2, G.GStatus, List<&2, U32>>:
  match r:
    case Fail{st}:
      Fail{st}
    case Done{[m]}:
      Done{m}
    case Done{ms}:
      Fail{G.GStatus{G.Grpc.internal(), "a unary call answered with other than one message"}}

# A unary call: its answer's one message, or its status.
def Grpc.unary(+conn: Chan(I.H2Msg), +method: String, msg: List<&2, U32>, +ms: U32) ->
  IO(Result<&2, &2, G.GStatus, List<&2, U32>>):
  IO.bind(Result<&2, &2, G.GStatus, List<&2, List<&2, U32>>>, Result<&2, &2, G.GStatus, List<&2, U32>>,
    Grpc.stream(conn, method, msg, ms), r => IO.pure(Result<&2, &2, G.GStatus, List<&2, U32>>, Grpc.single(r)))
