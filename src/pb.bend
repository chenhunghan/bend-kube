import Base
import ./utf8.bend as U

# Protobuf
# ========
#
# The protobuf wire format (protobuf.dev/programming-guides/encoding), as
# gRPC carries it. A message is a list of fields, each a field number and
# a wire value; a schema is a pair of hand-written defs that build and read
# such a list. Bytes are List<U32>, one byte per cell, as everywhere in
# bend-kube.
#
# Base has no 64-bit integer, so a varint or fixed64 is a W64: its high
# and low 32 bits. int64 is that word in two's complement, sint64 its
# zigzag (Pb.zigzag), and int32 is sign-extended to 64 bits (Pb.int32).
#
# The decoder reads a byte at a time and refuses groups (wire types 3 and
# 4), field number 0, varints past 10 bytes, a length past Pb.max(), and a
# message that ends inside a field. Fields it does not know are kept, so a
# reader skips them and a proxy can pass them on.

type W64 is Data:
  W64{hi: U32, lo: U32}

# A field's value, by wire type:
#   PVar: 0, a varint
#   PF64: 1, eight little-endian bytes
#   PLen: 2, length-delimited raw bytes: a string, bytes, a nested
#         message (Pb.decode them) or a packed repeated field
#   PF32: 5, four little-endian bytes
type PbVal is Data:
  PVar{v: W64}
  PF64{v: W64}
  PLen{bs: List<&2, U32>}
  PF32{v: U32}

type PbField is Data:
  PbField{num: U32, val: PbVal}

# One entry of a map<string, string>.
type PbStr is Data:
  PbStr{key: String, val: String}

# Where the decoder is.
#   PVint: inside a varint; what is 0 for a key, 1 for a value, 2 for a
#          length; sh is the shift of the next 7 bits
#   PBody: left bytes of a length-delimited value to go, acc reversed
#   PFix: left bytes of a fixed32 (wire 5) or fixed64 (wire 1), acc
#         reversed
#   PBad: a message the decoder refuses; it stays here
type PbSt is Data:
  PVint{what: U32, num: U32, sh: U32, acc: W64}
  PBody{num: U32, left: U32, acc: List<&2, U32>}
  PFix{num: U32, wire: U32, left: U32, acc: List<&2, U32>}
  PBad{why: String}

type PbStep is Data:
  PbStep{st: PbSt, got: Maybe<&2, PbField>}

# The largest length-delimited value the decoder accepts: 64 MiB, past
# gRPC's own default limit of 4 MiB.
def Pb.max() -> U32:
  67108864

def Pb.zero() -> W64:
  W64{0, 0}

def Pb.w64(+x: U32) -> W64:
  W64{0, x}

def Pb.lo(w: W64) -> U32:
  match w:
    case W64{hi, lo}:
      lo

def Pb.hi(w: W64) -> U32:
  match w:
    case W64{hi, lo}:
      hi

def Pb.w64.is_zero(w: W64) -> Bool:
  match w:
    case W64{hi, lo}:
      U32.is_zero(hi) && U32.is_zero(lo)

def Pb.w64.is_eq(a: W64, b: W64) -> Bool:
  match a b:
    case W64{ah, al} W64{bh, bl}:
      U32.is_eq(ah, bh) && U32.is_eq(al, bl)

def Pb.int32.go(+x: U32, neg: Bool) -> W64:
  match neg:
    case True{}:
      W64{4294967295, x}
    case False{}:
      W64{0, x}

# An int32 as protobuf sends it: sign-extended to 64 bits.
def Pb.int32(+x: U32) -> W64:
  Pb.int32.go(x, U32.is_ge(x, 2147483648))

def Pb.zigzag.go(+hi: U32, +lo: U32, neg: Bool) -> W64:
  match neg:
    case True{}:
      W64{U32.not(U32.or(U32.shl(hi), U32.shrn(lo, 31n))), U32.not(U32.shl(lo))}
    case False{}:
      W64{U32.or(U32.shl(hi), U32.shrn(lo, 31n)), U32.shl(lo)}

# sint64: (n << 1) ^ (n >> 63), so small negatives stay short.
def Pb.zigzag(w: W64) -> W64:
  match w:
    case W64{+hi, +lo}:
      Pb.zigzag.go(hi, lo, U32.is_ge(hi, 2147483648))

