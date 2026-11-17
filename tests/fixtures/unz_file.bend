import Base
import ../../src/unz.bend as Z

# Decompresses a file straight into another, for tests/unz.sh:
#   unz_file sink|file gzip|zstd IN OUT [MAX]
# sink: 64 KiB chunks through Unz.sink and Unz.write (MAX: the most one
# write may put out, 256 MiB unless given); file: Unz.file at once (MAX
# in MiB, no limit unless given). Prints "ok BYTES" or the failure.

type Ev is Type:
  ERead{id: U32, f: File, r: Result<&1, &1, U32 & String, List<&2, U32>>}
  EWrote{id: U32, f: File, r: Result<&1, &1, U32 & String, U32>}

def closed(c: Result<&1, &1, U32 & String, Unit>, +n: U32) -> String:
  match c:
    case Done{u}:
      "ok " ++ U32.show(n)
    case Fail{(x, m)}:
      "fail " ++ m

def finish(id: U32, f: File, +n: U32, why: Maybe<&2, String>) -> IO(Unit):
  do IO<Unit>:
    c : Result<&1, &1, U32 & String, Unit> <- Z.Unz.close(id)
    File.close(f)
    IO.print(Maybe.default(&2, String, why, closed(c, n)))

def ERead.of(id: U32, p: File & Result<&1, &1, U32 & String, List<&2, U32>>) -> Ev:
  match p:
    case (f, r):
      ERead{id, f, r}

def loop(fuel: Nat, ev: Ev, +max: U32, +n: U32) -> IO(Unit):
  match fuel ev:
    case 0n ERead{id, f, r}:
      finish(id, f, n, Some{"out of fuel"})
    case 0n EWrote{id, f, r}:
      finish(id, f, n, Some{"out of fuel"})
    case 1n+k ERead{+id, f, Done{Nil{}}}:
      finish(id, f, n, None{})
    case 1n+k ERead{+id, f, Done{bs}}:
      do IO<Unit>:
        r : Result<&1, &1, U32 & String, U32> <- Z.Unz.write(id, bs, max)
        loop(k, EWrote{id, f, r}, max, n)
    case 1n+k ERead{id, f, Fail{(c, m)}}:
      finish(id, f, n, Some{"fail read: " ++ m})
    case 1n+k EWrote{+id, f, Done{w}}:
      do IO<Unit>:
        p : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_bytes(f, 65536)
        loop(k, ERead.of(id, p), max, U32.add(n, w))
    case 1n+k EWrote{id, f, Fail{(c, m)}}:
      finish(id, f, n, Some{"fail " ++ m})

def start(id: U32, a: Result<&1, &1, U32 & String, File>, s: Result<&1, &1, U32 & String, Unit>, +max: U32) -> IO(Unit):
  match a s:
    case Done{f} Done{u}:
      do IO<Unit>:
        p : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_bytes(f, 65536)
        loop(4294967295n, ERead.of(id, p), max, 0)
    case Done{f} Fail{(c, m)}:
      finish(id, f, 0, Some{"fail sink: " ++ m})
    case Fail{(c, m)} s2:
      do IO<Unit>:
        c2 : Result<&1, &1, U32 & String, Unit> <- Z.Unz.close(id)
        IO.print("fail open")

def opened(r: Result<&1, &1, U32 & String, U32>, +inp: String, +out: String, +max: U32) -> IO(Unit):
  match r:
    case Fail{(c, m)}:
      IO.print("fail " ++ m)
    case Done{+id}:
      do IO<Unit>:
        a : Result<&1, &1, U32 & String, File> <- File.open(inp, "r")
        s : Result<&1, &1, U32 & String, Unit> <- Z.Unz.sink(id, out)
        start(id, a, s, max)

def high(big: Bool, +hi: U32) -> String:
  match big:
    case True{}:
      " +" ++ U32.show(hi) ++ "*2^32"
    case False{}:
      ""

def kind_of(zstd: Bool) -> U32:
  match zstd:
    case True{}:
      Z.Unz.zstd()
    case False{}:
      Z.Unz.gzip()

def whole(r: Result<&1, &1, U32 & String, U32 & U32>) -> String:
  match r:
    case Done{(+hi, lo)}:
      "ok " ++ U32.show(lo) ++ high(Bool.not(U32.is_eq(hi, 0)), hi)
    case Fail{(c, m)}:
      "fail " ++ m

def main.mode(file: Bool, kind: U32, +inp: String, +out: String, +max: Maybe<&2, U32>) -> IO(Unit):
  match file:
    case True{}:
      IO.bind(Result<&1, &1, U32 & String, U32 & U32>, Unit, Z.Unz.file(kind, inp, out, Maybe.default(&2, U32, max, 0)), r => IO.print(whole(r)))
    case False{}:
      IO.bind(Result<&1, &1, U32 & String, U32>, Unit, Z.Unz.open(kind), r => opened(r, inp, out, Maybe.default(&2, U32, max, 268435456)))

def main.go(args: List<String>) -> IO(Unit):
  match args:
    case [p, +mode, +kind, inp, out]:
      main.mode(String.eq(mode, "file"), kind_of(String.eq(kind, "zstd")), inp, out, None{})
    case [p, +mode, +kind, inp, out, max]:
      main.mode(String.eq(mode, "file"), kind_of(String.eq(kind, "zstd")), inp, out, U32.read(max))
    case _:
      IO.print("usage: unz_file sink|file gzip|zstd IN OUT [MAX]")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    main.go(args)
