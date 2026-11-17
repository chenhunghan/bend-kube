import Base

# gzip
# ====
#
# A streaming gzip decoder (RFC 1952) around DEFLATE (RFC 1951), in pure
# Bend, for container image layers. Gz.feed takes the compressed bytes a
# chunk at a time and answers the bytes they decompress to, so a layer of
# any size streams through in bounded memory: the decoder keeps a 32 KiB
# window, in an Array, and reads its input a bit at a time (puff's
# canonical Huffman decoding), so it can stop between any two bits and
# resume with the next chunk. Each member's CRC-32 and size are checked;
# concatenated members are one stream.

# The base and extra bits of a length (257..285) or distance code.
type LD is Data:
  LD{base: U32, extra: U32}

# A Huffman decode in progress (puff's decode()): the code so far, the
# first code of its length, the index of that length's first symbol,
# and the counts of the lengths not yet tried.
type Hd is Data:
  Hd{code: U32, first: U32, index: U32, left: List<&2, U32>}

type HStep is Data:
  HSym{i: U32}
  HMore{h: Hd}
  HFail{}

# Where the decoder is. Each mode reading n bits keeps k, the bits read,
# and v, their value so far (least significant first).
type IM is Data:
  IHead{k: U32, v: U32}
  IAlign{}
  ISLen{k: U32, v: U32}
  IStored{left: U32}
  IDyn{k: U32, v: U32}
  ICl{hlit: U32, hdist: U32, left: U32, k: U32, v: U32, lens: List<&2, U32>}
  ILens{hlit: U32, hdist: U32, got: List<&2, U32>, n: U32, h: Hd}
  IRep{hlit: U32, hdist: U32, got: List<&2, U32>, n: U32, need: U32, k: U32, v: U32, base: U32, val: U32}
  IBlock{h: Hd}
  ILenX{base: U32, need: U32, k: U32, v: U32}
  IDist{len: U32, h: Hd}
  IDistX{len: U32, base: U32, need: U32, k: U32, v: U32}
  IDone{}
  IBad{why: String}

# The decoder: its mode, the window and the next place in it, how much
# has come out (up to 32 KiB, for distances), the literal/length (or
# code length) table and the distance table (the counts of each code
# length from 1, and the symbols in canonical order), whether this block
# is the last, the CRC-32 so far and its table, the bytes out, reversed,
# and the member's size so far (mod 2^32, as gzip's ISIZE).
type Inf is Type:
  Inf{m: IM, win: Array<U32>, pos: U32, total: U32, c1: List<&2, U32>, s1: Array<U32>, c2: List<&2, U32>,
    s2: Array<U32>, last: Bool, crc: U32, ct: Array<U32>, out: List<&2, U32>, size: U32}

# CRC-32
# ------

def Crc.one(n: Nat, +c: U32) -> U32:
  match n:
    case 0n:
      c
    case 1n+k:
      Crc.one(k, U32.xor(U32.shr(c), U32.and(3988292384, U32.sub(0, U32.and(c, 1)))))

def Crc.fill(n: Nat, a: Array<U32>, +i: U32) -> Array<U32>:
  match n:
    case 0n:
      a
    case 1n+k:
      Crc.fill(k, Array.set(U32, a, i, Crc.one(8n, i)), U32.add(i, 1))

# The CRC-32 table (the reflected polynomial 0xEDB88320).
def Crc.table() -> Array<U32>:
  Crc.fill(256n, [0 : U32*256n], 0)

# Tables
# ------

def Inf.len_base(i: U32) -> LD:
  match i:
    case 0:
      LD{3, 0}
    case 1:
      LD{4, 0}
    case 2:
      LD{5, 0}
    case 3:
      LD{6, 0}
    case 4:
      LD{7, 0}
    case 5:
      LD{8, 0}
    case 6:
      LD{9, 0}
    case 7:
      LD{10, 0}
    case 8:
      LD{11, 1}
    case 9:
      LD{13, 1}
    case 10:
      LD{15, 1}
    case 11:
      LD{17, 1}
    case 12:
      LD{19, 2}
    case 13:
      LD{23, 2}
    case 14:
      LD{27, 2}
    case 15:
      LD{31, 2}
    case 16:
      LD{35, 3}
    case 17:
      LD{43, 3}
    case 18:
      LD{51, 3}
    case 19:
      LD{59, 3}
    case 20:
      LD{67, 4}
    case 21:
      LD{83, 4}
    case 22:
      LD{99, 4}
    case 23:
      LD{115, 4}
    case 24:
      LD{131, 5}
    case 25:
      LD{163, 5}
    case 26:
      LD{195, 5}
    case 27:
      LD{227, 5}
    case 28:
      LD{258, 0}
    case _:
      LD{0, 255}

def Inf.dist_base(i: U32) -> LD:
  match i:
    case 0:
      LD{1, 0}
    case 1:
      LD{2, 0}
    case 2:
      LD{3, 0}
    case 3:
      LD{4, 0}
    case 4:
      LD{5, 1}
    case 5:
      LD{7, 1}
    case 6:
      LD{9, 2}
    case 7:
      LD{13, 2}
    case 8:
      LD{17, 3}
    case 9:
      LD{25, 3}
    case 10:
      LD{33, 4}
    case 11:
      LD{49, 4}
    case 12:
      LD{65, 5}
    case 13:
      LD{97, 5}
    case 14:
      LD{129, 6}
    case 15:
      LD{193, 6}
    case 16:
      LD{257, 7}
    case 17:
      LD{385, 7}
    case 18:
      LD{513, 8}
    case 19:
      LD{769, 8}
    case 20:
      LD{1025, 9}
    case 21:
      LD{1537, 9}
    case 22:
      LD{2049, 10}
    case 23:
      LD{3073, 10}
    case 24:
      LD{4097, 11}
    case 25:
      LD{6145, 11}
    case 26:
      LD{8193, 12}
    case 27:
      LD{12289, 12}
    case 28:
      LD{16385, 13}
    case 29:
      LD{24577, 13}
    case _:
      LD{0, 255}