def Pb.unzigzag.go(+hi: U32, +lo: U32, odd: Bool) -> W64:
  match odd:
    case True{}:
      W64{U32.not(U32.shr(hi)), U32.not(U32.or(U32.shr(lo), U32.shln(hi, 31n)))}
    case False{}:
      W64{U32.shr(hi), U32.or(U32.shr(lo), U32.shln(hi, 31n))}

# The inverse of Pb.zigzag: (n >> 1) ^ -(n & 1).
def Pb.unzigzag(w: W64) -> W64:
  match w:
    case W64{+hi, +lo}:
      Pb.unzigzag.go(hi, lo, U32.is_eq(U32.and(lo, 1), 1))

# Encoding
# --------

def Pb.varint.go(fuel: Nat, +hi: U32, +lo: U32, last: Bool) -> List<&2, U32>:
  match fuel last:
    case 0n l:
      Nil{}
    case 1n+f True{}:
      [lo]
    case 1n+f False{}:
      +nhi = U32.shrn(hi, 7n)
      +nlo = U32.or(U32.shrn(lo, 7n), U32.shln(U32.and(hi, 127), 25n))
      Con{U32.or(128, U32.and(lo, 127)),
        Pb.varint.go(f, nhi, nlo, U32.is_zero(nhi) && U32.is_lt(nlo, 128))}

# A varint: 7 bits a byte, low first, the top bit set on all but the last.
def Pb.varint(w: W64) -> List<&2, U32>:
  match w:
    case W64{+hi, +lo}:
      Pb.varint.go(10n, hi, lo, U32.is_zero(hi) && U32.is_lt(lo, 128))

def Pb.varint32(+x: U32) -> List<&2, U32>:
  Pb.varint(W64{0, x})

# A U32 as four little-endian bytes, before rest.
def Pb.le32(+x: U32, rest: List<&2, U32>) -> List<&2, U32>:
  Con{U32.and(x, 255), Con{U32.and(U32.shrn(x, 8n), 255),
    Con{U32.and(U32.shrn(x, 16n), 255), Con{U32.shrn(x, 24n), rest}}}}

# A field's key: its number and wire type.
def Pb.key(+num: U32, +wire: U32) -> List<&2, U32>:
  Pb.varint32(U32.or(U32.shln(num, 3n), wire))

def Pb.field(f: PbField) -> List<&2, U32>:
  match f:
    case PbField{+num, PVar{v}}:
      List.append(&2, U32, Pb.key(num, 0), Pb.varint(v))
    case PbField{+num, PF64{W64{+hi, +lo}}}:
      List.append(&2, U32, Pb.key(num, 1), Pb.le32(lo, Pb.le32(hi, Nil{})))
    case PbField{+num, PLen{+bs}}:
      List.append(&2, U32, Pb.key(num, 2),
        List.append(&2, U32, Pb.varint32(U32.from_nat(List.length(&2, U32, bs))), bs))
    case PbField{+num, PF32{+v}}:
      List.append(&2, U32, Pb.key(num, 5), Pb.le32(v, Nil{}))

# A message's bytes: its fields in order.
def Pb.encode(msg: List<&2, PbField>) -> List<&2, U32>:
  match msg:
    case Nil{}:
      Nil{}
    case Con{f, t}:
      List.append(&2, U32, Pb.field(f), Pb.encode(t))

# Builders
# --------
#
# Each answers a list of fields, empty for proto3's default value (zero,
# false, an empty string or list), which proto3 does not send. Join them
# with List.concat, or write PbField{..} to send a default on purpose.

def Pb.one(+f: PbField, omit: Bool) -> List<&2, PbField>:
  match omit:
    case True{}:
      Nil{}
    case False{}:
      [f]

# uint64, int64, or an enum or int32 widened by Pb.int32.
def Pb.u64(+num: U32, +v: W64) -> List<&2, PbField>:
  Pb.one(PbField{num, PVar{v}}, Pb.w64.is_zero(v))

def Pb.u32(+num: U32, +v: U32) -> List<&2, PbField>:
  Pb.u64(num, W64{0, v})

def Pb.bool(+num: U32, b: Bool) -> List<&2, PbField>:
  Pb.u32(num, Bool.to_u32(b))

