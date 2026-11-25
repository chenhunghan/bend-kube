import Base
import ../../src/zip.bend as Z

# Stores blocks with src/zip.bend, for tests/zip.sh:
#   zip KIND SRC OFF_HI OFF_LO LEN_HI LEN_LO BLOCK DST AT_HI AT_LO
#     Zip.blocks from SRC into DST, which must exist (it is opened "r+")
#   zip KIND SRC DST
#     Zip.pack of SRC's bytes (at most 2 MiB are read), the stored bytes
#     written to DST
# Prints "ok" and each block's word, or "fail" and the failure.

def num(s: String) -> U32:
  Maybe.default(&2, U32, U32.read(s), 0)

def words(ws: List<&2, U32>) -> String:
  match ws:
    case Nil{}:
      ""
    case Con{w, t}:
      " " ++ U32.show(w) ++ words(t)

def shown(r: Result<&1, &1, U32 & String, List<&2, U32>>) -> String:
  match r:
    case Done{ws}:
      "ok" ++ words(ws)
    case Fail{(c, m)}:
      "fail " ++ m

def blocked(q: File & (File & Result<&1, &1, U32 & String, List<&2, U32>>)) -> IO(Unit):
  match q:
    case (f, (g, r)):
      do IO<Unit>:
        File.close(f)
        File.close(g)
        IO.print(shown(r))

def blocks(a: Result<&1, &1, U32 & String, File>, b: Result<&1, &1, U32 & String, File>, kind: U32, oh: U32, ol: U32, lh: U32, ll: U32, block: U32, ah: U32, al: U32) -> IO(Unit):
  match a b:
    case Done{f} Done{g}:
      do IO<Unit>:
        q : File & (File & Result<&1, &1, U32 & String, List<&2, U32>>) <- Z.Zip.blocks(kind, f, oh, ol, lh, ll, block, g, ah, al)
        blocked(q)
    case Done{f} Fail{(c, m)}:
      do IO<Unit>:
        File.close(f)
        IO.print("fail open " ++ m)
    case Fail{(c, m)} Done{g}:
      do IO<Unit>:
        File.close(g)
        IO.print("fail open " ++ m)
    case Fail{(c, m)} Fail{e}:
      IO.print("fail open " ++ m)

def wrote(q: File & Result<&1, &1, U32 & String, Unit>, +word: U32) -> IO(Unit):
  match q:
    case (g, Done{u}):
      do IO<Unit>:
        File.close(g)
        IO.print("ok " ++ U32.show(word))
    case (g, Fail{(c, m)}):
      do IO<Unit>:
        File.close(g)
        IO.print("fail write " ++ m)

def packed(r: Result<&1, &1, U32 & String, U32 & List<&2, U32>>, b: Result<&1, &1, U32 & String, File>) -> IO(Unit):
  match r b:
    case Done{(+word, stored)} Done{g}:
      do IO<Unit>:
        q : File & Result<&1, &1, U32 & String, Unit> <- File.write_bytes(g, stored)
        wrote(q, word)
    case Fail{(c, m)} Done{g}:
      do IO<Unit>:
        File.close(g)
        IO.print("fail " ++ m)
    case r2 Fail{(c, m)}:
      IO.print("fail open " ++ m)

def pack.read(p: File & Result<&1, &1, U32 & String, List<&2, U32>>, kind: U32, +dst: String) -> IO(Unit):
  match p:
    case (f, Done{bs}):
      do IO<Unit>:
        File.close(f)
        r : Result<&1, &1, U32 & String, U32 & List<&2, U32>> <- Z.Zip.pack(kind, bs)
        b : Result<&1, &1, U32 & String, File> <- File.open(dst, "w")
        packed(r, b)
    case (f, Fail{(c, m)}):
      do IO<Unit>:
        File.close(f)
        IO.print("fail read " ++ m)

def pack(a: Result<&1, &1, U32 & String, File>, kind: U32, +dst: String) -> IO(Unit):
  match a:
    case Done{f}:
      do IO<Unit>:
        p : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_bytes(f, 2097152)
        pack.read(p, kind, dst)
    case Fail{(c, m)}:
      IO.print("fail open " ++ m)

def main.go(args: List<String>) -> IO(Unit):
  match args:
    case [p, kind, src, oh, ol, lh, ll, block, dst, ah, al]:
      do IO<Unit>:
        a : Result<&1, &1, U32 & String, File> <- File.open(src, "r")
        b : Result<&1, &1, U32 & String, File> <- File.open(dst, "r+")
        blocks(a, b, num(kind), num(oh), num(ol), num(lh), num(ll), num(block), num(ah), num(al))
    case [p, kind, src, dst]:
      do IO<Unit>:
        a : Result<&1, &1, U32 & String, File> <- File.open(src, "r")
        pack(a, num(kind), dst)
    case _:
      IO.print("usage: zip KIND SRC OFF_HI OFF_LO LEN_HI LEN_LO BLOCK DST AT_HI AT_LO | zip KIND SRC DST")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    main.go(args)