# The code length code's lengths come in this order.
def Inf.order() -> List<&2, U32>:
  [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15]

# Building a table (puff's construct())
# -------------------------------------

def Tb.count(lens: List<&2, U32>, +l: U32) -> U32:
  match lens:
    case Nil{}:
      0
    case Con{+x, t}:
      U32.add(Bool.to_u32(U32.is_eq(x, l)), Tb.count(t, l))

def Tb.counts(n: Nat, +lens: List<&2, U32>, +l: U32) -> List<&2, U32>:
  match n:
    case 0n:
      Nil{}
    case 1n+k:
      Con{Tb.count(lens, l), Tb.counts(k, lens, U32.add(l, 1))}

# Whether no length has more codes than the lengths before it leave room
# for (an over-subscribed code cannot be decoded).
def Tb.ok(cs: List<&2, U32>, +left: U32) -> Bool:
  match cs:
    case Nil{}:
      True{}
    case Con{+c, t}:
      Bool.not(U32.is_gt(c, U32.mul(left, 2))) && Tb.ok(t, U32.sub(U32.mul(left, 2), c))

type TP is Type:
  TP{a: Array<U32>, k: U32}

def Tb.put(a: Array<U32>, +k: U32, +sym: U32, hit: Bool) -> TP:
  match hit:
    case True{}:
      TP{Array.set(U32, a, k, sym), U32.add(k, 1)}
    case False{}:
      TP{a, k}

# Puts the symbols of length l, in order, from the next free place.
def Tb.place(lens: List<&2, U32>, +l: U32, ev: TP, +sym: U32) -> TP:
  match lens ev:
    case Nil{} e:
      e
    case Con{+x, t} TP{a, +k}:
      Tb.place(t, l, Tb.put(a, k, sym, U32.is_eq(x, l)), U32.add(sym, 1))

def Tb.all(n: Nat, +lens: List<&2, U32>, +l: U32, ev: TP) -> TP:
  match n:
    case 0n:
      ev
    case 1n+r:
      Tb.all(r, lens, U32.add(l, 1), Tb.place(lens, l, ev, 0))

type TB is Type:
  TB{counts: List<&2, U32>, syms: Array<U32>, ok: Bool}

def Tb.done(cs: List<&2, U32>, ev: TP) -> TB:
  match ev:
    case TP{a, k}:
      +cs = cs
      TB{cs, a, Tb.ok(cs, 1)}

# A canonical code from each symbol's code length (0: unused): the count
# of each length from 1 to 15, and the symbols by length, then value.
def Tb.build(+lens: List<&2, U32>, syms: Array<U32>) -> TB:
  Tb.done(Tb.counts(15n, lens, 1), Tb.all(15n, lens, 1, TP{syms, 0}))

def Tb.fixed_lit() -> List<&2, U32>:
  List.concat(&2, U32, [List.replicate(U32, 144n, 8), List.replicate(U32, 112n, 9), List.replicate(U32, 24n, 7),
    List.replicate(U32, 8n, 8)])

def Tb.fixed_dist() -> List<&2, U32>:
  List.replicate(U32, 30n, 5)

# Huffman decoding, a bit at a time
# ---------------------------------

def Inf.hd(cs: List<&2, U32>) -> Hd:
  Hd{0, 0, 0, cs}

def Inf.hbit.go(+c: U32, +first: U32, +index: U32, +count: U32, rest: List<&2, U32>, hit: Bool) -> HStep:
  match hit:
    case True{}:
      HSym{U32.add(index, U32.sub(c, first))}
    case False{}:
      HMore{Hd{U32.shl(c), U32.shl(U32.add(first, count)), U32.add(index, count), rest}}

def Inf.hbit(h: Hd, +bit: U32) -> HStep:
  match h:
    case Hd{code, +first, index, left}:
      match left:
        case Nil{}:
          HFail{}
        case Con{+count, rest}:
          +c = U32.or(code, bit)
          Inf.hbit.go(c, first, index, count, rest, U32.is_lt(U32.sub(c, first), count))

# The decoder's moves
# -------------------

def Inf.mode(st: Inf, nm: IM) -> Inf:
  match st:
    case Inf{m, win, pos, total, c1, s1, c2, s2, last, crc, ct, out, size}:
      Inf{nm, win, pos, total, c1, s1, c2, s2, last, crc, ct, out, size}

def Inf.bad(st: Inf, why: String) -> Inf:
  Inf.mode(st, IBad{why})

def Inf.c1_of(st: Inf) -> Inf & List<&2, U32>:
  match st:
    case Inf{m, win, pos, total, +c1, s1, c2, s2, last, crc, ct, out, size}:
      (Inf{m, win, pos, total, c1, s1, c2, s2, last, crc, ct, out, size}, c1)

type IC is Type:
  IC{st: Inf, cs: List<&2, U32>}

def IC.of(p: Inf & List<&2, U32>) -> IC:
  match p:
    case (st, cs):
      IC{st, cs}

def Inf.c2_of(st: Inf) -> Inf & List<&2, U32>:
  match st:
    case Inf{m, win, pos, total, c1, s1, +c2, s2, last, crc, ct, out, size}:
      (Inf{m, win, pos, total, c1, s1, c2, s2, last, crc, ct, out, size}, c2)

def Inf.last_of(st: Inf) -> Inf & Bool:
  match st:
    case Inf{m, win, pos, total, c1, s1, c2, s2, +last, crc, ct, out, size}:
      (Inf{m, win, pos, total, c1, s1, c2, s2, last, crc, ct, out, size}, last)