def Pb.fixed64(+num: U32, +v: W64) -> List<&2, PbField>:
  Pb.one(PbField{num, PF64{v}}, Pb.w64.is_zero(v))

def Pb.fixed32(+num: U32, +v: U32) -> List<&2, PbField>:
  Pb.one(PbField{num, PF32{v}}, U32.is_zero(v))

def Pb.bytes(+num: U32, +bs: List<&2, U32>) -> List<&2, PbField>:
  Pb.one(PbField{num, PLen{bs}}, List.is_empty(&2, U32, bs))

def Pb.str(+num: U32, s: String) -> List<&2, PbField>:
  Pb.bytes(num, U.Utf8.encode(s))

# A nested message, sent even when empty: a message field has presence.
def Pb.msg(+num: U32, m: List<&2, PbField>) -> List<&2, PbField>:
  [PbField{num, PLen{Pb.encode(m)}}]

# A repeated message or string field: one field per element.
def Pb.msgs(+num: U32, ms: List<&2, List<&2, PbField>>) -> List<&2, PbField>:
  match ms:
    case Nil{}:
      Nil{}
    case Con{m, t}:
      Con{PbField{num, PLen{Pb.encode(m)}}, Pb.msgs(num, t)}

def Pb.strs(+num: U32, ss: List<&2, String>) -> List<&2, PbField>:
  match ss:
    case Nil{}:
      Nil{}
    case Con{s, t}:
      Con{PbField{num, PLen{U.Utf8.encode(s)}}, Pb.strs(num, t)}

def Pb.packed.go(ws: List<&2, W64>) -> List<&2, U32>:
  match ws:
    case Nil{}:
      Nil{}
    case Con{w, t}:
      List.append(&2, U32, Pb.varint(w), Pb.packed.go(t))

# A packed repeated varint field, as proto3 sends repeated scalars.
def Pb.packed(+num: U32, ws: List<&2, W64>) -> List<&2, PbField>:
  Pb.bytes(num, Pb.packed.go(ws))

# A map<string, string>: one entry message per pair, key 1 and value 2.
def Pb.str_map(+num: U32, kvs: List<&2, PbStr>) -> List<&2, PbField>:
  match kvs:
    case Nil{}:
      Nil{}
    case Con{PbStr{k, v}, t}:
      Con{PbField{num, PLen{Pb.encode(List.append(&2, PbField, Pb.str(1, k), Pb.str(2, v)))}},
        Pb.str_map(num, t)}

# Decoding
# --------

def Pb.put.go(+b: U32, +sh: U32, +hi: U32, +lo: U32, low: Bool, zero: Bool) -> W64:
  match low zero:
    case True{} True{}:
      W64{hi, U32.or(lo, b)}
    case True{} False{}:
      W64{U32.or(hi, U32.shrn(b, U32.to_nat(U32.sub(32, sh)))), U32.or(lo, U32.shln(b, U32.to_nat(sh)))}
    case False{} z:
      W64{U32.or(hi, U32.shln(b, U32.to_nat(U32.sub(sh, 32)))), lo}

# Puts 7 bits b at shift sh of acc; bits past 64 fall off.
def Pb.put(+b: U32, +sh: U32, acc: W64) -> W64:
  match acc:
    case W64{+hi, +lo}:
      Pb.put.go(b, sh, hi, lo, U32.is_lt(sh, 32), U32.is_zero(sh))

def Pb.bad(why: String) -> PbStep:
  PbStep{PBad{why}, None{}}

def Pb.begin() -> PbSt:
  PVint{0, 0, 0, W64{0, 0}}

def Pb.emit(+num: U32, v: PbVal) -> PbStep:
  PbStep{Pb.begin(), Some{PbField{num, v}}}

def Pb.wired(+num: U32, wire: U32) -> PbStep:
  match wire:
    case 0:
      PbStep{PVint{1, num, 0, W64{0, 0}}, None{}}
    case 1:
      PbStep{PFix{num, 1, 8, Nil{}}, None{}}
    case 2:
      PbStep{PVint{2, num, 0, W64{0, 0}}, None{}}
    case 5:
      PbStep{PFix{num, 5, 4, Nil{}}, None{}}
    case _:
      Pb.bad("wire type 3, 4, 6 or 7 is not supported")

