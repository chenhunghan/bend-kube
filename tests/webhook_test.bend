import Base
import ../src/json.bend as J
import ../src/utf8.bend as U
import ../src/admission.bend as A

# Scenarios through the webhook's pure side: requests read off the wire in
# awkward pieces, the reviews a handler's verdicts become, and conversions.

def bytes(s: String) -> List<&2, U32>:
  U.Utf8.encode(s)

def feed_all(cs: List<&2, String>, st: A.Rq) -> A.Rq:
  match cs:
    case Nil{}:
      st
    case Con{c, t}:
      feed_all(t, A.Rq.feed(st, bytes(c)))

def yes(b: Bool) -> String:
  match b:
    case True{}:
      "yes"
    case False{}:
      "no"

def got.of(g: A.Got) -> String:
  match g:
    case A.Got{m, p, b}:
      m ++ " " ++ p ++ " body " ++ b

def got(+st: A.Rq) -> String:
  "done " ++ yes(A.Rq.done(st)) ++ ", broken " ++ yes(A.Rq.broken(st)) ++ ", " ++ got.of(A.Rq.got(st))

def review(+body: String) -> String:
  "{\"apiVersion\": \"admission.k8s.io/v1\", \"kind\": \"AdmissionReview\", \"request\": {\"uid\": \"u1\"}} " ++ body

def conv.at(+o: J.Json, +to: String, ok: Bool) -> Result<&2, &2, String, J.Json>:
  match ok:
    case True{}:
      Done{J.Json.set(o, "apiVersion", J.JStr{to})}
    case False{}:
      Fail{"no way to " ++ to}

def conv.go(+o: J.Json, +to: String) -> Result<&2, &2, String, J.Json>:
  conv.at(o, to, String.ends_with(to, "/v2"))

def conv(o: J.Json, to: String) -> Result<&2, &2, String, J.Json>:
  conv.go(o, to)

def js.of(r: Result<&2, &2, String, J.Json>) -> J.Json:
  match r:
    case Done{j}:
      j
    case Fail{e}:
      J.JStr{"bad json: " ++ e}

def js(s: String) -> J.Json:
  js.of(J.Json.parse(s))

def kind(r: A.Review) -> String:
  match r:
    case A.KAdmission{j}:
      "admission"
    case A.KConversion{j}:
      "conversion"
    case A.KBad{m}:
      "bad: " ++ m

def main() -> IO(Unit):
  do IO<Unit>:
    # Cut mid request line, mid header, and mid body.
    IO.print("in pieces: " ++ got(feed_all(["POST /vali", "date?timeout=10s HTTP/1.1\r\nHost: h\r\nContent-Le",
      "ngth: 11\r\nContent-Type: application/json\r\n\r\n{\"a\":", " true}"], A.Rq.init())))
    IO.print("not yet: " ++ got(feed_all(["POST /v HTTP/1.1\r\nContent-Length: 11\r\n\r\n{\"a\":"], A.Rq.init())))
    IO.print("chunked: " ++ got(feed_all(["POST /m HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",
      "4\r\n{\"b\"\r\n", "3\r\n:1}\r\n0\r\n\r\n"], A.Rq.init())))
    IO.print("no body: " ++ got(feed_all(["GET /healthz HTTP/1.1\r\nHost: h\r\n\r\n"], A.Rq.init())))
    IO.print("broken: " ++ got(feed_all(["POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\nzz\r\n"], A.Rq.init())))
    IO.print("size: " ++ U32.show(A.Rq.size(feed_all(["POST / HTTP/1.1\r\n", "Content-Length: 0\r\n\r\n"], A.Rq.init()))))
    IO.print("allow: " ++ J.Json.show(A.Wh.admission_review("admission.k8s.io/v1", "u1", A.Verdict.allow())))
    IO.print("deny: " ++ J.Json.show(A.Wh.admission_review("admission.k8s.io/v1", "u2", A.Verdict.deny("no"))))
    IO.print("deny 422: " ++ J.Json.show(A.Wh.admission_review("admission.k8s.io/v1", "u3", A.Verdict.deny_with(422, "bad spec"))))
    IO.print("patch and warn: " ++ J.Json.show(A.Wh.admission_review("admission.k8s.io/v1beta1", "u4",
      A.Verdict.warn(A.Verdict.patch([A.Patch.op("add", "/metadata/labels/x", J.JStr{"y"})]), "careful"))))
    IO.print("convert: " ++ J.Json.show(A.Wh.conversion_review(~conv, js("{\"apiVersion\": \"apiextensions.k8s.io/v1\", \"kind\": \"ConversionReview\", \"request\": {\"uid\": \"c1\", \"desiredAPIVersion\": \"x.dev/v2\", \"objects\": [{\"apiVersion\": \"x.dev/v1\", \"kind\": \"T\"}, {\"apiVersion\": \"x.dev/v1\", \"kind\": \"T\", \"metadata\": {\"name\": \"b\"}}]}}"))))
    IO.print("convert fails: " ++ J.Json.show(A.Wh.conversion_review(~conv, js("{\"apiVersion\": \"apiextensions.k8s.io/v1\", \"kind\": \"ConversionReview\", \"request\": {\"uid\": \"c2\", \"desiredAPIVersion\": \"x.dev/v3\", \"objects\": [{\"apiVersion\": \"x.dev/v1\"}]}}"))))
    IO.print("kinds: " ++ kind(A.Review.of("{\"kind\": \"AdmissionReview\"}")) ++ ", " ++ kind(A.Review.of("{\"kind\": \"ConversionReview\"}"))
      ++ ", " ++ kind(A.Review.of("{\"kind\": \"Pod\"}")) ++ ", " ++ kind(A.Review.of("{oops")))
