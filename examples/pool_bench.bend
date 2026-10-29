import Base
import ../src/json.bend as J
import ../src/core.bend as C
import ../src/config.bend as K
import ../src/client.bend as Cl

def Bench.ok(r: Result<&2, &2, Cl.KErr, J.Json>) -> U32:
  match r:
    case Done{j}:
      1
    case Fail{e}:
      0

# n GETs one after another, without and then with a connection pool; the
# difference is the TLS handshakes the pool saves. A second pooled round
# after a pause shows reuse surviving idle time.

def gets(n: Nat, +cfg: K.Config, ok: U32) -> IO(U32):
  match n:
    case 0n:
      IO.pure(U32, ok)
    case 1n+p:
      IO.bind(Result<&2, &2, Cl.KErr, J.Json>, U32, Cl.Client.json(cfg, C.Req.get("/version")),
        r => gets(p, cfg, (ok + Bench.ok(r) : U32)))

def timed(label: String, n: Nat, +cfg: K.Config) -> IO(Unit):
  do IO<Unit>:
    t0 : Nat <- IO.now()
    ok : U32 <- gets(n, cfg, 0)
    t1 : Nat <- IO.now()
    IO.print(label ++ ": " ++ U32.show(ok) ++ " ok in " ++ Nat.show(Nat.sub(t1, t0)) ++ "ms")

def run(c: Result<&2, &2, String, K.Config>) -> IO(Unit):
  match c:
    case Done{+cfg}:
      do IO<Unit>:
        timed("fresh connections", 50n, cfg)
        +p : Chan(Socket) <- Chan.new(Socket, 8)
        timed("pooled", 50n, K.Config.with_pool(cfg, p))
        IO.print("pausing 20s (restart the proxy now to make the idle connection stale)")
        IO.sleep(20000)
        timed("pooled after pause", 50n, K.Config.with_pool(cfg, p))
    case Fail{e}:
      IO.print("config: " ++ e)

def main() -> IO(Unit):
  IO.bind(Result<&2, &2, String, K.Config>, Unit, Cl.Config.infer(), run)
