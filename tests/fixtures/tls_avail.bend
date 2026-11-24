import Base
import ../../src/net.bend as N

# For tests/tls.sh: Tls.available() three times in one process:
#   tls_avail CRYPTO SSL
# probes with the environment it was started with, then sets
# BEND_KUBE_LIBCRYPTO to CRYPTO and BEND_KUBE_LIBSSL to SSL ("" unsets
# one) and probes twice more. Prints one line per probe: "N ok" or
# "N fail <why>".

def Env.set(name: String, value: String) -> IO(Unit):
  import "./tls_avail.c"

def shown(+n: String, r: N.Res(Unit)) -> String:
  match r:
    case Done{u}:
      n ++ " ok"
    case Fail{(c, m)}:
      n ++ " fail " ++ m

def probe(+n: String) -> IO(Unit):
  IO.bind(N.Res(Unit), Unit, N.Tls.available(), r => IO.print(shown(n, r)))

def run(args: List<String>) -> IO(Unit):
  match args:
    case [p, crypto, ssl]:
      do IO<Unit>:
        probe("1")
        Env.set("BEND_KUBE_LIBCRYPTO", crypto)
        Env.set("BEND_KUBE_LIBSSL", ssl)
        probe("2")
        probe("3")
    case _:
      IO.print("usage: tls_avail CRYPTO SSL")

def main() -> IO(Unit):
  IO.bind(List<String>, Unit, IO.args(), run)
