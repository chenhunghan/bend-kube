import Base
import ./utf8.bend as U

# HTTP/1.1
# ========
#
# Pure: a request renders to text, and a response decodes from bytes as they
# arrive. The decoder is a byte-at-a-time automaton (so it terminates by
# structure and streams), covering Content-Length, chunked and
# read-until-close bodies, which is all the Kubernetes API server sends.

type Header is Data:
  Header{name: String, value: String}

type Req is Data:
  Req{method: String, path: String, headers: List<&2, Header>, body: String}

type Head is Data:
  Head{status: U32, reason: String, headers: List<&2, Header>}

# Where the decoder is.
#   PHead: header bytes, reversed, and how much of CRLF CRLF ends them
#   PLen: body bytes left under Content-Length
#   PSize: a chunk's hex size so far; ext once past a ';' extension
#   PData: chunk bytes left; PCrlf: the CRLF after a chunk's data
#   PTrail: trailer lines after the last chunk; blank if this line is empty
#   PClose: a body that runs to the end of the stream
#   PErr: a broken response; PLost: the connection failed before any byte
#   of a response (a request on it may safely be retried)
type Phase is Data:
  PHead{buf: List<&2, U32>, tail: U32}
  PLen{left: U32}
  PSize{size: U32, ext: Bool, any: Bool}
  PData{left: U32}
  PCrlf{}
  PTrail{blank: Bool}
  PClose{}
  PDone{}
  PErr{msg: String}
  PLost{msg: String}

# The decoder: its phase, the head once read, and body bytes decoded since
# the last take, reversed.
type Resp is Data:
  Resp{phase: Phase, head: Maybe<&2, Head>, out: List<&2, U32>}

# Text
# ----

def Http.lower(s: String) -> String:
  String.to_lower(s)

def Http.header.if(+name: String, v: String, t: List<&2, Header>, hit: Bool) ->
  Maybe<&2, String>:
  match hit:
    case True{}:
      Some{String.trim(v)}
    case False{}:
      None{}

def Http.header(+name: String, hs: List<&2, Header>) -> Maybe<&2, String>:
  match hs:
    case Nil{}:
      None{}
    case Con{Header{n, v}, t}:
      Http.header.if(name, v, t, String.eq(Http.lower(n), Http.lower(name)))

# The first header named name (case-insensitive).
def Http.find(hs: List<&2, Header>, +name: String) -> Maybe<&2, String>:
  match hs:
    case Nil{}:
      None{}
    case Con{+h, t}:
      Maybe.or(&2, String, Http.header(name, [h]), Http.find(t, name))

# Requests
# --------

def Http.render_headers(hs: List<&2, Header>) -> String:
  match hs:
    case Nil{}:
      ""
    case Con{Header{n, v}, t}:
      n ++ ": " ++ v ++ "\r\n" ++ Http.render_headers(t)

# The request's bytes, as text: a Host header, the given headers, and a
# Content-Length that counts the body's UTF-8 bytes.
def Http.render(req: Req, host: String) -> String:
  match req:
    case Req{m, p, hs, +body}:
      m ++ " " ++ p ++ " HTTP/1.1\r\nHost: " ++ host ++ "\r\n"
        ++ Http.render_headers(hs)
        ++ "Content-Length: " ++ U32.show(U.Utf8.size(body)) ++ "\r\n\r\n" ++ body

def Http.pct_hex.if(+n: U32, lt: Bool) -> Char:
  match lt:
    case True{}:
      Chr{(n + 48 : U32)}
    case False{}:
      Chr{(n + 55 : U32)}

# Percent-encodes a query or path component (RFC 3986 unreserved kept).
def Http.pct_hex(+n: U32) -> Char:
  Http.pct_hex.if(n, U32.is_lt(n, 10))

def Http.keep(c: Char) -> Bool:
  match c:
    case '-':
      True{}
    case '_':
      True{}
    case '.':
      True{}
    case '~':
      True{}
    case Chr{+x}:
      Bool.or(Char.is_alpha(Chr{x}), Char.is_digit(Chr{x}))