# A key is whole: its wire type says what follows.
def Pb.keyed(+num: U32, wire: U32, zero: Bool, big: Bool) -> PbStep:
  match zero big:
    case True{} g:
      Pb.bad("field number 0")
    case False{} True{}:
      Pb.bad("field number past 2^29")
    case False{} False{}:
      Pb.wired(num, wire)

def Pb.sized.go(+num: U32, +len: U32, empty: Bool) -> PbStep:
  match empty:
    case True{}:
      Pb.emit(num, PLen{Nil{}})
    case False{}:
      PbStep{PBody{num, len, Nil{}}, None{}}

def Pb.sized(+num: U32, +len: U32, big: Bool) -> PbStep:
  match big:
    case True{}:
      Pb.bad("a field of " ++ U32.show(len) ++ " bytes is too large")
    case False{}:
      Pb.sized.go(num, len, U32.is_zero(len))

# A varint is whole.
def Pb.vint.done(what: U32, +num: U32, w: W64) -> PbStep:
  match what w:
    case 0 W64{+hi, +lo}:
      Pb.keyed(U32.shrn(lo, 3n), U32.and(lo, 7), U32.is_zero(U32.shrn(lo, 3n)), U32.is_ne(hi, 0))
    case 1 w2:
      Pb.emit(num, PVar{w2})
    case _ W64{+hi, +lo}:
      Pb.sized(num, lo, U32.is_ne(hi, 0) || U32.is_gt(lo, Pb.max()))

def Pb.vint(+what: U32, +num: U32, +sh: U32, acc: W64, last: Bool, long: Bool) -> PbStep:
  match last long:
    case l True{}:
      Pb.bad("a varint longer than 10 bytes")
    case True{} False{}:
      Pb.vint.done(what, num, acc)
    case False{} False{}:
      PbStep{PVint{what, num, U32.add(sh, 7), acc}, None{}}

# Four little-endian bytes, given reversed (most significant first).
def Pb.word(bs: List<&2, U32>) -> U32:
  match bs:
    case [a, b, c, d]:
      U32.or(U32.shln(a, 24n), U32.or(U32.shln(b, 16n), U32.or(U32.shln(c, 8n), d)))
    case _:
      0

def Pb.fixed(+num: U32, wire: U32, +acc: List<&2, U32>) -> PbStep:
  match wire:
    case 1:
      Pb.emit(num, PF64{W64{Pb.word(List.take(&2, U32, acc, 4n)), Pb.word(List.drop(&2, U32, acc, 4n))}})
    case _:
      Pb.emit(num, PF32{Pb.word(acc)})

def Pb.body(+num: U32, +left: U32, acc: List<&2, U32>, last: Bool) -> PbStep:
  match last:
    case True{}:
      Pb.emit(num, PLen{List.reverse(&2, U32, acc)})
    case False{}:
      PbStep{PBody{num, U32.sub(left, 1), acc}, None{}}

def Pb.fix(+num: U32, +wire: U32, +left: U32, +acc: List<&2, U32>, last: Bool) -> PbStep:
  match last:
    case True{}:
      Pb.fixed(num, wire, acc)
    case False{}:
      PbStep{PFix{num, wire, U32.sub(left, 1), acc}, None{}}

# One byte into the decoder.
def Pb.step(st: PbSt, +b: U32) -> PbStep:
  match st:
    case PVint{+what, +num, +sh, acc}:
      Pb.vint(what, num, sh, Pb.put(U32.and(b, 127), sh, acc), U32.is_lt(b, 128), U32.is_ge(sh, 70))
    case PBody{+num, +left, acc}:
      Pb.body(num, left, Con{b, acc}, U32.is_eq(left, 1))
    case PFix{+num, +wire, +left, acc}:
      Pb.fix(num, wire, left, Con{b, acc}, U32.is_eq(left, 1))
    case PBad{why}:
      PbStep{PBad{why}, None{}}

def Pb.add(got: Maybe<&2, PbField>, out: List<&2, PbField>) -> List<&2, PbField>:
  match got:
    case None{}:
      out
    case Some{f}:
      Con{f, out}

# The end of the bytes: only between fields is a message whole.
def Pb.fin(st: PbSt, out: List<&2, PbField>) -> Result<&2, &2, String, List<&2, PbField>>:
  match st:
    case PVint{0, num, 0, acc}:
      Done{List.reverse(&2, PbField, out)}
    case PBad{why}:
      Fail{why}
    case _:
      Fail{"the message ends inside a field"}

