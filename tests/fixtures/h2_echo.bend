import Base
import ../../src/http.bend as H
import ../../src/utf8.bend as U
import ../../src/h2.bend as T
import ../../src/h2io.bend as I
import ../../src/sys.bend as Y

# An HTTP/2 echo, for tests/h2.sh:
#   h2_echo serve-unix PATH | serve-tcp PORT
#       answers each request 200 with its body (or "hello PATH" when
#       empty), x-path and x-bytes headers, and an x-done trailer
#   h2_echo call-unix PATH REQPATH BODY [N]
#       N calls (default 1) on one connection, at once; prints each
#       status, body and trailers in order

def hdr(+name: String, hs: List<&2, H.Header>) -> String:
  Maybe.default(&2, String, H.Http.find(hs, name), "")

def reply.body(+path: String, +body: List<&2, U32>, empty: Bool) -> List<&2, U32>:
  match empty:
    case True{}:
      U.Utf8.encode("hello " ++ path)
    case False{}:
      body

def reply(+sid: U32, +conn: Chan(I.H2Msg), r: Result<&2, &2, String, I.H2Resp>) -> IO(Unit):
  match r:
    case Fail{e}:
      IO.print("request failed: " ++ e)
    case Done{I.H2Resp{+hs, +body, t}}:
      +path = hdr(":path", hs)
      do IO<Unit>:
        a : Result<&1, &1, I.H2Msg, Unit> <- Chan.send(I.H2Msg, conn, I.MSend{sid, T.CHead{[H.Header{":status", "200"},
          H.Header{"x-path", path}, H.Header{"x-bytes", Nat.show(List.length(&2, U32, body))}], False{}}})
        b : Result<&1, &1, I.H2Msg, Unit> <- Chan.send(I.H2Msg, conn, I.MSend{sid,
          T.CData{reply.body(path, body, List.is_empty(&2, U32, body)), False{}}})
        c : Result<&1, &1, I.H2Msg, Unit> <- Chan.send(I.H2Msg, conn, I.MSend{sid, T.CHead{[H.Header{"x-done", "yes"}], True{}}})
        return Unit{}

def handle(q: I.H2Req) -> IO(Unit):
  match q:
    case I.H2Req{+sid, +evs, +conn}:
      do IO<Unit>:
        m : Maybe<&1, I.SEv> <- Chan.recv(I.SEv, evs)
        r : Result<&2, &2, String, I.H2Resp> <- I.H2io.collect(4294967295n, 4294967295n, I.CEv{I.H2Resp{Nil{}, Nil{}, Nil{}}, m}, evs)
        reply(sid, conn, r)

def handled(m: Maybe<&1, I.H2Req>) -> IO(Unit):
  match m:
    case Some{q}:
      IO.spawn(Unit, handle(q))
    case None{}:
      IO.pure(Unit, Unit{})

def requests(fuel: Nat, +reqs: Chan(I.H2Req)) -> IO(Unit):
  match fuel:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+f:
      do IO<Unit>:
        m : Maybe<&1, I.H2Req> <- Chan.recv(I.H2Req, reqs)
        handled(m)
        requests(f, reqs)

def serving(r: Result<&1, &1, U32 & String, Listener>) -> IO(Unit):
  match r:
    case Fail{(c, m)}:
      IO.print("listen failed: " ++ m)
    case Done{l}:
      do IO<Unit>:
        +reqs : Chan(I.H2Req) <- Chan.new(I.H2Req, 256)
        IO.spawn(Unit, requests(4294967295n, reqs))
        IO.print("listening")
        I.H2io.serve(l, reqs)

def show_h(h: H.Header) -> String:
  match h:
    case H.Header{n, v}:
      n ++ "=" ++ v

def show_hs(hs: List<&2, H.Header>) -> String:
  List.show(~&2, ~H.Header, ~show_h, hs)