def Inf.put.go(p: Array<U32> & U32, m: IM, win: Array<U32>, +pos: U32, +total: U32, c1: List<&2, U32>, s1: Array<U32>,
  c2: List<&2, U32>, s2: Array<U32>, last: Bool, +crc: U32, out: List<&2, U32>, +size: U32, +b: U32) -> Inf:
  match p:
    case (ct, +x):
      Inf{m, Array.set(U32, win, U32.and(pos, 32767), b), U32.add(pos, 1), U32.min(U32.add(total, 1), 32768),
        c1, s1, c2, s2, last, U32.xor(x, U32.shrn(crc, 8n)), ct, Con{b, out}, U32.add(size, 1)}

# One byte out: into the window, the CRC and the output.
def Inf.put(st: Inf, +b: U32) -> Inf:
  match st:
    case Inf{m, win, +pos, +total, c1, s1, c2, s2, last, +crc, ct, out, size}:
      Inf.put.go(Array.get(U32, ct, U32.and(U32.xor(crc, b), 255)), m, win, pos, total, c1, s1, c2, s2, last, crc, out, size, b)

def Inf.copy1.go(p: Array<U32> & U32, m: IM, +pos: U32, +total: U32, c1: List<&2, U32>, s1: Array<U32>,
  c2: List<&2, U32>, s2: Array<U32>, last: Bool, +crc: U32, ct: Array<U32>, out: List<&2, U32>, size: U32) -> Inf:
  match p:
    case (win, +b):
      Inf.put(Inf{m, win, pos, total, c1, s1, c2, s2, last, crc, ct, out, size}, b)

def Inf.copy1(st: Inf, +dist: U32) -> Inf:
  match st:
    case Inf{m, win, +pos, +total, c1, s1, c2, s2, last, +crc, ct, out, size}:
      Inf.copy1.go(Array.get(U32, win, U32.and(U32.sub(pos, dist), 32767)), m, pos, total, c1, s1, c2, s2, last, crc, ct, out, size)

def Inf.copy(n: Nat, +dist: U32, st: Inf) -> Inf:
  match n:
    case 0n:
      st
    case 1n+r:
      Inf.copy(r, dist, Inf.copy1(st, dist))

def Inf.total_of(st: Inf) -> Inf & U32:
  match st:
    case Inf{m, win, pos, +total, c1, s1, c2, s2, last, crc, ct, out, size}:
      (Inf{m, win, pos, total, c1, s1, c2, s2, last, crc, ct, out, size}, total)

def Inf.sym1.go(p: Array<U32> & U32, m: IM, win: Array<U32>, pos: U32, total: U32, c1: List<&2, U32>,
  c2: List<&2, U32>, s2: Array<U32>, last: Bool, crc: U32, ct: Array<U32>, out: List<&2, U32>, size: U32) -> Inf & U32:
  match p:
    case (s1, x):
      (Inf{m, win, pos, total, c1, s1, c2, s2, last, crc, ct, out, size}, x)

def Inf.sym2.go(p: Array<U32> & U32, m: IM, win: Array<U32>, pos: U32, total: U32, c1: List<&2, U32>,
  s1: Array<U32>, c2: List<&2, U32>, last: Bool, crc: U32, ct: Array<U32>, out: List<&2, U32>, size: U32) -> Inf & U32:
  match p:
    case (s2, x):
      (Inf{m, win, pos, total, c1, s1, c2, s2, last, crc, ct, out, size}, x)

# Back to reading literals and lengths, with the block's table.
def Inf.block(st: Inf) -> Inf:
  match st:
    case Inf{m, win, pos, total, +c1, s1, c2, s2, last, crc, ct, out, size}:
      Inf{IBlock{Inf.hd(c1)}, win, pos, total, c1, s1, c2, s2, last, crc, ct, out, size}

# On to a distance, with the block's distance table.
def Inf.dist(st: Inf, +len: U32) -> Inf:
  match st:
    case Inf{m, win, pos, total, c1, s1, +c2, s2, last, crc, ct, out, size}:
      Inf{IDist{len, Inf.hd(c2)}, win, pos, total, c1, s1, c2, s2, last, crc, ct, out, size}

def Inf.copy.go(st: Inf, +len: U32, +dist: U32, far: Bool) -> Inf:
  match far:
    case True{}:
      Inf.bad(st, "a distance past the start of the output")
    case False{}:
      Inf.block(Inf.copy(U32.to_nat(len), dist, st))

# Copies len bytes from dist back.
def Inf.match(p: Inf & U32, +len: U32, +dist: U32) -> Inf:
  match p:
    case (st, +total):
      Inf.copy.go(st, len, dist, U32.is_gt(dist, total))

# The block ended: the next, or the end.
def Inf.end_block.go(p: Inf & Bool) -> Inf:
  match p:
    case (st, True{}):
      Inf.mode(st, IDone{})
    case (st, False{}):
      Inf.mode(st, IHead{0, 0})

def Inf.end_block(st: Inf) -> Inf:
  Inf.end_block.go(Inf.last_of(st))

def Inf.set_t1(st: Inf, t: TB) -> Inf & Bool:
  match st t:
    case Inf{m, win, pos, total, c0, s0, c2, s2, last, crc, ct, out, size} TB{c1, s1, +ok}:
      (Inf{m, win, pos, total, c1, s1, c2, s2, last, crc, ct, out, size}, ok)

def Inf.set_t2(st: Inf, t: TB) -> Inf & Bool:
  match st t:
    case Inf{m, win, pos, total, c1, s1, c0, s0, last, crc, ct, out, size} TB{c2, s2, +ok}:
      (Inf{m, win, pos, total, c1, s1, c2, s2, last, crc, ct, out, size}, ok)

def Inf.s1_take(st: Inf) -> Inf & Array<U32>:
  match st:
    case Inf{m, win, pos, total, c1, s1, c2, s2, last, crc, ct, out, size}:
      (Inf{m, win, pos, total, c1, [0 : U32*2n], c2, s2, last, crc, ct, out, size}, s1)

