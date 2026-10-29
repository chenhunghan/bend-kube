import Base
import ../src/ws.bend as W

def bytes(bs: List<&2, U32>) -> String:
  match bs:
    case Nil{}:
      ""
    case Con{b, Nil{}}:
      U32.show(b)
    case Con{b, t}:
      U32.show(b) ++ " " ++ bytes(t)

def frames(fs: List<&2, W.Frame>) -> String:
  match fs:
    case Nil{}:
      ""
    case Con{W.Frame{fin, op, data}, t}:
      "[fin=" ++ Bool.show(fin) ++ " op=" ++ U32.show(op) ++ " data=" ++ bytes(data) ++ "] " ++
        frames(t)

def err(m: Maybe<&2, String>) -> String:
  match m:
    case None{}:
      "none"
    case Some{e}:
      e

def fed(f: W.Fed) -> String:
  match f:
    case W.Fed{st, fs}:
      frames(fs) ++ "error=" ++ err(W.Ws.error(st))

def strip(bs: List<&2, U32>) -> List<&2, U32>:
  match bs:
    case Con{b0, Con{b1, rest}}:
      Con{b0, Con{U32.sub(b1, 128), List.drop(&2, U32, rest, 4n)}}
    case _:
      Nil{}

# A server's short frame (under 126 bytes): the client's, with the mask
# bit and key removed.
def sizes.go(fs: List<&2, W.Frame>) -> String:
  match fs:
    case Nil{}:
      ""
    case Con{W.Frame{fin, op, data}, t}:
      "[op=" ++ U32.show(op) ++ " size=" ++ Nat.show(List.length(&2, U32, data)) ++ "] " ++ sizes.go(t)

def sizes(f: W.Fed) -> String:
  match f:
    case W.Fed{st, fs}:
      sizes.go(fs) ++ "error=" ++ err(W.Ws.error(st))

def unmasked(+op: U32, +data: List<&2, U32>) -> List<&2, U32>:
  strip(W.Ws.frame(op, data, 0))

def two_cuts.go(f: W.Fed, +rest: List<&2, U32>) -> String:
  match f:
    case W.Fed{st, fs1}:
      frames(fs1) ++ "| " ++ fed(W.Ws.feed(st, rest))

def two_cuts(+bs: List<&2, U32>, +n: Nat) -> String:
  two_cuts.go(W.Ws.feed(W.WHead{}, List.take(&2, U32, bs, n)), List.drop(&2, U32, bs, n))

def main() -> IO(Unit):
  do IO<Unit>:
    # a masked client frame: header, key, then XORed payload
    IO.print(bytes(W.Ws.frame(2, [0, 104, 105], 16909060)))
    IO.print(bytes(List.take(&2, U32, W.Ws.frame(2, List.replicate(U32, 200n, 7), 0), 4n)))
    IO.print(bytes(W.Ws.len(70000)))
    # a masked frame decodes back to its payload
    IO.print(fed(W.Ws.feed(W.WHead{}, W.Ws.frame(2, [1, 2, 3, 250], 2864434397))))
    # two server frames in one cut, then split mid-header and mid-payload
    IO.print(fed(W.Ws.feed(W.WHead{}, List.append(&2, U32, unmasked(2, [1, 111, 107]), unmasked(8, Nil{})))))
    IO.print(two_cuts(List.append(&2, U32, unmasked(2, [2, 101]), unmasked(2, [3, 123])), 1n))
    IO.print(two_cuts(List.append(&2, U32, unmasked(2, [2, 101]), unmasked(2, [3, 123])), 5n))
    # a 16-bit length (300): no frame until the whole payload came
    IO.print(fed(W.Ws.feed(W.WHead{}, [129, 126, 1, 44, 9, 9])))
    IO.print(sizes(W.Ws.feed(W.WHead{}, List.append(&2, U32, [129, 126, 1, 44], List.replicate(U32, 300n, 9)))))
    # a length over the limit is refused
    IO.print(fed(W.Ws.feed(W.WHead{}, [130, 127, 0, 0, 0, 0, 2, 0, 0, 0, 9])))
