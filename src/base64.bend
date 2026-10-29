import Base

# Base64
# ======
#
# The standard alphabet (RFC 4648 section 4), as kubeconfig's *-data fields
# and Secret data use it. Decoding skips whitespace and padding; a char
# outside the alphabet fails the whole decode.

type B64 is Data:
  B64{acc: U32, bits: U32, ok: Bool}

def B64.val.go(+x: U32, up: Bool, low: Bool, dig: Bool) -> U32:
  match up low dig:
    case True{} _ _:
      (x - 65 : U32)
    case False{} True{} _:
      (x - 71 : U32)
    case False{} False{} True{}:
      (x + 4 : U32)
    case _ _ _:
      65

# The 6-bit value of a char: 64 for skipped chars, 65 for bad ones.
def B64.val(+c: Char) -> U32:
  match c:
    case '+':
      62
    case '/':
      63
    case '=':
      64
    case ' ':
      64
    case '\n':
      64
    case '\r':
      64
    case '\t':
      64
    case Chr{+x}:
      B64.val.go(x, Char.is_upper(Chr{x}), Char.is_lower(Chr{x}), Char.is_digit(Chr{x}))

def B64.next.go(+acc: U32, +bits: U32, ok: Bool, +v: U32, skip: Bool, bad: Bool, full: Bool) ->
  B64:
  match skip bad full:
    case True{} _ _:
      B64{acc, bits, ok}
    case False{} True{} _:
      B64{acc, bits, False{}}
    case False{} False{} True{}:
      # 8 bits are ready: the byte leaves, bits - 2 stay
      B64{(((acc << 6n) .|. v) .&. ((1 << U32.to_nat((bits - 2 : U32))) - 1) : U32),
        (bits - 2 : U32), ok}
    case False{} False{} False{}:
      B64{((acc << 6n) .|. v : U32), (bits + 6 : U32), ok}

# The state after a char's value v.
def B64.next(st: B64, +v: U32) -> B64:
  match st:
    case B64{+acc, +bits, ok}:
      B64.next.go(acc, bits, ok, v, U32.is_eq(v, 64), U32.is_eq(v, 65), U32.is_ge(bits, 2))

def B64.emit.go(+acc: U32, +bits: U32, +v: U32, out: List<&2, U32>, skip: Bool, full: Bool) ->
  List<&2, U32>:
  match skip full:
    case False{} True{}:
      ((((acc << 6n) .|. v) >> U32.to_nat((bits - 2 : U32))) .&. 255 : U32) <> out
    case _ _:
      out

# The byte a char completes, pushed onto out (reversed).
def B64.emit(st: B64, +v: U32, out: List<&2, U32>) -> List<&2, U32>:
  match st:
    case B64{+acc, +bits, ok}:
      B64.emit.go(acc, bits, v, out, U32.is_ge(v, 64), U32.is_ge(bits, 2))

def B64.go(s: String, +st: B64, out: List<&2, U32>) -> B64 & List<&2, U32>:
  match s:
    case SNil{}:
      (st, out)
    case SCon{+c, t}:
      B64.go(t, B64.next(st, B64.val(c)), B64.emit(st, B64.val(c), out))

def B64.decode.fin(r: B64 & List<&2, U32>) -> Maybe<&2, List<&2, U32>>:
  match r:
    case (B64{acc, bits, True{}}, out):
      Some{List.reverse(&2, U32, out)}
    case _:
      None{}

# The bytes a base64 text spells; None if a char is outside the alphabet.
def B64.decode(s: String) -> Maybe<&2, List<&2, U32>>:
  B64.decode.fin(B64.go(s, B64{0, 0, True{}}, Nil{}))

def B64.chr.go(+v: U32, up: Bool, low: Bool, dig: Bool, plus: Bool) -> Char:
  match up low dig plus:
    case True{} _ _ _:
      Chr{(v + 65 : U32)}
    case False{} True{} _ _:
      Chr{(v + 71 : U32)}
    case False{} False{} True{} _:
      Chr{(v - 4 : U32)}
    case False{} False{} False{} True{}:
      '+'
    case _ _ _ _:
      '/'

def B64.chr(+v: U32) -> Char:
  B64.chr.go(v, U32.is_lt(v, 26), U32.is_lt(v, 52), U32.is_lt(v, 62), U32.is_eq(v, 62))

# Encodes bytes, three at a time, with '=' padding.
def B64.encode(bs: List<&2, U32>) -> String:
  match bs:
    case Nil{}:
      ""
    case Con{+a, Nil{}}:
      SCon{B64.chr((a >> 2n : U32)), SCon{B64.chr(((a .&. 3) << 4n : U32)), "=="}}
    case Con{+a, Con{+b, Nil{}}}:
      SCon{B64.chr((a >> 2n : U32)), SCon{B64.chr((((a .&. 3) << 4n) .|. (b >> 4n) : U32)),
        SCon{B64.chr(((b .&. 15) << 2n : U32)), "="}}}
    case Con{+a, Con{+b, Con{+c, t}}}:
      SCon{B64.chr((a >> 2n : U32)), SCon{B64.chr((((a .&. 3) << 4n) .|. (b >> 4n) : U32)),
        SCon{B64.chr((((b .&. 15) << 2n) .|. (c >> 6n) : U32)), SCon{B64.chr((c .&. 63 : U32)),
          B64.encode(t)}}}}