def Inf.s2_take(st: Inf) -> Inf & Array<U32>:
  match st:
    case Inf{m, win, pos, total, c1, s1, c2, s2, last, crc, ct, out, size}:
      (Inf{m, win, pos, total, c1, s1, c2, [0 : U32*2n], last, crc, ct, out, size}, s2)

def Inf.t1.go(p: Inf & Array<U32>, +lens: List<&2, U32>) -> Inf & Bool:
  match p:
    case (st, a):
      Inf.set_t1(st, Tb.build(lens, a))

def Inf.t2.go(p: Inf & Array<U32>, +lens: List<&2, U32>) -> Inf & Bool:
  match p:
    case (st, a):
      Inf.set_t2(st, Tb.build(lens, a))

# The first table from lens (reusing its symbols' array); and whether the
# code is sound.
def Inf.t1(st: Inf, +lens: List<&2, U32>) -> Inf & Bool:
  Inf.t1.go(Inf.s1_take(st), lens)

def Inf.t2(st: Inf, +lens: List<&2, U32>) -> Inf & Bool:
  Inf.t2.go(Inf.s2_take(st), lens)

def Inf.tables.fin(st: Inf, ok: Bool) -> Inf:
  match ok:
    case True{}:
      Inf.block(st)
    case False{}:
      Inf.bad(st, "an over-subscribed Huffman code")

def Inf.tables.two(p: Inf & Bool, ok1: Bool) -> Inf:
  match p:
    case (st, ok2):
      Inf.tables.fin(st, ok1 && ok2)

def Inf.tables.one(p: Inf & Bool, +dist: List<&2, U32>) -> Inf:
  match p:
    case (st, +ok1):
      Inf.tables.two(Inf.t2(st, dist), ok1)

# A block's literal/length and distance tables, then its data.
def Inf.tables(st: Inf, +lit: List<&2, U32>, +dist: List<&2, U32>) -> Inf:
  Inf.tables.one(Inf.t1(st, lit), dist)

def Inf.sym1(st: Inf, +i: U32) -> Inf & U32:
  match st:
    case Inf{m, win, pos, total, c1, s1, c2, s2, last, crc, ct, out, size}:
      Inf.sym1.go(Array.get(U32, s1, i), m, win, pos, total, c1, c2, s2, last, crc, ct, out, size)

def Inf.sym2(st: Inf, +i: U32) -> Inf & U32:
  match st:
    case Inf{m, win, pos, total, c1, s1, c2, s2, last, crc, ct, out, size}:
      Inf.sym2.go(Array.get(U32, s2, i), m, win, pos, total, c1, s1, c2, last, crc, ct, out, size)

# The modes, a bit at a time
# --------------------------

def Inf.set_last(st: Inf, l: Bool) -> Inf:
  match st:
    case Inf{m, win, pos, total, c1, s1, c2, s2, last, crc, ct, out, size}:
      Inf{m, win, pos, total, c1, s1, c2, s2, l, crc, ct, out, size}

def Inf.head.go(st: Inf, ty: U32) -> Inf:
  match ty:
    case 0:
      Inf.mode(st, IAlign{})
    case 1:
      Inf.tables(st, Tb.fixed_lit(), Tb.fixed_dist())
    case 2:
      Inf.mode(st, IDyn{0, 0})
    case _:
      Inf.bad(st, "block type 3")

def Inf.head(st: Inf, +v: U32) -> Inf:
  Inf.head.go(Inf.set_last(st, U32.is_eq(U32.and(v, 1), 1)), U32.shr(v))

def Inf.slen.go(st: Inf, +len: U32, ok: Bool, empty: Bool) -> Inf:
  match ok empty:
    case False{} e:
      Inf.bad(st, "a stored block's length and its complement disagree")
    case True{} True{}:
      Inf.end_block(st)
    case True{} False{}:
      Inf.mode(st, IStored{len})

def Inf.slen(st: Inf, +v: U32) -> Inf:
  Inf.slen.go(st, U32.and(v, 65535), U32.is_eq(U32.xor(U32.and(v, 65535), U32.shrn(v, 16n)), 65535),
    U32.is_zero(U32.and(v, 65535)))

def Inf.pick.go(+l: U32, rest: U32, hit: Bool) -> U32:
  match hit:
    case True{}:
      l
    case False{}:
      rest

def Inf.pick(+i: U32, ps: List<&2, U32>, ls: List<&2, U32>) -> U32:
  match ps ls:
    case Con{+p, pt} Con{+l, lt}:
      Inf.pick.go(l, Inf.pick(i, pt, lt), U32.is_eq(p, i))
    case x y:
      0

def Inf.cl_lens(n: Nat, +i: U32, +lens: List<&2, U32>) -> List<&2, U32>:
  match n:
    case 0n:
      Nil{}
    case 1n+k:
      Con{Inf.pick(i, Inf.order(), lens), Inf.cl_lens(k, U32.add(i, 1), lens)}

def Inf.lens_start(st: Inf, +hlit: U32, +hdist: U32) -> Inf:
  match st:
    case Inf{m, win, pos, total, +c1, s1, c2, s2, last, crc, ct, out, size}:
      Inf{ILens{hlit, hdist, Nil{}, 0, Inf.hd(c1)}, win, pos, total, c1, s1, c2, s2, last, crc, ct, out, size}

def Inf.cl_built(p: Inf & Bool, +hlit: U32, +hdist: U32) -> Inf:
  match p:
    case (st, True{}):
      Inf.lens_start(st, hlit, hdist)
    case (st, False{}):
      Inf.bad(st, "an over-subscribed code length code")

# The code length code is whole: its table, then the code lengths.
def Inf.cl_done(st: Inf, +hlit: U32, +hdist: U32, +lens: List<&2, U32>) -> Inf:
  Inf.cl_built(Inf.t1(st, Inf.cl_lens(19n, 0, lens)), hlit, hdist)