def Http.pct_bytes(bs: List<&2, U32>, rest: String) -> String:
  match bs:
    case Nil{}:
      rest
    case Con{+b, t}:
      SCon{'%', SCon{Http.pct_hex((b >> 4n : U32)), SCon{Http.pct_hex((b .&. 15 : U32)),
        Http.pct_bytes(t, rest)}}}

def Http.encode.chr(+c: Char, rest: String, keep: Bool) -> String:
  match keep:
    case True{}:
      SCon{c, rest}
    case False{}:
      Http.pct_bytes(U.Utf8.encode(SCon{c, SNil{}}), rest)

def Http.encode(s: String) -> String:
  match s:
    case SNil{}:
      SNil{}
    case SCon{+c, t}:
      Http.encode.chr(c, Http.encode(t), Http.keep(c))

def Http.parse_header.go(parts: List<&2, String>) -> Maybe<&2, Header>:
  match parts:
    case Con{n, Con{v, rest}}:
      Some{Header{String.trim(n), String.join(v <> rest, ":")}}
    case _:
      None{}

# Response heads
# --------------

def Http.parse_header(line: String) -> Maybe<&2, Header>:
  Http.parse_header.go(String.split(line, ':'))

def Http.parse_headers.put(h: Maybe<&2, Header>, rest: List<&2, Header>) -> List<&2, Header>:
  match h:
    case Some{x}:
      x <> rest
    case None{}:
      rest

def Http.parse_headers(lines: List<&2, String>) -> List<&2, Header>:
  match lines:
    case Nil{}:
      Nil{}
    case Con{l, t}:
      Http.parse_headers.put(Http.parse_header(String.trim(l)), Http.parse_headers(t))

def Http.parse_status.fin(code: Maybe<&2, U32>, reason: String) -> Maybe<&1, U32 & String>:
  match code:
    case Some{c}:
      Some{(c, reason)}
    case None{}:
      None{}

def Http.parse_status.go(parts: List<&2, String>) -> Maybe<&1, U32 & String>:
  match parts:
    case Con{v, Con{code, rest}}:
      Http.parse_status.fin(U32.read(code), String.join(rest, " "))
    case _:
      None{}

# "HTTP/1.1 200 OK": the status and the reason.
def Http.parse_status(line: String) -> Maybe<&1, U32 & String>:
  Http.parse_status.go(String.split(String.trim(line), ' '))

def Http.parse_head.fin(st: Maybe<&1, U32 & String>, hs: List<&2, Header>) -> Maybe<&2, Head>:
  match st:
    case Some{(c, r)}:
      Some{Head{c, r, hs}}
    case None{}:
      None{}

def Http.parse_head.go(lines: List<&2, String>) -> Maybe<&2, Head>:
  match lines:
    case Con{first, rest}:
      Http.parse_head.fin(Http.parse_status(first), Http.parse_headers(rest))
    case Nil{}:
      None{}

def Http.parse_head(text: String) -> Maybe<&2, Head>:
  Http.parse_head.go(String.lines(text))

def Http.framing.te(chunked: Bool) -> Phase:
  match chunked:
    case True{}:
      PSize{0, False{}, False{}}
    case False{}:
      PClose{}

def Http.framing.len.if(+k: U32, zero: Bool) -> Phase:
  match zero:
    case True{}:
      PDone{}
    case False{}:
      PLen{k}

def Http.framing.len(n: Maybe<&2, U32>) -> Phase:
  match n:
    case Some{+k}:
      Http.framing.len.if(k, U32.is_eq(k, 0))
    case None{}:
      PErr{"bad Content-Length"}

def Http.framing.pick(none: Bool, te: Maybe<&2, String>, cl: Maybe<&2, String>) -> Phase:
  match none te cl:
    case True{} _ _:
      PDone{}
    case False{} Some{t} _:
      Http.framing.te(String.contains(Http.lower(t), "chunked"))
    case False{} None{} Some{n}:
      Http.framing.len(U32.read(n))
    case False{} None{} None{}:
      PClose{}

