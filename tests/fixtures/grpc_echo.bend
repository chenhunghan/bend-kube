import Base
import ../../src/http.bend as H
import ../../src/pb.bend as P
import ../../src/grpc.bend as G
import ../../src/grpcio.bend as R
import ../../src/h2io.bend as I
import ../../src/sys.bend as Y

# The service echo.proto declares, for tests/grpc.sh:
#   grpc_echo serve PATH          serves bendtest.Echo on a Unix socket
#   grpc_echo call PATH METHOD TEXT N MS
#                                 calls METHOD with Msg{TEXT, N} within MS
#                                 milliseconds (0: none) and prints the
#                                 answer
# Say answers Msg{"hi " ++ text, n + 1, tags reversed, labels}; Count
# streams Msg{"i", i} for i below n; Fail answers INVALID_ARGUMENT; Slow
# sleeps n milliseconds, then answers as Say.

def msg(text: String, n: P.W64, tags: List<&2, String>, labels: List<&2, P.PbStr>) -> List<&2, U32>:
  P.Pb.encode(List.concat(&2, P.PbField, [P.Pb.str(1, text), P.Pb.u64(2, n), P.Pb.strs(3, tags), P.Pb.str_map(4, labels)]))

def inc.go(+hi: U32, +lo: U32, carry: Bool) -> P.W64:
  match carry:
    case True{}:
      P.W64{U32.add(hi, 1), 0}
    case False{}:
      P.W64{hi, U32.add(lo, 1)}

def inc(w: P.W64) -> P.W64:
  match w:
    case P.W64{+hi, +lo}:
      inc.go(hi, lo, U32.is_eq(lo, 4294967295))

def say(m: List<&2, P.PbField>) -> List<&2, U32>:
  +m = m
  msg("hi " ++ P.Pb.get_str(m, 1), inc(P.Pb.get_u64(m, 2)), List.reverse(&2, String, P.Pb.all_str(m, 3)),
    Result.default(&2, &2, String, List<&2, P.PbStr>, P.Pb.get_str_map(m, 4), Nil{}))

def counting(n: Nat, +i: U32, k: R.GSink) -> IO(R.GSink):
  match n:
    case 0n:
      IO.pure(R.GSink, k)
    case 1n+r:
      do IO<R.GSink>:
        k2 : R.GSink <- R.Grpc.send(k, msg("i", P.W64{0, i}, Nil{}, Nil{}))
        counting(r, U32.add(i, 1), k2)

def route(method: String, +m: List<&2, P.PbField>, k: R.GSink, sy: Bool, count: Bool, fail: Bool, slow: Bool) -> IO(Unit):
  match sy count fail slow:
    case True{} c f s:
      R.Grpc.reply(k, Done{say(m)})
    case False{} True{} f s:
      do IO<Unit>:
        k2 : R.GSink <- counting(U32.to_nat(P.Pb.get_u32(m, 2)), 0, k)
        R.Grpc.finish(k2, G.GStatus{0, ""})
    case False{} False{} True{} s:
      R.Grpc.reply(k, Fail{G.GStatus{G.Grpc.invalid_argument(), "bad: " ++ P.Pb.get_str(m, 1) ++ " ✓ 100%"}})
    case False{} False{} False{} True{}:
      do IO<Unit>:
        IO.sleep(P.Pb.get_u32(m, 2))
        R.Grpc.reply(k, Done{say(m)})
    case False{} False{} False{} False{}:
      R.Grpc.finish(k, G.GStatus{G.Grpc.unimplemented(), "unknown method " ++ method})

def decoded(+method: String, r: Result<&2, &2, String, List<&2, P.PbField>>, k: R.GSink) -> IO(Unit):
  match r:
    case Fail{e}:
      R.Grpc.finish(k, G.GStatus{G.Grpc.invalid_argument(), e})
    case Done{+m}:
      route(method, m, k, String.eq(method, "/bendtest.Echo/Say"), String.eq(method, "/bendtest.Echo/Count"),
        String.eq(method, "/bendtest.Echo/Fail"), String.eq(method, "/bendtest.Echo/Slow"))

def handler(c: R.GCall) -> IO(Unit):
  match c:
    case R.GCall{+method, md, msg, ms, k}:
      decoded(method, P.Pb.decode(msg), k)

def serving(r: Result<&1, &1, U32 & String, Listener>) -> IO(Unit):
  match r:
    case Fail{(c, m)}:
      IO.print("listen failed: " ++ m)
    case Done{l}:
      do IO<Unit>:
        +calls : Chan(R.GCall) <- Chan.new(R.GCall, 256)
        IO.spawn(Unit, R.Grpc.run(~handler, calls))
        IO.print("listening")
        R.Grpc.serve(l, calls)

def show_dec(r: Result<&2, &2, String, List<&2, P.PbField>>) -> String:
  match r:
    case Fail{e}:
      "undecodable: " ++ e
    case Done{+m}:
      P.Pb.get_str(m, 1) ++ "/" ++ U32.show(P.Pb.get_u32(m, 2))

def show_msg(bs: List<&2, U32>) -> String:
  show_dec(P.Pb.decode(bs))

def show_r(r: Result<&2, &2, G.GStatus, List<&2, List<&2, U32>>>) -> String:
  match r:
    case Fail{G.GStatus{c, m}}:
      "status " ++ U32.show(c) ++ ": " ++ m
    case Done{ms}:
      List.show(~&2, ~List<&2, U32>, ~show_msg, ms)

def calling(r: Result<&1, &1, U32 & String, Socket>, +method: String, +text: String, +n: U32, +ms: U32) -> IO(Unit):
  match r:
    case Fail{(c, m)}:
      IO.print("connect failed: " ++ m)
    case Done{s}:
      do IO<Unit>:
        +conn : Chan(I.H2Msg) <- I.H2io.client(s)
        a : Result<&2, &2, G.GStatus, List<&2, List<&2, U32>>> <- R.Grpc.stream(conn, method, msg(text, P.W64{0, n}, Nil{}, Nil{}), ms)
        IO.print(show_r(a))
        x : Result<&1, &1, I.H2Msg, Unit> <- Chan.send(I.H2Msg, conn, I.MClose{})
        return Unit{}

def num(s: String) -> U32:
  Maybe.default(&2, U32, U32.read(s), 0)

def main.go(args: List<String>) -> IO(Unit):
  match args:
    case [p, cmd, path]:
      IO.bind(Result<&1, &1, U32 & String, Listener>, Unit, Y.Sys.unix_listen(path, 384), serving)
    case [p, cmd, path, method, text, n, ms]:
      IO.bind(Result<&1, &1, U32 & String, Socket>, Unit, Y.Sys.unix_connect(path), r => calling(r, method, text, num(n), num(ms)))
    case _:
      IO.print("usage: grpc_echo serve PATH | call PATH METHOD TEXT N MS")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    main.go(args)