def Inf.lens_done.go(st: Inf, +all: List<&2, U32>, +hlit: U32, eob: Bool) -> Inf:
  match eob:
    case True{}:
      Inf.tables(st, List.take(&2, U32, all, U32.to_nat(hlit)), List.drop(&2, U32, all, U32.to_nat(hlit)))
    case False{}:
      Inf.bad(st, "no end-of-block code")

def Inf.lens_done(st: Inf, +hlit: U32, got: List<&2, U32>) -> Inf:
  +all = List.reverse(&2, U32, got)
  Inf.lens_done.go(st, all, hlit, Bool.not(U32.is_zero(Maybe.default(&2, U32, List.get(&2, U32, all, 256n), 0))))

def Inf.lens_more(st: Inf, +hlit: U32, +hdist: U32, got: List<&2, U32>, +n: U32) -> Inf:
  match st:
    case Inf{m, win, pos, total, +c1, s1, c2, s2, last, crc, ct, out, size}:
      Inf{ILens{hlit, hdist, got, n, Inf.hd(c1)}, win, pos, total, c1, s1, c2, s2, last, crc, ct, out, size}

def Inf.lens_add.go(st: Inf, +hlit: U32, +hdist: U32, got: List<&2, U32>, +n: U32, over: Bool, done: Bool) -> Inf:
  match over done:
    case True{} d:
      Inf.bad(st, "more code lengths than codes")
    case False{} True{}:
      Inf.lens_done(st, hlit, got)
    case False{} False{}:
      Inf.lens_more(st, hlit, hdist, got, n)

def Inf.lens_add(st: Inf, +hlit: U32, +hdist: U32, got: List<&2, U32>, +n: U32) -> Inf:
  Inf.lens_add.go(st, hlit, hdist, got, n, U32.is_gt(n, U32.add(hlit, hdist)), U32.is_eq(n, U32.add(hlit, hdist)))

def Inf.cl_sym.go(st: Inf, lit: Bool, +sym: U32, +hlit: U32, +hdist: U32, +got: List<&2, U32>, +n: U32) -> Inf:
  match lit:
    case True{}:
      Inf.lens_add(st, hlit, hdist, Con{sym, got}, U32.add(n, 1))
    case False{}:
      match sym:
        case 16:
          match got:
            case Nil{}:
              Inf.bad(st, "a repeat with no length before it")
            case Con{+prev, t}:
              Inf.mode(st, IRep{hlit, hdist, Con{prev, t}, n, 2, 0, 0, 3, prev})
        case 17:
          Inf.mode(st, IRep{hlit, hdist, got, n, 3, 0, 0, 3, 0})
        case _:
          Inf.mode(st, IRep{hlit, hdist, got, n, 7, 0, 0, 11, 0})

def Inf.cl_sym(p: Inf & U32, +hlit: U32, +hdist: U32, +got: List<&2, U32>, +n: U32) -> Inf:
  match p:
    case (st, +sym):
      Inf.cl_sym.go(st, U32.is_lt(sym, 16), sym, hlit, hdist, got, n)

def Inf.len.go(st: Inf, ld: LD) -> Inf:
  match ld:
    case LD{+base, +extra}:
      match extra:
        case 0:
          Inf.dist(st, base)
        case 255:
          Inf.bad(st, "a bad length code")
        case _:
          Inf.mode(st, ILenX{base, extra, 0, 0})

def Inf.lit.go(st: Inf, +sym: U32, lit: Bool, eob: Bool) -> Inf:
  match lit eob:
    case True{} e:
      Inf.block(Inf.put(st, sym))
    case False{} True{}:
      Inf.end_block(st)
    case False{} False{}:
      Inf.len.go(st, Inf.len_base(U32.sub(sym, 257)))

def Inf.lit(p: Inf & U32) -> Inf:
  match p:
    case (st, +sym):
      Inf.lit.go(st, sym, U32.is_lt(sym, 256), U32.is_eq(sym, 256))

def Inf.dsym.go(st: Inf, +len: U32, ld: LD) -> Inf:
  match ld:
    case LD{+base, +extra}:
      match extra:
        case 0:
          Inf.match(Inf.total_of(st), len, base)
        case 255:
          Inf.bad(st, "a bad distance code")
        case _:
          Inf.mode(st, IDistX{len, base, extra, 0, 0})

def Inf.dsym(p: Inf & U32, +len: U32) -> Inf:
  match p:
    case (st, +sym):
      Inf.dsym.go(st, len, Inf.dist_base(sym))

def Inf.got(+k: U32, +v: U32, +bit: U32) -> U32:
  U32.or(v, U32.shln(bit, U32.to_nat(k)))

def Inf.step.head(st: Inf, +k: U32, +v: U32, done: Bool) -> Inf:
  match done:
    case True{}:
      Inf.head(st, v)
    case False{}:
      Inf.mode(st, IHead{U32.add(k, 1), v})

def Inf.step.slen(st: Inf, +k: U32, +v: U32, done: Bool) -> Inf:
  match done:
    case True{}:
      Inf.slen(st, v)
    case False{}:
      Inf.mode(st, ISLen{U32.add(k, 1), v})

def Inf.step.dyn(st: Inf, +k: U32, +v: U32, done: Bool) -> Inf:
  match done:
    case True{}:
      Inf.mode(st, ICl{U32.add(257, U32.and(v, 31)), U32.add(1, U32.and(U32.shrn(v, 5n), 31)), U32.add(4, U32.shrn(v, 10n)),
        0, 0, Nil{}})
    case False{}:
      Inf.mode(st, IDyn{U32.add(k, 1), v})

