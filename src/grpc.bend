import Base
import ./http.bend as H
import ./utf8.bend as U

# gRPC
# ====
#
# The pure part of gRPC over HTTP/2 (github.com/grpc/grpc, doc/
# PROTOCOL-HTTP2.md): length-prefixed messages, status codes, the
# grpc-timeout header and grpc-message's percent-encoding, and the
# headers a call and its answer carry. grpcio.bend runs calls over
# h2io.bend. No compression: a compressed message is refused.

type GStatus is Data:
  GStatus{code: U32, msg: String}

def GStatus.msg(st: GStatus) -> String:
  match st:
    case GStatus{c, m}:
      m

# Status codes.
def Grpc.ok() -> U32:
  0

def Grpc.cancelled() -> U32:
  1

def Grpc.unknown() -> U32:
  2

def Grpc.invalid_argument() -> U32:
  3

def Grpc.deadline_exceeded() -> U32:
  4

def Grpc.not_found() -> U32:
  5

def Grpc.already_exists() -> U32:
  6

def Grpc.permission_denied() -> U32:
  7

def Grpc.resource_exhausted() -> U32:
  8

def Grpc.failed_precondition() -> U32:
  9

def Grpc.aborted() -> U32:
  10

def Grpc.out_of_range() -> U32:
  11

def Grpc.unimplemented() -> U32:
  12

def Grpc.internal() -> U32:
  13

def Grpc.unavailable() -> U32:
  14

def Grpc.data_loss() -> U32:
  15

def Grpc.unauthenticated() -> U32:
  16

# The largest message either side takes: gRPC's default, 4 MiB.
def Grpc.max() -> U32:
  4194304

# Messages
# --------

def Grpc.len(bs: List<&2, U32>) -> U32:
  U32.from_nat(List.length(&2, U32, bs))

# A message on the wire: no compression, its length (4 bytes, big-endian),
# its bytes.
def Grpc.frame(msg: List<&2, U32>) -> List<&2, U32>:
  +m = msg
  +n = Grpc.len(m)
  Con{0, Con{U32.shrn(n, 24n), Con{U32.and(U32.shrn(n, 16n), 255), Con{U32.and(U32.shrn(n, 8n), 255),
    Con{U32.and(n, 255), m}}}}}

def Grpc.frames(ms: List<&2, List<&2, U32>>) -> List<&2, U32>:
  match ms:
    case Nil{}:
      Nil{}
    case Con{m, t}:
      List.append(&2, U32, Grpc.frame(m), Grpc.frames(t))

# Reading messages, a byte at a time:
#   GHead: header bytes so far, reversed
#   GBody: left bytes of a message to go, acc reversed
#   GBad: refused
type GRd is Data:
  GHead{n: U32, acc: List<&2, U32>}
  GBody{left: U32, acc: List<&2, U32>}
  GBad{st: GStatus}

type GStep is Data:
  GStep{rd: GRd, got: Maybe<&2, List<&2, U32>>}

def Grpc.rd_len(+len: U32, flag: U32, big: Bool, empty: Bool) -> GStep:
  match flag big empty:
    case 0 False{} True{}:
      GStep{GHead{0, Nil{}}, Some{Nil{}}}
    case 0 False{} False{}:
      GStep{GBody{len, Nil{}}, None{}}
    case 0 True{} e:
      GStep{GBad{GStatus{8, "a message of " ++ U32.show(len) ++ " bytes is past the 4 MiB limit"}}, None{}}
    case _ b e:
      GStep{GBad{GStatus{12, "compressed messages are not supported"}}, None{}}

def Grpc.rd_head(acc: List<&2, U32>) -> GStep:
  match acc:
    case [d, c, b, a, flag]:
      +len = U32.or(U32.shln(a, 24n), U32.or(U32.shln(b, 16n), U32.or(U32.shln(c, 8n), d)))
      Grpc.rd_len(len, flag, U32.is_gt(len, Grpc.max()), U32.is_zero(len))
    case _:
      GStep{GBad{GStatus{13, "a message header of the wrong size"}}, None{}}