def show_resp(r: Result<&2, &2, String, I.H2Resp>) -> String:
  match r:
    case Fail{e}:
      "fail: " ++ e
    case Done{I.H2Resp{+hs, body, t}}:
      hdr(":status", hs) ++ " " ++ U.Utf8.decode_all(body) ++ " " ++ show_hs(t)

def call1(+conn: Chan(I.H2Msg), +path: String, +body: String) -> IO(Result<&2, &2, String, I.H2Resp>):
  I.H2io.call(conn, [H.Header{":method", "POST"}, H.Header{":scheme", "http"}, H.Header{":path", path},
    H.Header{":authority", "localhost"}], U.Utf8.encode(body))

def forks(+n: Nat, +conn: Chan(I.H2Msg), +path: String, +body: String, acc: List<&2, Chan(Result<&2, &2, String, I.H2Resp>)>) ->
  IO(List<&2, Chan(Result<&2, &2, String, I.H2Resp>)>):
  match n:
    case 0n:
      IO.pure(List<&2, Chan(Result<&2, &2, String, I.H2Resp>)>, List.reverse(&2, Chan(Result<&2, &2, String, I.H2Resp>), acc))
    case 1n+k:
      do IO<List<&2, Chan(Result<&2, &2, String, I.H2Resp>)>>:
        ch : Chan(Result<&2, &2, String, I.H2Resp>) <- IO.fork(Result<&2, &2, String, I.H2Resp>,
          call1(conn, path, body ++ Nat.show(k)))
        forks(k, conn, path, body, Con{ch, acc})

def joins(chs: List<&2, Chan(Result<&2, &2, String, I.H2Resp>)>) -> IO(Unit):
  match chs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{ch, t}:
      do IO<Unit>:
        r : Result<&2, &2, String, I.H2Resp> <- IO.join(Result<&2, &2, String, I.H2Resp>, ch)
        IO.print(show_resp(r))
        joins(t)

def calling(r: Result<&1, &1, U32 & String, Socket>, +path: String, +body: String, n: Nat) -> IO(Unit):
  match r:
    case Fail{(c, m)}:
      IO.print("connect failed: " ++ m)
    case Done{s}:
      do IO<Unit>:
        +conn : Chan(I.H2Msg) <- I.H2io.client(s)
        chs : List<&2, Chan(Result<&2, &2, String, I.H2Resp>)> <- forks(n, conn, path, body, Nil{})
        joins(chs)
        x : Result<&1, &1, I.H2Msg, Unit> <- Chan.send(I.H2Msg, conn, I.MClose{})
        return Unit{}

def count(m: Maybe<&2, U32>) -> Nat:
  match m:
    case Some{n}:
      U32.to_nat(n)
    case None{}:
      1n

def serve(unix: Bool, a: String) -> IO(Unit):
  match unix:
    case True{}:
      IO.bind(Result<&1, &1, U32 & String, Listener>, Unit, Y.Sys.unix_listen(a, 384), serving)
    case False{}:
      IO.bind(Result<&1, &1, U32 & String, Listener>, Unit, TCP.listen("127.0.0.1", Maybe.default(&2, U32, U32.read(a), 0)), serving)

def main.go(args: List<String>) -> IO(Unit):
  match args:
    case [p, +cmd, a]:
      serve(String.eq(cmd, "serve-unix"), a)
    case [p, cmd, a, path, body]:
      IO.bind(Result<&1, &1, U32 & String, Socket>, Unit, Y.Sys.unix_connect(a), r => calling(r, path, body, 1n))
    case [p, cmd, a, path, body, n]:
      IO.bind(Result<&1, &1, U32 & String, Socket>, Unit, Y.Sys.unix_connect(a), r => calling(r, path, body, count(U32.read(n))))
    case _:
      IO.print("usage: h2_echo serve-unix PATH | serve-tcp PORT | call-unix PATH REQPATH BODY [N]")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    main.go(args)