def Http.no_body(+code: U32) -> Bool:
  Bool.or(U32.is_lt(code, 200), Bool.or(U32.is_eq(code, 204), U32.is_eq(code, 304)))

def Http.framing.go(+code: U32, te: Maybe<&2, String>, cl: Maybe<&2, String>) -> Phase:
  Http.framing.pick(Http.no_body(code), te, cl)

# The body's framing, once the head is read: chunked, a length, or none
# (204, 304 and 1xx carry no body).
def Http.framing(+h: Head) -> Phase:
  match h:
    case Head{+code, r, hs}:
      Http.framing.go(code, Http.find(hs, "transfer-encoding"), Http.find(hs, "content-length"))

# The decoder
# -----------

def Http.resp.init() -> Resp:
  Resp{PHead{Nil{}, 0}, None{}, Nil{}}

def Http.head_tail.go(+tail: U32, cr: Bool, lf: Bool, even: Bool) -> U32:
  match cr lf even:
    case True{} _ True{}:
      (tail + 1 : U32)
    case True{} _ False{}:
      1
    case False{} True{} False{}:
      (tail + 1 : U32)
    case _ _ _:
      0

# How far into CRLF CRLF the head is after byte b.
def Http.head_tail(+tail: U32, +b: U32) -> U32:
  Http.head_tail.go(tail, U32.is_eq(b, 13), U32.is_eq(b, 10), U32.is_eq((tail .&. 1 : U32), 0))

def Http.end_head.go(h: Maybe<&2, Head>) -> Resp:
  match h:
    case Some{+x}:
      Resp{Http.framing(x), Some{x}, Nil{}}
    case None{}:
      Resp{PErr{"bad response head"}, None{}, Nil{}}

def Http.end_head(buf: List<&2, U32>) -> Resp:
  Http.end_head.go(Http.parse_head(U.Utf8.decode_all(List.reverse(&2, U32, buf))))

def Http.step.head.end(buf: List<&2, U32>, +tail: U32, done: Bool) -> Resp:
  match done:
    case True{}:
      Http.end_head(buf)
    case False{}:
      Resp{PHead{buf, tail}, None{}, Nil{}}

def Http.step.head.if(buf: List<&2, U32>, +tail: U32) -> Resp:
  Http.step.head.end(buf, tail, U32.is_eq(tail, 4))

def Http.step.head(buf: List<&2, U32>, +tail: U32, +b: U32) -> Resp:
  Http.step.head.if(b <> buf, Http.head_tail(tail, b))

def Http.count.if(+left: U32, chunk: Bool, zero: Bool) -> Phase:
  match chunk zero:
    case True{} True{}:
      PCrlf{}
    case False{} True{}:
      PDone{}
    case True{} False{}:
      PData{left}
    case False{} False{}:
      PLen{left}

# A counted run of body bytes: PLen or PData, with what follows at zero.
def Http.count(+left: U32, chunk: Bool) -> Phase:
  Http.count.if(left, chunk, U32.is_eq(left, 0))

def Http.hex.pick(+c: U32, digit: Bool, lower: Bool, upper: Bool) -> Maybe<&2, U32>:
  match digit lower upper:
    case True{} _ _:
      Some{(c - 48 : U32)}
    case False{} True{} _:
      Some{(c - 87 : U32)}
    case False{} False{} True{}:
      Some{(c - 55 : U32)}
    case _ _ _:
      None{}

def Http.hex.go(+c: U32, a: Bool, b: Bool, d: Bool, e: Bool, f: Bool, g: Bool) -> Maybe<&2, U32>:
  Http.hex.pick(c, Bool.and(a, b), Bool.and(d, e), Bool.and(f, g))

def Http.hex(+c: U32) -> Maybe<&2, U32>:
  Http.hex.go(c, U32.is_ge(c, 48), U32.is_le(c, 57), U32.is_ge(c, 97), U32.is_le(c, 102),
    U32.is_ge(c, 65), U32.is_le(c, 70))