def Grpc.rd_more(+n: U32, +acc: List<&2, U32>, last: Bool) -> GStep:
  match last:
    case True{}:
      Grpc.rd_head(acc)
    case False{}:
      GStep{GHead{U32.add(n, 1), acc}, None{}}

def Grpc.rd_pay(+left: U32, acc: List<&2, U32>, last: Bool) -> GStep:
  match last:
    case True{}:
      GStep{GHead{0, Nil{}}, Some{List.reverse(&2, U32, acc)}}
    case False{}:
      GStep{GBody{U32.sub(left, 1), acc}, None{}}

def Grpc.rd_step(rd: GRd, +b: U32) -> GStep:
  match rd:
    case GHead{+n, acc}:
      Grpc.rd_more(n, Con{b, acc}, U32.is_eq(n, 4))
    case GBody{+left, acc}:
      Grpc.rd_pay(left, Con{b, acc}, U32.is_eq(left, 1))
    case GBad{st}:
      GStep{GBad{st}, None{}}

def Grpc.rd_add(got: Maybe<&2, List<&2, U32>>, out: List<&2, List<&2, U32>>) -> List<&2, List<&2, U32>>:
  match got:
    case None{}:
      out
    case Some{m}:
      Con{m, out}

def Grpc.rd_fin(rd: GRd, out: List<&2, List<&2, U32>>) -> Result<&2, &2, GStatus, List<&2, List<&2, U32>>>:
  match rd:
    case GHead{0, acc}:
      Done{List.reverse(&2, List<&2, U32>, out)}
    case GBad{st}:
      Fail{st}
    case _:
      Fail{GStatus{13, "the stream ends inside a message"}}

def Grpc.rd_go(bs: List<&2, U32>, ev: GStep, out: List<&2, List<&2, U32>>) -> Result<&2, &2, GStatus, List<&2, List<&2, U32>>>:
  match bs ev:
    case Nil{} GStep{rd, got}:
      Grpc.rd_fin(rd, Grpc.rd_add(got, out))
    case Con{+b, t} GStep{rd, got}:
      Grpc.rd_go(t, Grpc.rd_step(rd, b), Grpc.rd_add(got, out))

# A stream's whole body: its messages, or the status that refuses it.
def Grpc.unframe(bs: List<&2, U32>) -> Result<&2, &2, GStatus, List<&2, List<&2, U32>>>:
  Grpc.rd_go(bs, GStep{GHead{0, Nil{}}, None{}}, Nil{})

# grpc-timeout
# ------------

# n of a unit (H, M, S, m, u, n) in milliseconds, rounded up, at most
# 2^32-1.
def Grpc.unit(ok: Bool, u: U32, +n: U32) -> Maybe<&2, U32>:
  match ok u:
    case False{} x:
      None{}
    case True{} 72:
      Some{U32.mul(U32.min(n, 1193), 3600000)}
    case True{} 77:
      Some{U32.mul(U32.min(n, 71582), 60000)}
    case True{} 83:
      Some{U32.mul(U32.min(n, 4294967), 1000)}
    case True{} 109:
      Some{n}
    case True{} 117:
      Some{U32.div(U32.add(n, 999), 1000)}
    case True{} 110:
      Some{U32.div(U32.add(n, 999999), 1000000)}
    case True{} x:
      None{}

def Grpc.digit(d: Bool, rest: Maybe<&2, U32>) -> Maybe<&2, U32>:
  match d:
    case True{}:
      rest
    case False{}:
      None{}

# Up to 8 digits, then the unit.
def Grpc.digits(s: List<&2, Char>, +acc: U32, +n: U32) -> Maybe<&2, U32>:
  match s:
    case Nil{}:
      None{}
    case Con{Chr{+u}, Nil{}}:
      Grpc.unit(U32.is_ge(n, 1) && U32.is_le(n, 8), u, acc)
    case Con{Chr{+d}, t}:
      Grpc.digit(U32.is_ge(d, 48) && U32.is_le(d, 57),
        Grpc.digits(t, U32.add(U32.mul(acc, 10), U32.sub(d, 48)), U32.add(n, 1)))