def Inf.step.cl(st: Inf, +hlit: U32, +hdist: U32, +left: U32, +k: U32, +v: U32, lens: List<&2, U32>, done: Bool, last: Bool) -> Inf:
  match done last:
    case True{} True{}:
      Inf.cl_done(st, hlit, hdist, List.reverse(&2, U32, Con{v, lens}))
    case True{} False{}:
      Inf.mode(st, ICl{hlit, hdist, U32.sub(left, 1), 0, 0, Con{v, lens}})
    case False{} l:
      Inf.mode(st, ICl{hlit, hdist, left, U32.add(k, 1), v, lens})

def Inf.step.rep(st: Inf, +hlit: U32, +hdist: U32, got: List<&2, U32>, +n: U32, +need: U32, +k: U32, +v: U32,
  +base: U32, +val: U32, done: Bool) -> Inf:
  match done:
    case True{}:
      Inf.lens_add(st, hlit, hdist, List.append(&2, U32, List.replicate(U32, U32.to_nat(U32.add(base, v)), val), got),
        U32.add(n, U32.add(base, v)))
    case False{}:
      Inf.mode(st, IRep{hlit, hdist, got, n, need, U32.add(k, 1), v, base, val})

def Inf.step.lenx(st: Inf, +base: U32, +need: U32, +k: U32, +v: U32, done: Bool) -> Inf:
  match done:
    case True{}:
      Inf.dist(st, U32.add(base, v))
    case False{}:
      Inf.mode(st, ILenX{base, need, U32.add(k, 1), v})

def Inf.step.distx(st: Inf, +len: U32, +base: U32, +need: U32, +k: U32, +v: U32, done: Bool) -> Inf:
  match done:
    case True{}:
      Inf.match(Inf.total_of(st), len, U32.add(base, v))
    case False{}:
      Inf.mode(st, IDistX{len, base, need, U32.add(k, 1), v})

def Inf.step.huff(st: Inf, r: HStep, +which: U32, +hlit: U32, +hdist: U32, +got: List<&2, U32>, +n: U32, +len: U32) -> Inf:
  match r which:
    case HFail{} w:
      Inf.bad(st, "a bad Huffman code")
    case HMore{h} 0:
      Inf.mode(st, ILens{hlit, hdist, got, n, h})
    case HMore{h} 1:
      Inf.mode(st, IBlock{h})
    case HMore{h} w:
      Inf.mode(st, IDist{len, h})
    case HSym{+i} 0:
      Inf.cl_sym(Inf.sym1(st, i), hlit, hdist, got, n)
    case HSym{+i} 1:
      Inf.lit(Inf.sym1(st, i))
    case HSym{+i} w:
      Inf.dsym(Inf.sym2(st, i), len)

# One bit in mode m (st's own mode is a placeholder).
def Inf.step(m: IM, st: Inf, +bit: U32) -> Inf:
  match m:
    case IHead{+k, +v}:
      Inf.step.head(st, k, Inf.got(k, v, bit), U32.is_eq(k, 2))
    case IAlign{}:
      Inf.mode(st, IAlign{})
    case ISLen{+k, +v}:
      Inf.step.slen(st, k, Inf.got(k, v, bit), U32.is_eq(k, 31))
    case IStored{left}:
      Inf.mode(st, IStored{left})
    case IDyn{+k, +v}:
      Inf.step.dyn(st, k, Inf.got(k, v, bit), U32.is_eq(k, 13))
    case ICl{hlit, hdist, +left, +k, +v, lens}:
      Inf.step.cl(st, hlit, hdist, left, k, Inf.got(k, v, bit), lens, U32.is_eq(k, 2), U32.is_eq(left, 1))
    case ILens{hlit, hdist, got, n, h}:
      Inf.step.huff(st, Inf.hbit(h, bit), 0, hlit, hdist, got, n, 0)
    case IRep{hlit, hdist, got, n, +need, +k, +v, base, val}:
      Inf.step.rep(st, hlit, hdist, got, n, need, k, Inf.got(k, v, bit), base, val, U32.is_eq(U32.add(k, 1), need))
    case IBlock{h}:
      Inf.step.huff(st, Inf.hbit(h, bit), 1, 0, 0, Nil{}, 0, 0)
    case ILenX{base, +need, +k, +v}:
      Inf.step.lenx(st, base, need, k, Inf.got(k, v, bit), U32.is_eq(U32.add(k, 1), need))
    case IDist{len, h}:
      Inf.step.huff(st, Inf.hbit(h, bit), 2, 0, 0, Nil{}, 0, len)
    case IDistX{len, base, +need, +k, +v}:
      Inf.step.distx(st, len, base, need, k, Inf.got(k, v, bit), U32.is_eq(U32.add(k, 1), need))
    case IDone{}:
      Inf.mode(st, IDone{})
    case IBad{why}:
      Inf.mode(st, IBad{why})

def Inf.bit(st: Inf, +bit: U32) -> Inf:
  match st:
    case Inf{m, win, pos, total, c1, s1, c2, s2, last, crc, ct, out, size}:
      Inf.step(m, Inf{IDone{}, win, pos, total, c1, s1, c2, s2, last, crc, ct, out, size}, bit)

# The decoder with its mode beside it.
type IP is Type:
  IP{st: Inf, m: IM}

def Inf.peek(st: Inf) -> IP:
  match st:
    case Inf{+m, win, pos, total, c1, s1, c2, s2, last, crc, ct, out, size}:
      IP{Inf{m, win, pos, total, c1, s1, c2, s2, last, crc, ct, out, size}, m}

# The bits of a byte, least significant first; a stored block's alignment
# drops the rest, and the end of the stream ignores them.
def Inf.bits(i: Nat, +b: U32, ev: IP) -> Inf:
  match i ev:
    case 0n IP{st, mm}:
      st
    case 1n+r IP{st, IAlign{}}:
      Inf.mode(st, ISLen{0, 0})
    case 1n+r IP{st, IDone{}}:
      st
    case 1n+r IP{st, IBad{w}}:
      st
    case 1n+r IP{st, mm}:
      Inf.bits(r, U32.shr(b), Inf.peek(Inf.bit(st, U32.and(b, 1))))