def Http.step.size.digit(+size: U32, +v: U32, big: Bool) -> Phase:
  match big:
    case True{}:
      PErr{"chunk too large"}
    case False{}:
      PSize{((size << 4n) + v : U32), False{}, True{}}

def Http.step.size.end(+size: U32, last: Bool) -> Phase:
  match last:
    case True{}:
      PTrail{True{}}
    case False{}:
      PData{size}

def Http.step.size.go(+size: U32, lf: Bool, ext: Bool, h: Maybe<&2, U32>, semi: Bool,
  cr: Bool, any: Bool) -> Phase:
  match lf ext h semi cr any:
    case True{} _ _ _ _ True{}:
      Http.step.size.end(size, U32.is_eq(size, 0))
    case True{} _ _ _ _ False{}:
      PErr{"empty chunk size"}
    case False{} True{} _ _ _ _:
      PSize{size, True{}, any}
    case False{} False{} Some{v} _ _ _:
      Http.step.size.digit(size, v, U32.is_ge(size, 134217728))
    case False{} False{} None{} True{} _ _:
      PSize{size, True{}, any}
    case False{} False{} None{} False{} True{} _:
      PSize{size, ext, any}
    case _ _ _ _ _ _:
      PErr{"bad chunk size"}

# A byte of a chunk-size line. The line ends at LF; a zero size means the
# last chunk, and its trailers follow.
def Http.step.size(+size: U32, ext: Bool, any: Bool, +b: U32) -> Phase:
  Http.step.size.go(size, U32.is_eq(b, 10), ext, Http.hex(b), U32.is_eq(b, 59),
    U32.is_eq(b, 13), any)

def Http.step.crlf.go(cr: Bool, lf: Bool) -> Phase:
  match cr lf:
    case True{} _:
      PCrlf{}
    case False{} True{}:
      PSize{0, False{}, False{}}
    case _ _:
      PErr{"missing CRLF after chunk"}

def Http.step.crlf(+b: U32) -> Phase:
  Http.step.crlf.go(U32.is_eq(b, 13), U32.is_eq(b, 10))

def Http.step.trail.go(lf: Bool, cr: Bool, blank: Bool) -> Phase:
  match lf cr blank:
    case True{} _ True{}:
      PDone{}
    case True{} _ False{}:
      PTrail{True{}}
    case False{} True{} b:
      PTrail{b}
    case False{} False{} _:
      PTrail{False{}}

def Http.step.trail(blank: Bool, +b: U32) -> Phase:
  Http.step.trail.go(U32.is_eq(b, 10), U32.is_eq(b, 13), blank)

# One byte.
def Http.step(r: Resp, +b: U32) -> Resp:
  match r:
    case Resp{PHead{buf, tail}, h, out}:
      Http.step.head(buf, tail, b)
    case Resp{PLen{+left}, h, out}:
      Resp{Http.count((left - 1 : U32), False{}), h, b <> out}
    case Resp{PSize{size, ext, any}, h, out}:
      Resp{Http.step.size(size, ext, any, b), h, out}
    case Resp{PData{+left}, h, out}:
      Resp{Http.count((left - 1 : U32), True{}), h, b <> out}
    case Resp{PCrlf{}, h, out}:
      Resp{Http.step.crlf(b), h, out}
    case Resp{PTrail{blank}, h, out}:
      Resp{Http.step.trail(blank, b), h, out}
    case Resp{PClose{}, h, out}:
      Resp{PClose{}, h, b <> out}
    case Resp{PDone{}, h, out}:
      Resp{PErr{"bytes after the body"}, h, out}
    case Resp{PErr{m}, h, out}:
      Resp{PErr{m}, h, out}
    case Resp{PLost{m}, h, out}:
      Resp{PLost{m}, h, out}

# Feeds a cut of bytes.
def Http.feed(bs: List<&2, U32>, r: Resp) -> Resp:
  match bs:
    case Nil{}:
      r
    case Con{+b, t}:
      Http.feed(t, Http.step(r, b))

