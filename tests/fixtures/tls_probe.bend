import Base
import ../../src/utf8.bend as U
import ../../src/net.bend as N

# For tests/tls.sh: opens host:port (args) with net.bend's Tls.open, the
# PEM roots, client certificate and key in PROBE_CA, PROBE_CERT and
# PROBE_KEY, sends a GET, and prints "ok <status line>" or "error: <why>".

def line(bs: List<&2, U32>) -> String:
  String.take(U.Utf8.decode_all(bs), 15n)

def got(p: Socket & N.Res(List<&2, U32>)) -> IO(Unit):
  match p:
    case (s, Done{Nil{}}):
      IO.bind(Unit, Unit, N.Tls.close(s), u => IO.print("error: closed"))
    case (s, Done{bs}):
      IO.bind(Unit, Unit, N.Tls.close(s), u => IO.print("ok " ++ line(bs)))
    case (s, Fail{(c, m)}):
      IO.bind(Unit, Unit, N.Tls.close(s), u => IO.print("error: recv: " ++ m))

def sent(p: Socket & N.Res(Unit)) -> IO(Unit):
  match p:
    case (s, Done{u}):
      IO.bind(Socket & N.Res(List<&2, U32>), Unit, N.Tls.recv(s, 4096, 5000), got)
    case (s, Fail{(c, m)}):
      IO.bind(Unit, Unit, N.Tls.close(s), u => IO.print("error: send: " ++ m))

def opened(r: N.Res(Socket)) -> IO(Unit):
  match r:
    case Done{s}:
      IO.bind(Socket & N.Res(Unit), Unit, N.Tls.send(s, "GET / HTTP/1.0\r\n\r\n", 5000), sent)
    case Fail{(c, m)}:
      IO.print("error: " ++ m)

def env(r: N.Res(String)) -> String:
  match r:
    case Done{v}:
      v
    case Fail{e}:
      ""

def run(args: List<String>, ca: String, cert: String, key: String) -> IO(Unit):
  match args:
    case Con{prog, Con{h, Con{p, t}}}:
      IO.bind(N.Res(Socket), Unit,
        N.Tls.open(h, Maybe.default(&2, U32, U32.read(p), 443), ca, cert, key, 3000), opened)
    case _:
      IO.print("usage: tls_probe HOST PORT")

def main() -> IO(Unit):
  do IO<Unit>:
    argv : List<String> <- IO.args()
    ca : N.Res(String) <- IO.get_env("PROBE_CA")
    cert : N.Res(String) <- IO.get_env("PROBE_CERT")
    key : N.Res(String) <- IO.get_env("PROBE_KEY")
    run(argv, env(ca), env(cert), env(key))