def Inf.stored(st: Inf, +left: U32, last: Bool) -> Inf:
  match last:
    case True{}:
      Inf.end_block(st)
    case False{}:
      Inf.mode(st, IStored{U32.sub(left, 1)})

def Inf.byte.go(ev: IP, +b: U32) -> Inf:
  match ev:
    case IP{st, IStored{+left}}:
      Inf.stored(Inf.put(st, b), left, U32.is_eq(left, 1))
    case IP{st, IAlign{}}:
      Inf.bits(8n, b, Inf.peek(Inf.mode(st, ISLen{0, 0})))
    case IP{st, IDone{}}:
      st
    case IP{st, mm}:
      Inf.bits(8n, b, IP{st, mm})

# One byte of a DEFLATE stream.
def Inf.byte(st: Inf, +b: U32) -> Inf:
  Inf.byte.go(Inf.peek(st), b)

# A new DEFLATE stream (the window is kept, but nothing reaches before
# the start).
def Inf.new() -> Inf:
  Inf{IHead{0, 0}, [0 : U32*32768n], 0, 0, Nil{}, [0 : U32*512n], Nil{}, [0 : U32*512n], False{}, 4294967295,
    Crc.table(), Nil{}, 0}

def Inf.restart(st: Inf) -> Inf:
  match st:
    case Inf{m, win, pos, total, c1, s1, c2, s2, last, crc, ct, out, size}:
      Inf{IHead{0, 0}, win, pos, 0, c1, s1, c2, s2, last, 4294967295, ct, out, 0}

# The bytes out since the last take, in order.
def Inf.take(st: Inf) -> Inf & List<&2, U32>:
  match st:
    case Inf{m, win, pos, total, c1, s1, c2, s2, last, crc, ct, out, size}:
      (Inf{m, win, pos, total, c1, s1, c2, s2, last, crc, ct, Nil{}, size}, List.reverse(&2, U32, out))

# The member's CRC-32 and size.
def Inf.sums(st: Inf) -> Inf & (U32 & U32):
  match st:
    case Inf{m, win, pos, total, c1, s1, c2, s2, last, +crc, ct, out, +size}:
      (Inf{m, win, pos, total, c1, s1, c2, s2, last, crc, ct, out, size}, (U32.xor(crc, 4294967295), size))

# The gzip wrapper (RFC 1952)
# ---------------------------

# Where the wrapper is:
#   GH: in the 10-byte header (n read; flg its flags)
#   GXLen: in FEXTRA's length; GX: in FEXTRA's data
#   GZero: in FNAME (comment: False) or FCOMMENT (True), up to a 0 byte
#   GHcrc: in FHCRC
#   GBody: in the DEFLATE data
#   GTrail: in the CRC-32 and ISIZE, acc reversed
#   GNext: between members
#   GBad: refused; it stays here
type GzM is Data:
  GH{n: U32, flg: U32}
  GXLen{k: U32, v: U32, flg: U32}
  GX{left: U32, flg: U32}
  GZero{comment: Bool, flg: U32}
  GHcrc{left: U32}
  GBody{}
  GTrail{n: U32, acc: List<&2, U32>}
  GNext{}
  GBad{why: String}

type Gz is Type:
  Gz{m: GzM, inf: Inf}

# A decoder for a gzip stream of one or more members.
def Gz.new() -> Gz:
  Gz{GH{0, 0}, Inf.new()}

def Gz.bit(+flg: U32, +b: U32) -> Bool:
  Bool.not(U32.is_zero(U32.and(flg, b)))

def Gz.after.go(+flg: U32, x: Bool, n: Bool, c: Bool, h: Bool) -> GzM:
  match x n c h:
    case True{} n2 c2 h2:
      GXLen{0, 0, flg}
    case False{} True{} c2 h2:
      GZero{False{}, flg}
    case False{} False{} True{} h2:
      GZero{True{}, flg}
    case False{} False{} False{} True{}:
      GHcrc{2}
    case False{} False{} False{} False{}:
      GBody{}

# What follows a part of the header (from: 0 the fixed part, 1 FEXTRA,
# 2 FNAME, 3 FCOMMENT), by its flags.
def Gz.after(+flg: U32, +from: U32) -> GzM:
  Gz.after.go(flg, U32.is_le(from, 0) && Gz.bit(flg, 4), U32.is_le(from, 1) && Gz.bit(flg, 8),
    U32.is_le(from, 2) && Gz.bit(flg, 16), Gz.bit(flg, 2))

def Gz.expect(inf: Inf, ok: Bool, next: GzM, why: String) -> Gz:
  match ok:
    case True{}:
      Gz{next, inf}
    case False{}:
      Gz{GBad{why}, inf}

def Gz.hdr(inf: Inf, n: U32, +flg: U32, +b: U32) -> Gz:
  match n:
    case 0:
      Gz.expect(inf, U32.is_eq(b, 31), GH{1, 0}, "not a gzip stream")
    case 1:
      Gz.expect(inf, U32.is_eq(b, 139), GH{2, 0}, "not a gzip stream")
    case 2:
      Gz.expect(inf, U32.is_eq(b, 8), GH{3, 0}, "a gzip member not compressed with DEFLATE")
    case 3:
      Gz.expect(inf, U32.is_zero(U32.and(b, 224)), GH{4, b}, "reserved gzip flags set")
    case 9:
      Gz{Gz.after(flg, 0), inf}
    case _:
      Gz{GH{U32.add(n, 1), flg}, inf}

def Gz.xlen(inf: Inf, +k: U32, +v: U32, +flg: U32, last: Bool, none: Bool) -> Gz:
  match last none:
    case False{} x:
      Gz{GXLen{1, v, flg}, inf}
    case True{} True{}:
      Gz{Gz.after(flg, 1), inf}
    case True{} False{}:
      Gz{GX{v, flg}, inf}

