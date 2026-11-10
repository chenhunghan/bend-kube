import Base
import ./json.bend as J
import ./http.bend as H
import ./utf8.bend as U
import ./base64.bend as B

# Admission
# =========
#
# The pure side of webhooks (webhook.bend serves them): what a handler
# answers (Verdict), how a request is read off the wire (Rq), and the
# AdmissionReview and ConversionReview answers built from them.

# Verdicts
# --------

# allowed; code and message when denied (code 0: 403); patch: JSON-patch
# operations to apply (a mutating webhook; Nil for none); warnings shown to
# the client (kubectl prints them).
type Verdict is Data:
  Verdict{allowed: Bool, code: U32, message: String, patch: List<&2, J.Json>, warnings: List<&2, String>}

def Verdict.allow() -> Verdict:
  Verdict{True{}, 0, "", Nil{}, Nil{}}

# Denied with a message (403 Forbidden).
def Verdict.deny(msg: String) -> Verdict:
  Verdict{False{}, 403, msg, Nil{}, Nil{}}

# Denied with an HTTP-style code (400 for a bad request, 422 invalid).
def Verdict.deny_with(code: U32, msg: String) -> Verdict:
  Verdict{False{}, code, msg, Nil{}, Nil{}}

# Allowed, applying JSON-patch operations ({"op": "add", "path": .., "value": ..}).
def Verdict.patch(ops: List<&2, J.Json>) -> Verdict:
  Verdict{True{}, 0, "", ops, Nil{}}

# The verdict with a warning added.
def Verdict.warn(v: Verdict, w: String) -> Verdict:
  match v:
    case Verdict{a, c, m, p, ws}:
      Verdict{a, c, m, p, List.append(&2, String, ws, [w])}

# A JSON-patch operation: op ("add", "replace", "remove"), path, value.
def Patch.op(op: String, path: String, value: J.Json) -> J.Json:
  J.Json.obj([J.KV{"op", J.JStr{op}}, J.KV{"path", J.JStr{path}}, J.KV{"value", value}])

# Reading a request
# -----------------
#
# The request line (method and path) is read up to its LF; the rest, the
# headers and the body, goes through the response decoder (http.bend)
# behind a stand-in status line, so Content-Length and chunked bodies are
# framed as for responses.

# A request so far: its first line's bytes (reversed), then the line and
# the decoder; size counts every byte read.
type Rq is Data:
  RLine{acc: List<&2, U32>, size: U32}
  RBody{line: String, resp: H.Resp, size: U32}

def Rq.init() -> Rq:
  RLine{Nil{}, 0}

# The bytes before the first LF, and those after it.
type Cut is Data:
  Cut{before: List<&2, U32>, after: List<&2, U32>, found: Bool}

def Cut.put(+b: U32, c: Cut) -> Cut:
  match c:
    case Cut{x, a, f}:
      Cut{b <> x, a, f}

def Cut.is_lf(bs: List<&2, U32>) -> Bool:
  match bs:
    case Con{b, t}:
      U32.is_eq(b, 10)
    case Nil{}:
      False{}

# lf: whether bs starts with LF.
def Cut.at(bs: List<&2, U32>, lf: Bool) -> Cut:
  match bs lf:
    case Nil{} _:
      Cut{Nil{}, Nil{}, False{}}
    case Con{b, t} True{}:
      Cut{Nil{}, t, True{}}
    case Con{+b, +t} False{}:
      Cut.put(b, Cut.at(t, Cut.is_lf(t)))

def Cut.of(+bs: List<&2, U32>) -> Cut:
  Cut.at(bs, Cut.is_lf(bs))

def Rq.status() -> List<&2, U32>:
  U.Utf8.encode("HTTP/1.1 200 OK\r\n")

def Rq.lined(acc: List<&2, U32>, +n: U32, c: Cut) -> Rq:
  match c:
    case Cut{bf, af, True{}}:
      RBody{String.trim(U.Utf8.decode_all(List.reverse(&2, U32, List.append(&2, U32, List.reverse(&2, U32, bf), acc)))),
        H.Http.feed(af, H.Http.feed(Rq.status(), H.Http.resp.init())), n}
    case Cut{bf, af, False{}}:
      RLine{List.append(&2, U32, List.reverse(&2, U32, bf), acc), n}

# Feeds bytes read from the connection.
def Rq.feed(st: Rq, +bs: List<&2, U32>) -> Rq:
  match st:
    case RLine{acc, n}:
      Rq.lined(acc, (n + U32.from_nat(List.length(&2, U32, bs)) : U32), Cut.of(bs))
    case RBody{l, r, n}:
      RBody{l, H.Http.feed(bs, r), (n + U32.from_nat(List.length(&2, U32, bs)) : U32)}

