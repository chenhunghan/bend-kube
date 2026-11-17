import Base
import ../../src/unz.bend as Z
import ../../src/gzip.bend as G

# Decompresses a file to another, 64 KiB at a time, for tests/unz.sh:
#   unz_cat gzip|zstd|pure IN OUT [MAX]
# (pure: gzip.bend, in Bend; MAX: the most one feed may put out, 256 MiB
# unless given). Prints "ok BYTES" or the failure.

type Dec is Type:
  Lib{id: U32, max: U32}
  Pure{g: G.Gz}

type Ev is Type:
  ERead{d: Dec, f: File, o: File, r: Result<&1, &1, U32 & String, List<&2, U32>>}
  EDec{d: Dec, f: File, o: File, r: Result<&1, &1, U32 & String, List<&2, U32>>}
  EWrote{d: Dec, f: File, o: File, r: Result<&1, &1, U32 & String, Unit>}

type DR is Type:
  DR{d: Dec, r: Result<&1, &1, U32 & String, List<&2, U32>>}

def Dec.pure(o: G.GzOut) -> DR:
  match o:
    case G.GzOut{g, out}:
      DR{Pure{g}, Done{out}}

def Dec.feed(d: Dec, bs: List<&2, U32>) -> IO(DR):
  match d:
    case Lib{+id, +max}:
      do IO<DR>:
        r : Result<&1, &1, U32 & String, List<&2, U32>> <- Z.Unz.feed(id, bs, max)
        return DR{Lib{id, max}, r}
    case Pure{g}:
      IO.pure(DR, Dec.pure(G.Gz.feed(g, bs)))

def Dec.done(r: Result<&2, &2, String, Unit>) -> Result<&1, &1, U32 & String, Unit>:
  match r:
    case Done{u}:
      Done{u}
    case Fail{m}:
      Fail{(0, m)}

def Dec.close(d: Dec) -> IO(Result<&1, &1, U32 & String, Unit>):
  match d:
    case Lib{id, max}:
      Z.Unz.close(id)
    case Pure{g}:
      IO.pure(Result<&1, &1, U32 & String, Unit>, Dec.done(G.Gz.finish(g)))

def closed(c: Result<&1, &1, U32 & String, Unit>, +n: U32) -> String:
  match c:
    case Done{u}:
      "ok " ++ U32.show(n)
    case Fail{(x, m)}:
      "fail " ++ m

def ERead.of(d: Dec, p: File & Result<&1, &1, U32 & String, List<&2, U32>>, o: File) -> Ev:
  match p:
    case (f, r):
      ERead{d, f, o, r}

def EDec.of(x: DR, f: File, o: File) -> Ev:
  match x:
    case DR{d, r}:
      EDec{d, f, o, r}

def EWrote.of(d: Dec, f: File, p: File & Result<&1, &1, U32 & String, Unit>) -> Ev:
  match p:
    case (o, r):
      EWrote{d, f, o, r}

def finish(d: Dec, f: File, o: File, +n: U32, why: Maybe<&2, String>) -> IO(Unit):
  do IO<Unit>:
    c : Result<&1, &1, U32 & String, Unit> <- Dec.close(d)
    File.close(f)
    File.close(o)
    IO.print(Maybe.default(&2, String, why, closed(c, n)))

def loop(fuel: Nat, ev: Ev, +n: U32) -> IO(Unit):
  match fuel ev:
    case 0n ERead{d, f, o, r}:
      finish(d, f, o, n, Some{"out of fuel"})
    case 0n EDec{d, f, o, r}:
      finish(d, f, o, n, Some{"out of fuel"})
    case 0n EWrote{d, f, o, r}:
      finish(d, f, o, n, Some{"out of fuel"})
    case 1n+k ERead{d, f, o, Done{Nil{}}}:
      finish(d, f, o, n, None{})
    case 1n+k ERead{d, f, o, Done{bs}}:
      do IO<Unit>:
        x : DR <- Dec.feed(d, bs)
        loop(k, EDec.of(x, f, o), n)
    case 1n+k ERead{d, f, o, Fail{(c, m)}}:
      finish(d, f, o, n, Some{"fail read: " ++ m})
    case 1n+k EDec{d, f, o, Done{+out}}:
      do IO<Unit>:
        p : File & Result<&1, &1, U32 & String, Unit> <- File.write_bytes(o, out)
        loop(k, EWrote.of(d, f, p), U32.add(n, U32.from_nat(List.length(&2, U32, out))))
    case 1n+k EDec{d, f, o, Fail{(c, m)}}:
      finish(d, f, o, n, Some{"fail " ++ m})
    case 1n+k EWrote{d, f, o, Done{u}}:
      do IO<Unit>:
        p : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_bytes(f, 65536)
        loop(k, ERead.of(d, p, o), n)
    case 1n+k EWrote{d, f, o, Fail{(c, m)}}:
      finish(d, f, o, n, Some{"fail write: " ++ m})

def start(d: Dec, a: Result<&1, &1, U32 & String, File>, b: Result<&1, &1, U32 & String, File>) -> IO(Unit):
  match a b:
    case Done{f} Done{o}:
      do IO<Unit>:
        p : File & Result<&1, &1, U32 & String, List<&2, U32>> <- File.read_bytes(f, 65536)
        loop(4294967295n, ERead.of(d, p, o), 0)
    case x y:
      IO.print("fail open")

def run(d: Dec, +inp: String, +out: String) -> IO(Unit):
  do IO<Unit>:
    a : Result<&1, &1, U32 & String, File> <- File.open(inp, "r")
    b : Result<&1, &1, U32 & String, File> <- File.open(out, "w")
    start(d, a, b)

def opened(r: Result<&1, &1, U32 & String, U32>, +inp: String, +out: String, +max: U32) -> IO(Unit):
  match r:
    case Fail{(c, m)}:
      IO.print("fail " ++ m)
    case Done{id}:
      run(Lib{id, max}, inp, out)

def main.kind(pure: Bool, zstd: Bool, +inp: String, +out: String, +max: U32) -> IO(Unit):
  match pure zstd:
    case True{} z:
      run(Pure{G.Gz.new()}, inp, out)
    case False{} True{}:
      IO.bind(Result<&1, &1, U32 & String, U32>, Unit, Z.Unz.open(Z.Unz.zstd()), r => opened(r, inp, out, max))
    case False{} False{}:
      IO.bind(Result<&1, &1, U32 & String, U32>, Unit, Z.Unz.open(Z.Unz.gzip()), r => opened(r, inp, out, max))

def main.go(args: List<String>) -> IO(Unit):
  match args:
    case [p, +kind, inp, out]:
      main.kind(String.eq(kind, "pure"), String.eq(kind, "zstd"), inp, out, 268435456)
    case [p, +kind, inp, out, max]:
      main.kind(String.eq(kind, "pure"), String.eq(kind, "zstd"), inp, out, Maybe.default(&2, U32, U32.read(max), 0))
    case _:
      IO.print("usage: unz_cat gzip|zstd|pure IN OUT")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    main.go(args)
