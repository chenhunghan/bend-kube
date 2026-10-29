import Base
import ../src/utf8.bend as U
import ../src/core.bend as C
import ../src/watcher.bend as W
import ../src/runtime.bend as R

# The parallel line parser must answer exactly what the sequential one
# does, in the same order.

def line(+n: U32) -> List<&2, U32>:
  U.Utf8.encode("{\"type\":\"ADDED\",\"object\":{\"metadata\":{\"name\":\"o" ++ U32.show(n)
    ++ "\",\"resourceVersion\":\"" ++ U32.show(n) ++ "\"}}}")

def lines(n: Nat, +k: U32) -> List<&2, List<&2, U32>>:
  match n:
    case 0n:
      Nil{}
    case 1n+p:
      line(k) <> lines(p, (k + 1 : U32))

def names(xs: List<&2, W.Input>) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{W.IEvent{C.WAdded{o}}, t}:
      C.Obj.name(o) ++ " " ++ names(t)
    case Con{x, t}:
      "? " ++ names(t)

def main() -> IO(Unit):
  +ls = lines(37n, 1)
  do IO<Unit>:
    IO.print("same: " ++ Bool.show(String.eq(names(R.Drv.inputs(ls)), names(R.Drv.inputs.par(3n, ls)))))
    IO.print(String.take(names(R.Drv.inputs.par(3n, ls)), 24n))