# A grpc-timeout ("10S", "250m") in milliseconds; None when malformed.
def Grpc.timeout(s: String) -> Maybe<&2, U32>:
  Grpc.digits(String.to_list(s), 0, 0)

# A timeout of ms milliseconds, as grpc-timeout says it.
def Grpc.timeout_show.go(+ms: U32, small: Bool) -> String:
  match small:
    case True{}:
      U32.show(ms) ++ "m"
    case False{}:
      U32.show(U32.div(U32.add(ms, 999), 1000)) ++ "S"

def Grpc.timeout_show(+ms: U32) -> String:
  Grpc.timeout_show.go(ms, U32.is_lt(ms, 100000000))

# grpc-message
# ------------

def Grpc.hexd.go(+d: U32, digit: Bool) -> Char:
  match digit:
    case True{}:
      Chr{U32.add(d, 48)}
    case False{}:
      Chr{U32.add(d, 55)}

def Grpc.hexd(+d: U32) -> Char:
  Grpc.hexd.go(d, U32.is_lt(d, 10))

def Grpc.pct.go(+b: U32, rest: String, plain: Bool) -> String:
  match plain:
    case True{}:
      SCon{Chr{b}, rest}
    case False{}:
      SCon{Chr{37}, SCon{Grpc.hexd(U32.shrn(b, 4n)), SCon{Grpc.hexd(U32.and(b, 15)), rest}}}

# Percent-encodes what is not printable ASCII, and %, as UTF-8 bytes.
def Grpc.pct(bs: List<&2, U32>) -> String:
  match bs:
    case Nil{}:
      SNil{}
    case Con{+b, t}:
      Grpc.pct.go(b, Grpc.pct(t), U32.is_ge(b, 32) && U32.is_le(b, 126) && Bool.not(U32.is_eq(b, 37)))

def Grpc.unhex.go(+c: U32, digit: Bool, upper: Bool) -> U32:
  match digit upper:
    case True{} u:
      U32.sub(c, 48)
    case False{} True{}:
      U32.sub(c, 55)
    case False{} False{}:
      U32.sub(c, 87)

def Grpc.unhex(+c: U32) -> U32:
  Grpc.unhex.go(c, U32.is_le(c, 57), U32.is_le(c, 70))

def Grpc.is_hex(+c: U32) -> Bool:
  (U32.is_ge(c, 48) && U32.is_le(c, 57)) || (U32.is_ge(c, 65) && U32.is_le(c, 70)) ||
    (U32.is_ge(c, 97) && U32.is_le(c, 102))

# Undoes Grpc.pct, to bytes; a % not followed by two hex digits stays.
# (Kept apart from the walk so its recursion stays structural.)
type GPct is Data:
  GPct{out: List<&2, U32>, held: List<&2, U32>}

def Grpc.unpct.three(+a: U32, +b: U32, out: List<&2, U32>, ok: Bool) -> GPct:
  match ok:
    case True{}:
      GPct{Con{U32.or(U32.shln(Grpc.unhex(a), 4n), Grpc.unhex(b)), out}, Nil{}}
    case False{}:
      GPct{Con{b, Con{a, Con{37, out}}}, Nil{}}

def Grpc.unpct.plain(+c: U32, out: List<&2, U32>, pct: Bool) -> GPct:
  match pct:
    case True{}:
      GPct{out, [37]}
    case False{}:
      GPct{Con{U32.and(c, 255), out}, Nil{}}

