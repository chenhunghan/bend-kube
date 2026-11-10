import Base

# Sys
# ===
#
# Effects Base lacks (effs/sys.c): the wall clock, termination signals, and
# a listener on IPv6 as well as IPv4.

# The wall clock: (days since 1970-01-01, (second of the day,
# microseconds)). time.bend's Wall.of makes it a Wall.
def Sys.wall() -> IO(U32 & (U32 & U32)):
  import "./effs/sys.c"
  import "./effs/sys.js"

# Waits for SIGTERM or SIGINT; answers the signal's number.
def Sys.signal() -> IO(U32):
  import "./effs/sys.c"
  import "./effs/sys.js"

def Sys.listen.dual(port: U32) -> IO(Result<&1, &1, U32 & String, Listener>):
  import "./effs/sys.c"
  import "./effs/sys.js"

# What the JS lane's Sys.listen.dual answers (effs/sys.js).
def Sys.listen.js() -> String:
  "dual-stack listen needs the native lane"

def Sys.listen.v4(+port: U32, c: U32, +m: String, lane: Bool) -> IO(Result<&1, &1, U32 & String, Listener>):
  match lane:
    case True{}:
      TCP.listen("0.0.0.0", port)
    case False{}:
      IO.pure(Result<&1, &1, U32 & String, Listener>, Fail{(c, m)})

def Sys.listen.got(r: Result<&1, &1, U32 & String, Listener>, +port: U32) ->
  IO(Result<&1, &1, U32 & String, Listener>):
  match r:
    case Fail{(c, +m)}:
      # the JS lane's answer: listen through Base, on IPv4
      Sys.listen.v4(port, c, m, String.starts_with(m, Sys.listen.js()))
    case Done{l}:
      IO.pure(Result<&1, &1, U32 & String, Listener>, Done{l})

# A listener on every address of port: IPv6 and IPv4 (dual-stack), so
# probes and webhooks answer on IPv6-only and dual-stack clusters; IPv4
# only on a host without IPv6, and on the JS lane.
def Sys.listen(+port: U32) -> IO(Result<&1, &1, U32 & String, Listener>):
  IO.bind(Result<&1, &1, U32 & String, Listener>, Result<&1, &1, U32 & String, Listener>, Sys.listen.dual(port),
    r => Sys.listen.got(r, port))