def Rq.size(st: Rq) -> U32:
  match st:
    case RLine{a, n}:
      n
    case RBody{l, r, n}:
      n

# A request without Content-Length or chunked framing has no body (the
# response decoder would read one to the end of the stream).
def Rq.done(st: Rq) -> Bool:
  match st:
    case RBody{l, H.Resp{H.PClose{}, h, o}, n}:
      True{}
    case RBody{l, r, n}:
      H.Http.is_done(r)
    case _:
      False{}

def Rq.broken(st: Rq) -> Bool:
  match st:
    case RBody{l, r, n}:
      Bool.not(Maybe.is_none(&2, String, H.Http.error(r)))
    case _:
      False{}

# The path of a request line ("POST /validate?timeout=10s HTTP/1.1"),
# without its query.
def Rq.path.go(ps: List<&2, String>) -> String:
  match ps:
    case Con{m, Con{+p, t}}:
      Maybe.default(&2, String, List.head(&2, String, String.split(p, '?')), p)
    case _:
      ""

def Rq.method.go(ps: List<&2, String>) -> String:
  match ps:
    case Con{m, t}:
      m
    case Nil{}:
      ""

# A finished request: its method, path and body.
type Got is Data:
  Got{method: String, path: String, body: String}

def Rq.got.fin(+line: String, rb: H.Resp & List<&2, U32>) -> Got:
  match rb:
    case (r, body):
      Got{Rq.method.go(String.split(line, ' ')), Rq.path.go(String.split(line, ' ')), U.Utf8.decode_all(body)}

def Rq.got(st: Rq) -> Got:
  match st:
    case RBody{+l, r, n}:
      Rq.got.fin(l, H.Http.take(r))
    case RLine{a, n}:
      Got{"", "", ""}

# Answers
# -------

def Wh.reason.go(ok: Bool, bad: Bool, missing: Bool, big: Bool) -> String:
  match ok bad missing big:
    case True{} b m g:
      "OK"
    case False{} True{} m g:
      "Bad Request"
    case False{} False{} True{} g:
      "Not Found"
    case False{} False{} False{} True{}:
      "Payload Too Large"
    case _ _ _ _:
      "Method Not Allowed"

def Wh.reason(+code: U32) -> String:
  Wh.reason.go(U32.is_eq(code, 200), U32.is_eq(code, 400), U32.is_eq(code, 404), U32.is_eq(code, 413))

def Wh.reply(+code: U32, +body: String) -> String:
  "HTTP/1.1 " ++ U32.show(code) ++ " " ++ Wh.reason(code) ++ "\r\nContent-Type: application/json"
    ++ "\r\nContent-Length: " ++ U32.show(U.Utf8.size(body)) ++ "\r\nConnection: close\r\n\r\n" ++ body

def Wh.error(+code: U32, +msg: String) -> String:
  Wh.reply(code, J.Json.show(J.Json.obj([J.KV{"error", J.JStr{msg}}])))

def Wh.strs(ws: List<&2, String>) -> List<&2, J.Json>:
  match ws:
    case Nil{}:
      Nil{}
    case Con{w, t}:
      J.JStr{w} <> Wh.strs(t)

def Wh.code.go(+c: U32, zero: Bool) -> U32:
  match zero:
    case True{}:
      403
    case False{}:
      c

def Wh.code(+c: U32) -> U32:
  Wh.code.go(c, U32.is_eq(c, 0))

def Wh.patch_kvs(ops: List<&2, J.Json>) -> List<&2, J.KV>:
  match ops:
    case Nil{}:
      Nil{}
    case Con{+o, +t}:
      [J.KV{"patchType", J.JStr{"JSONPatch"}},
        J.KV{"patch", J.JStr{B.B64.encode(U.Utf8.encode(J.Json.show(J.Json.arr(o <> t))))}}]

def Wh.status_kvs(allowed: Bool, +code: U32, +msg: String) -> List<&2, J.KV>:
  match allowed:
    case True{}:
      Nil{}
    case False{}:
      [J.KV{"status", J.Json.obj([J.KV{"code", J.JNum{U32.show(Wh.code(code))}}, J.KV{"message", J.JStr{msg}}])}]

def Wh.warn_kvs(ws: List<&2, String>) -> List<&2, J.KV>:
  match ws:
    case Nil{}:
      Nil{}
    case Con{+w, +t}:
      [J.KV{"warnings", J.Json.arr(Wh.strs(w <> t))}]