# One character: held is what follows a % so far, reversed.
def Grpc.unpct.step(st: GPct, +c: U32) -> GPct:
  match st:
    case GPct{out, Nil{}}:
      Grpc.unpct.plain(c, out, U32.is_eq(c, 37))
    case GPct{out, [37]}:
      GPct{out, [c, 37]}
    case GPct{out, [+a, 37]}:
      Grpc.unpct.three(a, c, out, Grpc.is_hex(a) && Grpc.is_hex(c))
    case GPct{out, held}:
      GPct{Con{U32.and(c, 255), List.append(&2, U32, held, out)}, Nil{}}

def Grpc.unpct.go(s: List<&2, Char>, st: GPct) -> List<&2, U32>:
  match s st:
    case Nil{} GPct{out, held}:
      List.reverse(&2, U32, List.append(&2, U32, held, out))
    case Con{Chr{+c}, t} x:
      Grpc.unpct.go(t, Grpc.unpct.step(x, c))

def Grpc.unpct(s: List<&2, Char>) -> List<&2, U32>:
  Grpc.unpct.go(s, GPct{Nil{}, Nil{}})

# Headers
# -------

def Grpc.hdr(hs: List<&2, H.Header>, +name: String) -> Maybe<&2, String>:
  H.Http.find(hs, name)

def Grpc.timeout_hdr(+ms: U32, none: Bool) -> List<&2, H.Header>:
  match none:
    case True{}:
      Nil{}
    case False{}:
      [H.Header{"grpc-timeout", Grpc.timeout_show(ms)}]

# The headers of a call to method ("/package.Service/Method"), with a
# deadline of ms milliseconds unless ms is 0.
def Grpc.call_headers(method: String, +ms: U32) -> List<&2, H.Header>:
  List.append(&2, H.Header, [H.Header{":method", "POST"}, H.Header{":scheme", "http"}, H.Header{":path", method},
    H.Header{":authority", "localhost"}, H.Header{"content-type", "application/grpc"}, H.Header{"te", "trailers"}],
    Grpc.timeout_hdr(ms, U32.is_zero(ms)))

# An answer's headers.
def Grpc.reply_headers() -> List<&2, H.Header>:
  [H.Header{":status", "200"}, H.Header{"content-type", "application/grpc"}]

def Grpc.status_headers.go(+code: U32, msg: String, empty: Bool) -> List<&2, H.Header>:
  match empty:
    case True{}:
      [H.Header{"grpc-status", U32.show(code)}]
    case False{}:
      [H.Header{"grpc-status", U32.show(code)}, H.Header{"grpc-message", Grpc.pct(U.Utf8.encode(msg))}]

def Grpc.status_headers(st: GStatus) -> List<&2, H.Header>:
  match st:
    case GStatus{+code, +msg}:
      Grpc.status_headers.go(code, msg, String.is_empty(msg))

# A status's trailers, or, with no message sent, the whole answer in one
# block ("Trailers-Only").
def Grpc.trailers(st: GStatus, only: Bool) -> List<&2, H.Header>:
  match only:
    case True{}:
      List.append(&2, H.Header, Grpc.reply_headers(), Grpc.status_headers(st))
    case False{}:
      Grpc.status_headers(st)

def Grpc.code(m: Maybe<&2, String>) -> U32:
  match m:
    case None{}:
      2
    case Some{s}:
      Maybe.default(&2, U32, U32.read(s), 2)

# The status an answer's trailers (or Trailers-Only headers) carry.
def Grpc.status_of(hs: List<&2, H.Header>) -> GStatus:
  +hs = hs
  GStatus{Grpc.code(Grpc.hdr(hs, "grpc-status")),
    U.Utf8.decode_all(Grpc.unpct(String.to_list(Maybe.default(&2, String, Grpc.hdr(hs, "grpc-message"), ""))))}

# Whether request headers are a gRPC call: POST, and a content-type of
# application/grpc (or application/grpc+proto, ...).
def Grpc.is_call(hs: List<&2, H.Header>) -> Bool:
  +hs = hs
  String.eq(Maybe.default(&2, String, Grpc.hdr(hs, ":method"), ""), "POST") &&
    String.starts_with(Maybe.default(&2, String, Grpc.hdr(hs, "content-type"), ""), "application/grpc")
