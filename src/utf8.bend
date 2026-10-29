import Base

# UTF-8
# -----
#
# Bytes arrive in arbitrary cuts, so the decoder carries an unfinished
# sequence across calls: (code so far, continuation bytes still needed).
# A malformed sequence decodes to U+FFFD, as io_str does.

type Utf8 is Data:
  Utf8{code: U32, need: U32}

def Utf8.init() -> Utf8:
  Utf8{0, 0}

def Utf8.bad() -> Char:
  Chr{65533}

def Utf8.lead.go(+b: U32, a: Bool, c: Bool, two: Bool, three: Bool, four: Bool) -> U32:
  match a c two three four:
    case True{} _ _ _ _:
      0
    case False{} True{} _ _ _:
      4
    case False{} False{} True{} _ _:
      1
    case False{} False{} False{} True{} _:
      2
    case False{} False{} False{} False{} True{}:
      3
    case _ _ _ _ _:
      4

# The lead byte's class: 0 ASCII, 1..3 continuation count, 4 invalid.
def Utf8.lead(+b: U32) -> U32:
  Utf8.lead.go(b, U32.is_lt(b, 128), U32.is_lt(b, 194), U32.is_lt(b, 224),
    U32.is_lt(b, 240), U32.is_lt(b, 245))

def Utf8.is_cont(+b: U32) -> Bool:
  U32.is_eq((b .&. 192 : U32), 128)

# The fresh-byte case: the state and the chars a lead byte makes.
def Utf8.fresh.st(+b: U32, +k: U32, mid: Bool) -> Utf8:
  match mid:
    case True{}:
      Utf8{U32.and(b, U32.shrn(63, U32.to_nat(k))), k}
    case False{}:
      Utf8{0, 0}

def Utf8.fresh.out(+b: U32, +k: U32, acc: String, ascii: Bool, bad: Bool) -> String:
  match ascii bad:
    case True{} _:
      SCon{Chr{b}, acc}
    case False{} True{}:
      SCon{Utf8.bad(), acc}
    case False{} False{}:
      acc

def Utf8.fresh.mid(+k: U32) -> Bool:
  Bool.and(Bool.not(U32.is_eq(k, 0)), Bool.not(U32.is_eq(k, 4)))

def Utf8.next.cont.if(+code: U32, +need: U32, done: Bool) -> Utf8:
  match done:
    case True{}:
      Utf8{0, 0}
    case False{}:
      Utf8{code, need}

def Utf8.next.cont(+code: U32, +need: U32) -> Utf8:
  Utf8.next.cont.if(code, need, U32.is_eq(need, 0))

# The state after byte b.
def Utf8.next.go(+code: U32, +need: U32, +b: U32, cont: Bool, idle: Bool) -> Utf8:
  match cont idle:
    case True{} False{}:
      Utf8.next.cont(((code << 6n) .|. (b .&. 63) : U32), (need - 1 : U32))
    case _ _:
      Utf8.fresh.st(b, Utf8.lead(b), Utf8.fresh.mid(Utf8.lead(b)))

def Utf8.next(st: Utf8, +b: U32) -> Utf8:
  match st:
    case Utf8{+code, +need}:
      Utf8.next.go(code, need, b, Utf8.is_cont(b), U32.is_eq(need, 0))

def Utf8.emit.cont(+code: U32, acc: String, done: Bool) -> String:
  match done:
    case True{}:
      SCon{Chr{code}, acc}
    case False{}:
      acc

# The chars byte b completes, pushed onto acc (reversed).
def Utf8.emit.go(+code: U32, +need: U32, +b: U32, acc: String, cont: Bool, idle: Bool) -> String:
  match cont idle:
    case True{} False{}:
      Utf8.emit.cont(((code << 6n) .|. (b .&. 63) : U32), acc, U32.is_eq(need, 1))
    case False{} False{}:
      Utf8.fresh.out(b, Utf8.lead(b), SCon{Utf8.bad(), acc},
        U32.is_eq(Utf8.lead(b), 0), U32.is_eq(Utf8.lead(b), 4))
    case _ _:
      Utf8.fresh.out(b, Utf8.lead(b), acc, U32.is_eq(Utf8.lead(b), 0), U32.is_eq(Utf8.lead(b), 4))

