import Base

# Sys
# ===
#
# Effects Base lacks (effs/sys.c): the wall clock, and termination signals.

# The wall clock: (days since 1970-01-01, (second of the day,
# microseconds)). time.bend's Wall.of makes it a Wall.
def Sys.wall() -> IO(U32 & (U32 & U32)):
  import "./effs/sys.c"
  import "./effs/sys.js"

# Waits for SIGTERM or SIGINT; answers the signal's number.
def Sys.signal() -> IO(U32):
  import "./effs/sys.c"
  import "./effs/sys.js"