def Pb.decode.go(bs: List<&2, U32>, ev: PbStep, out: List<&2, PbField>) ->
  Result<&2, &2, String, List<&2, PbField>>:
  match bs ev:
    case Nil{} PbStep{st, got}:
      Pb.fin(st, Pb.add(got, out))
    case Con{+b, t} PbStep{st, got}:
      Pb.decode.go(t, Pb.step(st, b), Pb.add(got, out))

# A message's fields, in the order they came.
def Pb.decode(bs: List<&2, U32>) -> Result<&2, &2, String, List<&2, PbField>>:
  Pb.decode.go(bs, PbStep{Pb.begin(), None{}}, Nil{})

# One varint after another: ev is the varint so far, or the last byte's
# verdict.
type PbVs is Data:
  PbVs{sh: U32, acc: W64, out: List<&2, W64>}
  PbVsBad{why: String}

def Pb.varints.next(+b: U32, +sh: U32, acc: W64, out: List<&2, W64>, last: Bool, long: Bool) -> PbVs:
  match last long:
    case l True{}:
      PbVsBad{"a varint longer than 10 bytes"}
    case True{} False{}:
      PbVs{0, W64{0, 0}, Con{Pb.put(b, sh, acc), out}}
    case False{} False{}:
      PbVs{U32.add(sh, 7), Pb.put(U32.and(b, 127), sh, acc), out}

def Pb.varints.fin(ev: PbVs) -> Result<&2, &2, String, List<&2, W64>>:
  match ev:
    case PbVs{0, acc, out}:
      Done{List.reverse(&2, W64, out)}
    case PbVs{sh, acc, out}:
      Fail{"a packed field ends inside a varint"}
    case PbVsBad{why}:
      Fail{why}

def Pb.varints.go(bs: List<&2, U32>, ev: PbVs) -> Result<&2, &2, String, List<&2, W64>>:
  match bs ev:
    case Nil{} e:
      Pb.varints.fin(e)
    case Con{+b, t} PbVs{+sh, acc, out}:
      Pb.varints.go(t, Pb.varints.next(b, sh, acc, out, U32.is_lt(b, 128), U32.is_ge(sh, 70)))
    case Con{b, t} PbVsBad{why}:
      Fail{why}

# The varints of a packed repeated field.
def Pb.varints(bs: List<&2, U32>) -> Result<&2, &2, String, List<&2, W64>>:
  Pb.varints.go(bs, PbVs{0, W64{0, 0}, Nil{}})

# Readers
# -------
#
# proto3 reads the last value of a scalar field that came more than once,
# and the default for a field that did not come.

def Pb.pick(v: PbVal, last: Maybe<&2, PbVal>, hit: Bool) -> Maybe<&2, PbVal>:
  match hit:
    case True{}:
      Some{v}
    case False{}:
      last

def Pb.keep(v: PbVal, rest: List<&2, PbVal>, hit: Bool) -> List<&2, PbVal>:
  match hit:
    case True{}:
      Con{v, rest}
    case False{}:
      rest

def Pb.get.go(msg: List<&2, PbField>, +num: U32, last: Maybe<&2, PbVal>) -> Maybe<&2, PbVal>:
  match msg:
    case Nil{}:
      last
    case Con{PbField{n, v}, t}:
      Pb.get.go(t, num, Pb.pick(v, last, U32.is_eq(n, num)))

# The last value of field num.
def Pb.get(msg: List<&2, PbField>, +num: U32) -> Maybe<&2, PbVal>:
  Pb.get.go(msg, num, None{})

# Every value of field num, in order.
def Pb.all(msg: List<&2, PbField>, +num: U32) -> List<&2, PbVal>:
  match msg:
    case Nil{}:
      Nil{}
    case Con{PbField{n, v}, t}:
      Pb.keep(v, Pb.all(t, num), U32.is_eq(n, num))

def Pb.as_u64(m: Maybe<&2, PbVal>) -> W64:
  match m:
    case Some{PVar{v}}:
      v
    case Some{PF64{v}}:
      v
    case Some{PF32{v}}:
      W64{0, v}
    case _:
      W64{0, 0}