# The AdmissionReview that answers request uid with the verdict, in the
# review's own apiVersion.
def Wh.admission_review(+av: String, +uid: String, v: Verdict) -> J.Json:
  match v:
    case Verdict{+a, c, m, p, ws}:
      J.Json.obj([J.KV{"apiVersion", J.JStr{av}}, J.KV{"kind", J.JStr{"AdmissionReview"}},
        J.KV{"response", J.Json.obj(List.append(&2, J.KV,
          [J.KV{"uid", J.JStr{uid}}, J.KV{"allowed", J.JBool{a}}],
          List.append(&2, J.KV, Wh.status_kvs(a, c, m), List.append(&2, J.KV, Wh.patch_kvs(p), Wh.warn_kvs(ws)))))}])

def Wh.conv.put(r: Result<&2, &2, String, J.Json>, rest: Result<&2, &2, String, List<&2, J.Json>>) ->
  Result<&2, &2, String, List<&2, J.Json>>:
  match r rest:
    case Done{x} Done{xs}:
      Done{x <> xs}
    case Fail{e} _:
      Fail{e}
    case Done{x} Fail{e}:
      Fail{e}

# Every object converted, or the first failure.
def Wh.converted(~convert: J.Json -> String -> Result<&2, &2, String, J.Json>, xs: List<&2, J.Json>,
  +to: String) -> Result<&2, &2, String, List<&2, J.Json>>:
  match xs:
    case Nil{}:
      Done{Nil{}}
    case Con{x, t}:
      Wh.conv.put(convert(x, to), Wh.converted(~convert, t, to))

def Wh.conv.result(+av: String, +uid: String, r: Result<&2, &2, String, List<&2, J.Json>>) -> J.Json:
  match r:
    case Done{xs}:
      J.Json.obj([J.KV{"apiVersion", J.JStr{av}}, J.KV{"kind", J.JStr{"ConversionReview"}},
        J.KV{"response", J.Json.obj([J.KV{"uid", J.JStr{uid}}, J.KV{"convertedObjects", J.Json.arr(xs)},
          J.KV{"result", J.Json.obj([J.KV{"status", J.JStr{"Success"}}])}])}])
    case Fail{e}:
      J.Json.obj([J.KV{"apiVersion", J.JStr{av}}, J.KV{"kind", J.JStr{"ConversionReview"}},
        J.KV{"response", J.Json.obj([J.KV{"uid", J.JStr{uid}}, J.KV{"convertedObjects", J.Json.arr(Nil{})},
          J.KV{"result", J.Json.obj([J.KV{"status", J.JStr{"Failure"}}, J.KV{"message", J.JStr{e}}])}])}])

# The ConversionReview that answers a request: every object in the desired
# apiVersion, or the first failure.
def Wh.conversion_review(~convert: J.Json -> String -> Result<&2, &2, String, J.Json>, +review: J.Json) ->
  J.Json:
  Wh.conv.result(J.Json.str_or(J.Json.get(review, "apiVersion"), "apiextensions.k8s.io/v1"),
    J.Json.str_or(J.Json.at(review, ["request", "uid"]), ""),
    Wh.converted(~convert, J.Json.items(J.Json.at(review, ["request", "objects"])),
      J.Json.str_or(J.Json.at(review, ["request", "desiredAPIVersion"]), "")))

# What a review is
# ----------------

type Review is Data:
  KAdmission{review: J.Json}
  KConversion{review: J.Json}
  KBad{msg: String}

def Review.of.go(+j: J.Json, +kind: String, adm: Bool, conv: Bool) -> Review:
  match adm conv:
    case True{} c:
      KAdmission{j}
    case False{} True{}:
      KConversion{j}
    case False{} False{}:
      KBad{"not an AdmissionReview or ConversionReview: kind " ++ kind}

def Review.of.json(+j: J.Json, +kind: String) -> Review:
  Review.of.go(j, kind, String.eq(kind, "AdmissionReview"), String.eq(kind, "ConversionReview"))

def Review.of.parsed(r: Result<&2, &2, String, J.Json>) -> Review:
  match r:
    case Done{+j}:
      Review.of.json(j, J.Json.str_or(J.Json.get(j, "kind"), ""))
    case Fail{e}:
      KBad{"bad JSON: " ++ e}

# The review a request body carries.
def Review.of(body: String) -> Review:
  Review.of.parsed(J.Json.parse(body))

