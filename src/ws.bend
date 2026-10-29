import Base

# WebSocket
# =========
#
# RFC 6455 framing, as Kubernetes' exec speaks it (exec.bend). Frames a
# client sends are masked; frames it reads are decoded a byte at a time,
# so a frame may arrive split over any number of recvs, and many frames
# may arrive in one.

type Frame is Data:
  Frame{fin: Bool, op: U32, data: List<&2, U32>}

# Where the decoder is.
#   WHead: before a frame's first byte
#   WLen: before the byte with the mask bit and the 7-bit length
#   WExt: need more bytes of a 16- or 64-bit length
#   WKey: need more bytes of the masking key
#   WPay: left bytes of payload to go, key rotated to the next byte
#   WBad: a frame the decoder refuses; it stays here
type WSt is Data:
  WHead{}
  WLen{fin: Bool, op: U32}
  WExt{fin: Bool, op: U32, masked: Bool, need: U32, len: U32}
  WKey{fin: Bool, op: U32, len: U32, need: U32, key: List<&2, U32>}
  WPay{fin: Bool, op: U32, left: U32, key: List<&2, U32>, acc: List<&2, U32>}
  WBad{why: String}

type Stepped is Data:
  Stepped{st: WSt, got: Maybe<&2, Frame>}

type Fed is Data:
  Fed{st: WSt, frames: List<&2, Frame>}

# Opcodes.
def Ws.text() -> U32:
  1

def Ws.binary() -> U32:
  2

def Ws.close() -> U32:
  8

def Ws.ping() -> U32:
  9

def Ws.pong() -> U32:
  10

# The largest payload the decoder accepts.
def Ws.max() -> U32:
  16777216

# Encoding
# --------

# The nth byte of x, counting from the low end.
def Ws.byte(+x: U32, n: Nat) -> U32:
  U32.mod(U32.shrn(x, Nat.mul(8n, n)), 256)

def Ws.len.go(+n: U32, small: Bool, mid: Bool) -> List<&2, U32>:
  match small mid:
    case True{} True{}:
      [U32.or(128, n)]
    case True{} False{}:
      [U32.or(128, n)]
    case False{} True{}:
      [254, Ws.byte(n, 1n), Ws.byte(n, 0n)]
    case False{} False{}:
      [255, 0, 0, 0, 0, Ws.byte(n, 3n), Ws.byte(n, 2n), Ws.byte(n, 1n), Ws.byte(n, 0n)]

# The header from the second byte on: the mask bit (always set, as a client
# must) and the length, in 7, 16 or 64 bits.
def Ws.len(+n: U32) -> List<&2, U32>:
  Ws.len.go(n, U32.is_lt(n, 126), U32.is_lt(n, 65536))

# XORs bytes with the key a, b, c, d, rotating.
def Ws.mask(bs: List<&2, U32>, +a: U32, +b: U32, +c: U32, +d: U32) -> List<&2, U32>:
  match bs:
    case Nil{}:
      Nil{}
    case Con{x, t}:
      Con{U32.xor(x, a), Ws.mask(t, b, c, d, a)}

# One final frame of op carrying data, masked with key.
def Ws.frame(+op: U32, +data: List<&2, U32>, +key: U32) -> List<&2, U32>:
  List.append(&2, U32,
    Con{U32.or(128, op), Ws.len(U32.from_nat(List.length(&2, U32, data)))},
    Con{Ws.byte(key, 3n), Con{Ws.byte(key, 2n), Con{Ws.byte(key, 1n), Con{Ws.byte(key, 0n),
      Ws.mask(data, Ws.byte(key, 3n), Ws.byte(key, 2n), Ws.byte(key, 1n), Ws.byte(key, 0n))}}}})

# Decoding
# --------

def Ws.unmask(key: List<&2, U32>, +b: U32) -> U32:
  match key:
    case Nil{}:
      b
    case Con{k, t}:
      U32.xor(b, k)

def Ws.rotate(key: List<&2, U32>) -> List<&2, U32>:
  match key:
    case Nil{}:
      Nil{}
    case Con{k, t}:
      List.append(&2, U32, t, [k])

def Ws.payload(+fin: Bool, +op: U32, +len: U32, key: List<&2, U32>, empty: Bool) -> Stepped:
  match empty:
    case True{}:
      Stepped{WHead{}, Some{Frame{fin, op, Nil{}}}}
    case False{}:
      Stepped{WPay{fin, op, len, key, Nil{}}, None{}}