# Takes the body bytes decoded so far, in order, leaving none behind.
def Http.take(r: Resp) -> Resp & List<&2, U32>:
  match r:
    case Resp{p, h, out}:
      (Resp{p, h, Nil{}}, List.reverse(&2, U32, out))

# The stream ended: a read-until-close body is then complete.
def Http.eof(r: Resp) -> Resp:
  match r:
    case Resp{PClose{}, h, out}:
      Resp{PDone{}, h, out}
    case Resp{PDone{}, h, out}:
      Resp{PDone{}, h, out}
    case Resp{PErr{m}, h, out}:
      Resp{PErr{m}, h, out}
    case Resp{PLost{m}, h, out}:
      Resp{PLost{m}, h, out}
    case Resp{PHead{Nil{}, t}, h, out}:
      Resp{PLost{"connection closed before a response"}, h, out}
    case Resp{p, h, out}:
      Resp{PErr{"connection closed mid-response"}, h, out}

def Http.is_done(r: Resp) -> Bool:
  match r:
    case Resp{PDone{}, h, out}:
      True{}
    case _:
      False{}

def Http.error(r: Resp) -> Maybe<&2, String>:
  match r:
    case Resp{PErr{m}, h, out}:
      Some{m}
    case Resp{PLost{m}, h, out}:
      Some{m}
    case _:
      None{}

def Http.decode.fin(rb: Resp & List<&2, U32>) -> Result<&2, &1, String, Head & String>:
  match rb:
    case (Resp{PDone{}, Some{h}, o}, body):
      Done{(h, U.Utf8.decode_all(body))}
    case (Resp{PErr{m}, h, o}, body):
      Fail{m}
    case (Resp{PLost{m}, h, o}, body):
      Fail{m}
    case _:
      Fail{"incomplete response"}

# A whole response from its bytes: the head and the decoded body.
def Http.decode(bs: List<&2, U32>) -> Result<&2, &1, String, Head & String>:
  Http.decode.fin(Http.take(Http.eof(Http.feed(bs, Http.resp.init()))))

def Lines.cur.if(+b: U32, cur: List<&2, U32>, lf: Bool) -> List<&2, U32>:
  match lf:
    case True{}:
      Nil{}
    case False{}:
      b <> cur

def Lines.cur(+b: U32, +cur: List<&2, U32>) -> List<&2, U32>:
  Lines.cur.if(b, cur, U32.is_eq(b, 10))

def Lines.done.if(cur: List<&2, U32>, done: List<&2, List<&2, U32>>, lf: Bool) ->
  List<&2, List<&2, U32>>:
  match lf:
    case True{}:
      List.reverse(&2, U32, cur) <> done
    case False{}:
      done

def Lines.done(+b: U32, +cur: List<&2, U32>, done: List<&2, List<&2, U32>>) ->
  List<&2, List<&2, U32>>:
  Lines.done.if(cur, done, U32.is_eq(b, 10))

# Lines
# -----
#
# A watch body is a stream of JSON objects, one per line. Lines splits
# body bytes at LF, carrying the unfinished line (reversed) across cuts.

def Lines.go(bs: List<&2, U32>, +cur: List<&2, U32>, done: List<&2, List<&2, U32>>) ->
  List<&2, U32> & List<&2, List<&2, U32>>:
  match bs:
    case Nil{}:
      (cur, done)
    case Con{+b, t}:
      Lines.go(t, Lines.cur(b, cur), Lines.done(b, cur, done))

def Lines.split.fin(r: List<&2, U32> & List<&2, List<&2, U32>>) ->
  List<&2, U32> & List<&2, List<&2, U32>>:
  match r:
    case (cur, done):
      (cur, List.reverse(&2, List<&2, U32>, done))

# Splits a cut: the carried partial line, and the whole lines, in order.
def Lines.split(cur: List<&2, U32>, bs: List<&2, U32>) ->
  List<&2, U32> & List<&2, List<&2, U32>>:
  Lines.split.fin(Lines.go(bs, cur, Nil{}))
