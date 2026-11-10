import Base
import ../src/json.bend as J
import ../src/core.bend as C
import ../src/webhook.bend as Wh
import ../src/admission.bend as A
import ../src/log.bend as L

# Admission and conversion webhooks for ConfigMaps (deploy them with a
# ValidatingWebhookConfiguration and a MutatingWebhookConfiguration whose
# clientConfig points here, and a CA bundle that signed the certificate):
#
# - /validate denies a ConfigMap with a "forbidden" key, and warns about
#   one with a "deprecated" key;
# - /mutate labels every ConfigMap bend-kube/mutated=true (a JSON patch);
# - conversion (for a CRD with two versions) renames spec.size (v1) to
#   spec.replicas (v2) and back.
#
# WEBHOOK_PORT (9443), WEBHOOK_CERT and WEBHOOK_KEY (controller-runtime's
# /tmp/k8s-webhook-server/serving-certs/tls.crt and tls.key) say where.

def has(+o: J.Json, key: String) -> Bool:
  Bool.not(J.Json.is_null(J.Json.at(o, ["data", key])))

def validate.go(+o: J.Json, forbidden: Bool, deprecated: Bool) -> A.Verdict:
  match forbidden deprecated:
    case True{} d:
      A.Verdict.deny("ConfigMap " ++ C.Obj.name(o) ++ ": the key \"forbidden\" is not allowed")
    case False{} True{}:
      A.Verdict.warn(A.Verdict.allow(), "the key \"deprecated\" will be refused soon")
    case False{} False{}:
      A.Verdict.allow()

def validate(+o: J.Json) -> A.Verdict:
  validate.go(o, has(o, "forbidden"), has(o, "deprecated"))

# The label, added to the labels there are, or as the first.
def mutate.go(none: Bool) -> A.Verdict:
  match none:
    case True{}:
      A.Verdict.patch([A.Patch.op("add", "/metadata/labels",
        J.Json.obj([J.KV{"bend-kube/mutated", J.JStr{"true"}}]))])
    case False{}:
      A.Verdict.patch([A.Patch.op("add", "/metadata/labels/bend-kube~1mutated", J.JStr{"true"})])

def mutate(+o: J.Json) -> A.Verdict:
  mutate.go(J.Json.is_null(C.Obj.meta(o, "labels")))

def route(+path: String, +o: J.Json, v: Bool, m: Bool) -> IO(A.Verdict):
  match v m:
    case True{} x:
      IO.pure(A.Verdict, validate(o))
    case False{} True{}:
      IO.pure(A.Verdict, mutate(o))
    case False{} False{}:
      IO.pure(A.Verdict, A.Verdict.deny_with(404, "no webhook at " ++ path))

def admit.go(+path: String, +req: J.Json) -> IO(A.Verdict):
  IO.bind(Unit, A.Verdict, L.Log.info("review", [L.Log.kv("path", path),
    L.Log.kv("operation", J.Json.str_or(J.Json.get(req, "operation"), "")),
    L.Log.kv("name", J.Json.str_or(J.Json.get(req, "name"), ""))]),
    u => route(path, J.Json.get(req, "object"), String.eq(path, "/validate"), String.eq(path, "/mutate")))

def admit(path: String, req: J.Json) -> IO(A.Verdict):
  admit.go(path, req)

# spec.size (v1) and spec.replicas (v2) are the same field.
def rename(+o: J.Json, +av: String, +from: String, +to: String) -> J.Json:
  J.Json.set(J.Json.set(o, "apiVersion", J.JStr{av}), "spec",
    J.Json.set(J.Json.del(J.Json.get(o, "spec"), from), to, J.Json.at(o, ["spec", from])))

def convert.go(+o: J.Json, +to: String, v1: Bool, v2: Bool) -> Result<&2, &2, String, J.Json>:
  match v1 v2:
    case True{} x:
      Done{rename(o, to, "replicas", "size")}
    case False{} True{}:
      Done{rename(o, to, "size", "replicas")}
    case False{} False{}:
      Fail{"cannot convert to " ++ to}

def convert.at(+o: J.Json, +to: String) -> Result<&2, &2, String, J.Json>:
  convert.go(o, to, String.ends_with(to, "/v1"), String.ends_with(to, "/v2"))

def convert(o: J.Json, to: String) -> Result<&2, &2, String, J.Json>:
  convert.at(o, to)

def env(r: Result<&1, &1, U32 & String, String>, d: String) -> String:
  match r:
    case Done{v}:
      v
    case Fail{e}:
      d

def main() -> IO(Unit):
  do IO<Unit>:
    p : Result<&1, &1, U32 & String, String> <- IO.get_env("WEBHOOK_PORT")
    c : Result<&1, &1, U32 & String, String> <- IO.get_env("WEBHOOK_CERT")
    k : Result<&1, &1, U32 & String, String> <- IO.get_env("WEBHOOK_KEY")
    Wh.Webhook.serve(~admit, ~convert, Maybe.default(&2, U32, U32.read(env(p, "9443")), 9443),
      env(c, "/tmp/k8s-webhook-server/serving-certs/tls.crt"), env(k, "/tmp/k8s-webhook-server/serving-certs/tls.key"))