def Ws.begin.go(+fin: Bool, +op: U32, +len: U32, big: Bool, masked: Bool) -> Stepped:
  match big masked:
    case True{} m:
      Stepped{WBad{"frame of " ++ U32.show(len) ++ " bytes is too large"}, None{}}
    case False{} True{}:
      Stepped{WKey{fin, op, len, 4, Nil{}}, None{}}
    case False{} False{}:
      Ws.payload(fin, op, len, Nil{}, U32.is_zero(len))

# The header is whole: the key follows if masked, then the payload.
def Ws.begin(+fin: Bool, +op: U32, masked: Bool, +len: U32) -> Stepped:
  Ws.begin.go(fin, op, len, U32.is_gt(len, Ws.max()), masked)

def Ws.len7(+fin: Bool, +op: U32, masked: Bool, +n: U32, two: Bool, eight: Bool) -> Stepped:
  match two eight:
    case True{} e:
      Stepped{WExt{fin, op, masked, 2, 0}, None{}}
    case False{} True{}:
      Stepped{WExt{fin, op, masked, 8, 0}, None{}}
    case False{} False{}:
      Ws.begin(fin, op, masked, n)

def Ws.ext(+fin: Bool, +op: U32, masked: Bool, +need: U32, +len: U32, last: Bool) -> Stepped:
  match last:
    case True{}:
      Ws.begin(fin, op, masked, len)
    case False{}:
      Stepped{WExt{fin, op, masked, need, len}, None{}}

def Ws.key(+fin: Bool, +op: U32, +len: U32, +need: U32, +key: List<&2, U32>, last: Bool) -> Stepped:
  match last:
    case True{}:
      Ws.payload(fin, op, len, key, U32.is_zero(len))
    case False{}:
      Stepped{WKey{fin, op, len, need, key}, None{}}

def Ws.pay(+fin: Bool, +op: U32, +left: U32, key: List<&2, U32>, +acc: List<&2, U32>, last: Bool) ->
  Stepped:
  match last:
    case True{}:
      Stepped{WHead{}, Some{Frame{fin, op, List.reverse(&2, U32, acc)}}}
    case False{}:
      Stepped{WPay{fin, op, left, key, acc}, None{}}

# One byte into the decoder.
def Ws.step(st: WSt, +b: U32) -> Stepped:
  match st:
    case WHead{}:
      Stepped{WLen{U32.is_ge(b, 128), U32.and(b, 15)}, None{}}
    case WLen{+fin, +op}:
      Ws.len7(fin, op, U32.is_ge(b, 128), U32.and(b, 127), U32.is_eq(U32.and(b, 127), 126),
        U32.is_eq(U32.and(b, 127), 127))
    case WExt{+fin, +op, masked, +need, +len}:
      Ws.ext(fin, op, masked, U32.sub(need, 1), U32.add(U32.mul(len, 256), b),
        U32.is_eq(need, 1))
    case WKey{+fin, +op, +len, +need, +key}:
      Ws.key(fin, op, len, U32.sub(need, 1), List.append(&2, U32, key, [b]), U32.is_eq(need, 1))
    case WPay{+fin, +op, +left, +key, +acc}:
      Ws.pay(fin, op, U32.sub(left, 1), Ws.rotate(key), Con{Ws.unmask(key, b), acc},
        U32.is_eq(left, 1))
    case WBad{why}:
      Stepped{WBad{why}, None{}}

def Ws.add(got: Maybe<&2, Frame>, out: List<&2, Frame>) -> List<&2, Frame>:
  match got:
    case None{}:
      out
    case Some{f}:
      Con{f, out}

def Ws.feed.go(bs: List<&2, U32>, ev: Stepped, out: List<&2, Frame>) -> Fed:
  match bs ev:
    case Nil{} Stepped{st, got}:
      Fed{st, List.reverse(&2, Frame, Ws.add(got, out))}
    case Con{+b, t} Stepped{st, got}:
      Ws.feed.go(t, Ws.step(st, b), Ws.add(got, out))

# Feeds bytes to the decoder: its next state and the frames they finished.
def Ws.feed(st: WSt, bs: List<&2, U32>) -> Fed:
  Ws.feed.go(bs, Stepped{st, None{}}, Nil{})

def Ws.error(st: WSt) -> Maybe<&2, String>:
  match st:
    case WBad{why}:
      Some{why}
    case _:
      None{}
