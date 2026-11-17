import Base
import ../../src/sys.bend as Y

# A Unix-socket echo, for tests/unix.sh:
#   unix_echo serve PATH       listens (mode 0600), echoes one message per
#                              connection, forever
#   unix_echo listen PATH      listens, prints ok or the failure, exits
#   unix_echo call PATH MSG    sends MSG, prints the reply or the failure

type AEv is Type:
  AGot{l: Listener, r: Result<&1, &1, U32 & String, Socket>}

def AEv.got(p: Listener & Result<&1, &1, U32 & String, Socket>) -> AEv:
  match p:
    case (l, r):
      AGot{l, r}

def fail(c: U32, m: String) -> String:
  "fail " ++ U32.show(c) ++ " " ++ m

def echo.close(q: Socket & Result<&1, &1, (U32 & String) & List<&2, U32>, Unit>) -> IO(Unit):
  match q:
    case (s, r):
      Socket.close(s)

def echo.reply(p: Socket & Result<&1, &1, U32 & String, Maybe<&1, String>>) -> IO(Unit):
  match p:
    case (s, Done{Some{m}}):
      IO.bind(Socket & Result<&1, &1, (U32 & String) & List<&2, U32>, Unit>, Unit, TCP.send(s, m), echo.close)
    case (s, _):
      Socket.close(s)

def echo.one(r: Result<&1, &1, U32 & String, Socket>) -> IO(Unit):
  match r:
    case Done{s}:
      IO.spawn(Unit, IO.bind(Socket & Result<&1, &1, U32 & String, Maybe<&1, String>>, Unit,
        TCP.recv(s, 4096), echo.reply))
    case Fail{e}:
      IO.pure(Unit, Unit{})

def echo.loop(fuel: Nat, ev: AEv) -> IO(Unit):
  match fuel ev:
    case 0n AGot{l, r}:
      Listener.close(l)
    case 1n+f AGot{l, r}:
      IO.bind(Unit, Unit, echo.one(r),
        u => IO.bind(Listener & Result<&1, &1, U32 & String, Socket>, Unit, TCP.accept(l),
          p => echo.loop(f, AEv.got(p))))

def serve.got(r: Result<&1, &1, U32 & String, Listener>) -> IO(Unit):
  match r:
    case Done{l}:
      do IO<Unit>:
        IO.print("listening")
        p : Listener & Result<&1, &1, U32 & String, Socket> <- TCP.accept(l)
        echo.loop(4294967295n, AEv.got(p))
    case Fail{(c, m)}:
      IO.print(fail(c, m))

def listen.got(r: Result<&1, &1, U32 & String, Listener>) -> IO(Unit):
  match r:
    case Done{l}:
      do IO<Unit>:
        IO.print("ok")
        Listener.close(l)
    case Fail{(c, m)}:
      IO.print(fail(c, m))

def call.got(p: Socket & Result<&1, &1, U32 & String, Maybe<&1, String>>) -> IO(Unit):
  match p:
    case (s, Done{Some{m}}):
      do IO<Unit>:
        IO.print("reply " ++ m)
        Socket.close(s)
    case (s, Done{None{}}):
      do IO<Unit>:
        IO.print("closed")
        Socket.close(s)
    case (s, Fail{(c, m)}):
      do IO<Unit>:
        IO.print(fail(c, m))
        Socket.close(s)

def call.sent(q: Socket & Result<&1, &1, (U32 & String) & List<&2, U32>, Unit>) -> IO(Unit):
  match q:
    case (s, Done{u}):
      IO.bind(Socket & Result<&1, &1, U32 & String, Maybe<&1, String>>, Unit, TCP.recv(s, 4096), call.got)
    case (s, Fail{((c, m), rest)}):
      do IO<Unit>:
        IO.print(fail(c, m))
        Socket.close(s)

def call.connected(r: Result<&1, &1, U32 & String, Socket>, msg: String) -> IO(Unit):
  match r:
    case Done{s}:
      IO.bind(Socket & Result<&1, &1, (U32 & String) & List<&2, U32>, Unit>, Unit, TCP.send(s, msg), call.sent)
    case Fail{(c, m)}:
      IO.print(fail(c, m))

def run(cmd: U32, path: String, msg: String) -> IO(Unit):
  match cmd:
    case 0:
      IO.bind(Result<&1, &1, U32 & String, Listener>, Unit, Y.Sys.unix_listen(path, 384), serve.got)
    case 1:
      IO.bind(Result<&1, &1, U32 & String, Listener>, Unit, Y.Sys.unix_listen(path, 0), listen.got)
    case _:
      IO.bind(Result<&1, &1, U32 & String, Socket>, Unit, Y.Sys.unix_connect(path), r => call.connected(r, msg))

def cmd.go(serve: Bool, listen: Bool) -> U32:
  match serve listen:
    case True{} x:
      0
    case False{} True{}:
      1
    case False{} False{}:
      2

def cmd(+c: String) -> U32:
  cmd.go(String.eq(c, "serve"), String.eq(c, "listen"))

def main.go(args: List<String>) -> IO(Unit):
  match args:
    case Con{p, Con{+c, Con{path, rest}}}:
      run(cmd(c), path, Maybe.default(&1, String, List.head(&1, String, rest), ""))
    case _:
      IO.print("usage: unix_echo serve|listen|call PATH [MSG]")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    main.go(args)