def Gz.extra(inf: Inf, +left: U32, +flg: U32, last: Bool) -> Gz:
  match last:
    case True{}:
      Gz{Gz.after(flg, 1), inf}
    case False{}:
      Gz{GX{U32.sub(left, 1), flg}, inf}

def Gz.zero(inf: Inf, +flg: U32, end: Bool, comment: Bool) -> Gz:
  match end comment:
    case True{} True{}:
      Gz{Gz.after(flg, 3), inf}
    case True{} False{}:
      Gz{Gz.after(flg, 2), inf}
    case False{} c:
      Gz{GZero{c, flg}, inf}

def Gz.hcrc(inf: Inf, +left: U32, last: Bool) -> Gz:
  match last:
    case True{}:
      Gz{GBody{}, inf}
    case False{}:
      Gz{GHcrc{U32.sub(left, 1)}, inf}

def Gz.body(ev: IP) -> Gz:
  match ev:
    case IP{st, IDone{}}:
      Gz{GTrail{0, Nil{}}, st}
    case IP{st, IBad{w}}:
      Gz{GBad{w}, st}
    case IP{st, mm}:
      Gz{GBody{}, st}

def Gz.le32(bs: List<&2, U32>) -> U32:
  match bs:
    case Con{a, Con{b, Con{c, Con{d, t}}}}:
      U32.or(a, U32.or(U32.shln(b, 8n), U32.or(U32.shln(c, 16n), U32.shln(d, 24n))))
    case _:
      0

def Gz.trail.go(st: Inf, crc_ok: Bool, size_ok: Bool) -> Gz:
  match crc_ok size_ok:
    case False{} s:
      Gz{GBad{"the member's CRC-32 does not match its data"}, st}
    case True{} False{}:
      Gz{GBad{"the member's size does not match its data"}, st}
    case True{} True{}:
      Gz{GNext{}, st}

def Gz.trail(p: Inf & (U32 & U32), +tr: List<&2, U32>) -> Gz:
  match p:
    case (st, (crc, size)):
      Gz.trail.go(st, U32.is_eq(crc, Gz.le32(tr)), U32.is_eq(size, Gz.le32(List.drop(&2, U32, tr, 4n))))

def Gz.trailer(inf: Inf, +n: U32, acc: List<&2, U32>, last: Bool) -> Gz:
  match last:
    case True{}:
      Gz.trail(Inf.sums(inf), List.reverse(&2, U32, acc))
    case False{}:
      Gz{GTrail{U32.add(n, 1), acc}, inf}

def Gz.next(inf: Inf, magic: Bool) -> Gz:
  match magic:
    case True{}:
      Gz{GH{1, 0}, Inf.restart(inf)}
    case False{}:
      Gz{GBad{"bytes after the gzip stream"}, inf}

def Gz.step(m: GzM, inf: Inf, +b: U32) -> Gz:
  match m:
    case GH{n, flg}:
      Gz.hdr(inf, n, flg, b)
    case GXLen{+k, +v, flg}:
      +nv = U32.or(v, U32.shln(b, U32.to_nat(U32.mul(k, 8))))
      Gz.xlen(inf, k, nv, flg, U32.is_eq(k, 1), U32.is_zero(nv))
    case GX{+left, +flg}:
      Gz.extra(inf, left, flg, U32.is_eq(left, 1))
    case GZero{comment, +flg}:
      Gz.zero(inf, flg, U32.is_zero(b), comment)
    case GHcrc{+left}:
      Gz.hcrc(inf, left, U32.is_eq(left, 1))
    case GBody{}:
      Gz.body(Inf.peek(Inf.byte(inf, b)))
    case GTrail{+n, acc}:
      Gz.trailer(inf, n, Con{b, acc}, U32.is_eq(n, 7))
    case GNext{}:
      Gz.next(inf, U32.is_eq(b, 31))
    case GBad{why}:
      Gz{GBad{why}, inf}

def Gz.byte(g: Gz, +b: U32) -> Gz:
  match g:
    case Gz{m, inf}:
      Gz.step(m, inf, b)

def Gz.feed.go(bs: List<&2, U32>, g: Gz) -> Gz:
  match bs:
    case Nil{}:
      g
    case Con{+b, t}:
      Gz.feed.go(t, Gz.byte(g, b))

type GzOut is Type:
  GzOut{g: Gz, out: List<&2, U32>}

def Gz.out.go(m: GzM, p: Inf & List<&2, U32>) -> GzOut:
  match p:
    case (st, out):
      GzOut{Gz{m, st}, out}

def Gz.out(g: Gz) -> GzOut:
  match g:
    case Gz{m, inf}:
      Gz.out.go(m, Inf.take(inf))

# Feeds compressed bytes: the decoder, and the bytes they decompress to.
def Gz.feed(g: Gz, bs: List<&2, U32>) -> GzOut:
  Gz.out(Gz.feed.go(bs, g))

# Whether the stream ended whole: every member's data, CRC and size.
def Gz.finish(g: Gz) -> Result<&2, &2, String, Unit>:
  match g:
    case Gz{GNext{}, inf}:
      Done{Unit{}}
    case Gz{GBad{why}, inf}:
      Fail{why}
    case Gz{m, inf}:
      Fail{"the gzip stream ends early"}

def Gz.whole.go(r: Result<&2, &2, String, Unit>, out: List<&2, U32>) -> Result<&2, &2, String, List<&2, U32>>:
  match r:
    case Fail{e}:
      Fail{e}
    case Done{u}:
      Done{out}

def Gz.whole(o: GzOut) -> Result<&2, &2, String, List<&2, U32>>:
  match o:
    case GzOut{g, out}:
      Gz.whole.go(Gz.finish(g), out)

# A whole gzip stream, decompressed.
def Gz.inflate(bs: List<&2, U32>) -> Result<&2, &2, String, List<&2, U32>>:
  Gz.whole(Gz.feed(Gz.new(), bs))