def Utf8.emit(st: Utf8, +b: U32, acc: String) -> String:
  match st:
    case Utf8{+code, +need}:
      Utf8.emit.go(code, need, b, acc, Utf8.is_cont(b), U32.is_eq(need, 0))

# Decodes bytes onto the front of acc (reversed), carrying the state.
def Utf8.go(bs: List<&2, U32>, +st: Utf8, acc: String) -> Utf8 & String:
  match bs:
    case Nil{}:
      (st, acc)
    case Con{+b, t}:
      Utf8.go(t, Utf8.next(st, b), Utf8.emit(st, b, acc))

def Utf8.decode.fin(r: Utf8 & String) -> Utf8 & String:
  match r:
    case (st, acc):
      (st, String.reverse(acc))

# Decodes a cut of bytes; returns the carried state and the text.
def Utf8.decode(st: Utf8, bs: List<&2, U32>) -> Utf8 & String:
  Utf8.decode.fin(Utf8.go(bs, st, SNil{}))

def Utf8.decode_all.tail(s: String, whole: Bool) -> String:
  match whole:
    case True{}:
      s
    case False{}:
      s ++ SCon{Utf8.bad(), SNil{}}

def Utf8.decode_all.fin(r: Utf8 & String) -> String:
  match r:
    case (Utf8{code, need}, s):
      Utf8.decode_all.tail(s, U32.is_eq(need, 0))

# Decodes a whole buffer.
def Utf8.decode_all(bs: List<&2, U32>) -> String:
  Utf8.decode_all.fin(Utf8.decode(Utf8.init(), bs))

def Utf8.put.go(+c: U32, rest: List<&2, U32>, a: Bool, b: Bool, d: Bool) -> List<&2, U32>:
  match a b d:
    case True{} _ _:
      c <> rest
    case False{} True{} _:
      (192 .|. (c >> 6n) : U32) <> (128 .|. (c .&. 63) : U32) <> rest
    case False{} False{} True{}:
      (224 .|. (c >> 12n) : U32) <> (128 .|. ((c >> 6n) .&. 63) : U32)
        <> (128 .|. (c .&. 63) : U32) <> rest
    case _ _ _:
      (240 .|. (c >> 18n) : U32) <> (128 .|. ((c >> 12n) .&. 63) : U32)
        <> (128 .|. ((c >> 6n) .&. 63) : U32) <> (128 .|. (c .&. 63) : U32) <> rest

def Utf8.put(+c: U32, rest: List<&2, U32>) -> List<&2, U32>:
  Utf8.put.go(c, rest, U32.is_lt(c, 128), U32.is_lt(c, 2048), U32.is_lt(c, 65536))

def Utf8.encode(s: String) -> List<&2, U32>:
  match s:
    case SNil{}:
      Nil{}
    case SCon{Chr{c}, t}:
      Utf8.put(c, Utf8.encode(t))

def Utf8.size.of(+c: U32, a: Bool, b: Bool, d: Bool) -> U32:
  match a b d:
    case True{} _ _:
      1
    case False{} True{} _:
      2
    case False{} False{} True{}:
      3
    case _ _ _:
      4

# The UTF-8 length of a string, in bytes.
def Utf8.size(s: String) -> U32:
  match s:
    case SNil{}:
      0
    case SCon{Chr{+c}, t}:
      (Utf8.size.of(c, U32.is_lt(c, 128), U32.is_lt(c, 2048), U32.is_lt(c, 65536))
        + Utf8.size(t) : U32)