def Pb.as_bytes(m: Maybe<&2, PbVal>) -> List<&2, U32>:
  match m:
    case Some{PLen{bs}}:
      bs
    case _:
      Nil{}

# uint64, int64, fixed64 (or a widened 32-bit field); 0 when absent.
def Pb.get_u64(msg: List<&2, PbField>, +num: U32) -> W64:
  Pb.as_u64(Pb.get(msg, num))

# uint32, int32 or an enum: the low 32 bits.
def Pb.get_u32(msg: List<&2, PbField>, +num: U32) -> U32:
  Pb.lo(Pb.get_u64(msg, num))

def Pb.get_bool(msg: List<&2, PbField>, +num: U32) -> Bool:
  Bool.not(Pb.w64.is_zero(Pb.get_u64(msg, num)))

def Pb.get_bytes(msg: List<&2, PbField>, +num: U32) -> List<&2, U32>:
  Pb.as_bytes(Pb.get(msg, num))

def Pb.get_str(msg: List<&2, PbField>, +num: U32) -> String:
  U.Utf8.decode_all(Pb.get_bytes(msg, num))

# A nested message's fields: empty when absent, Fail when it does not
# decode.
def Pb.get_msg(msg: List<&2, PbField>, +num: U32) -> Result<&2, &2, String, List<&2, PbField>>:
  Pb.decode(Pb.get_bytes(msg, num))

def Pb.all_str.go(vs: List<&2, PbVal>) -> List<&2, String>:
  match vs:
    case Nil{}:
      Nil{}
    case Con{v, t}:
      Con{U.Utf8.decode_all(Pb.as_bytes(Some{v})), Pb.all_str.go(t)}

# A repeated string field.
def Pb.all_str(msg: List<&2, PbField>, +num: U32) -> List<&2, String>:
  Pb.all_str.go(Pb.all(msg, num))

def Pb.all_msg.go(vs: List<&2, PbVal>) -> Result<&2, &2, String, List<&2, List<&2, PbField>>>:
  match vs:
    case Nil{}:
      Done{Nil{}}
    case Con{v, t}:
      do Result<&2, &2, String, List<&2, List<&2, PbField>>>:
        m : List<&2, PbField> <- Pb.decode(Pb.as_bytes(Some{v}))
        ms : List<&2, List<&2, PbField>> <- Pb.all_msg.go(t)
        return Con{m, ms}

# A repeated message field, each element decoded.
def Pb.all_msg(msg: List<&2, PbField>, +num: U32) -> Result<&2, &2, String, List<&2, List<&2, PbField>>>:
  Pb.all_msg.go(Pb.all(msg, num))

def Pb.all_u64.one(v: PbVal) -> Result<&2, &2, String, List<&2, W64>>:
  match v:
    case PLen{bs}:
      Pb.varints(bs)
    case _:
      Done{[Pb.as_u64(Some{v})]}

def Pb.all_u64.go(vs: List<&2, PbVal>) -> Result<&2, &2, String, List<&2, W64>>:
  match vs:
    case Nil{}:
      Done{Nil{}}
    case Con{v, t}:
      do Result<&2, &2, String, List<&2, W64>>:
        ws : List<&2, W64> <- Pb.all_u64.one(v)
        rest : List<&2, W64> <- Pb.all_u64.go(t)
        return List.append(&2, W64, ws, rest)

# A repeated varint field, packed or not (a reader must take both).
def Pb.all_u64(msg: List<&2, PbField>, +num: U32) -> Result<&2, &2, String, List<&2, W64>>:
  Pb.all_u64.go(Pb.all(msg, num))

def Pb.str_map.go(ms: List<&2, List<&2, PbField>>) -> List<&2, PbStr>:
  match ms:
    case Nil{}:
      Nil{}
    case Con{+m, t}:
      Con{PbStr{Pb.get_str(m, 1), Pb.get_str(m, 2)}, Pb.str_map.go(t)}

# A map<string, string>; a later entry for a key does not replace an
# earlier one here, so read it with the last one winning.
def Pb.get_str_map(msg: List<&2, PbField>, +num: U32) -> Result<&2, &2, String, List<&2, PbStr>>:
  do Result<&2, &2, String, List<&2, PbStr>>:
    ms : List<&2, List<&2, PbField>> <- Pb.all_msg(msg, num)
    return Pb.str_map.go(ms)
