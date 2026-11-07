import Base
import ../src/json.bend as J
import ../src/core.bend as C
import ../src/config.bend as K
import ../src/client.bend as Cl
import ../src/queue.bend as Q
import ../src/control.bend as X
import ../src/kube.bend as Kb
import ../src/log.bend as L
import ../src/helpers.bend as Hp

# A controller that reads from its caches and follows a reference: every
# ConfigMap labeled bend-kube/bundle=true in bend-demo names a Secret in
# its data.secret; the controller keeps an owned ConfigMap "<name>-keys"
# listing that Secret's key names (never its values).
#
# - Secrets are a related watch (cache 2) with an RRef relation: a change
#   to a Secret reconciles every bundle whose data.secret names it, so the
#   key list follows the Secret without polling.
# - The reconcile reads the Secret from the cache (X.Ctx.find), not from
#   the API server, and counts the outputs it owns from the cache of owned
#   ConfigMaps (cache 1, X.Ctx.children).
# - The generation predicate is set; ConfigMaps have no generation, so
#   every change still passes, as it should.
# - It keeps its own metrics (Metrics.add, Metrics.set): syncs per bundle
#   and the key count of each bundle's Secret.

def ns() -> String:
  "bend-demo"

def cms() -> C.Api:
  C.Api{C.Res.config_maps(), C.InNs{ns()}}

def spec() -> X.Spec:
  X.Spec.filter(
    X.Spec.watches(
      X.Spec.watches_where(X.Spec.label(X.Spec.of(cms()), "bend-kube/bundle=true"), cms(),
        "bend-kube/bundle-output=true", "", X.ROwner{}),
      C.Api{C.Res.secrets(), C.InNs{ns()}}, X.RRef{["data", "secret"]}),
    [X.PGeneration{}])

def keys.of(ks: List<&2, String>) -> List<&2, J.Json>:
  match ks:
    case Nil{}:
      Nil{}
    case Con{k, t}:
      J.JStr{k} <> keys.of(t)

def keys(d: J.Json) -> List<&2, J.Json>:
  keys.of(J.Json.keys(d))

def output(+o: J.Json, +secret: String, found: Maybe<&2, J.Json>) -> J.Json:
  J.Json.obj([J.KV{"apiVersion", J.JStr{"v1"}}, J.KV{"kind", J.JStr{"ConfigMap"}},
    J.KV{"metadata", J.Json.obj([J.KV{"name", J.JStr{C.Obj.name(o) ++ "-keys"}},
      J.KV{"namespace", J.JStr{ns()}},
      J.KV{"labels", J.Json.obj([J.KV{"bend-kube/bundle-output", J.JStr{"true"}}])},
      J.KV{"ownerReferences", J.Json.arr([C.Obj.owner_ref(o, C.Res.config_maps())])}])},
    J.KV{"data", J.Json.obj([J.KV{"secret", J.JStr{secret}},
      J.KV{"keys", J.JStr{J.Json.show(J.Json.arr(keys(J.Json.get(Maybe.default(&2, J.Json, found, J.JNull{}), "data"))))}}])}])

def done(r: Result<&2, &2, Cl.KErr, J.Json>) -> IO(Q.Action):
  match r:
    case Done{j}:
      IO.pure(Q.Action, Q.AwaitChange{})
    case Fail{+e}:
      IO.pure(Q.Action, Q.Retry{Cl.KErr.show(e)})

def run(+o: J.Json, +c: X.Ctx, +secret: String) -> IO(Q.Action):
  do IO<Q.Action>:
    L.Log.info("bundle", [L.Log.kv("name", C.Obj.name(o)), L.Log.kv("secret", secret),
      L.Log.kv("owned", Nat.show(List.length(&2, J.Json, X.Ctx.children(c, 1, o))))])
    r : Result<&2, &2, Cl.KErr, J.Json> <- Cl.Client.apply(X.Ctx.cfg(c), cms(), C.Obj.name(o) ++ "-keys",
      "bend-kube-bundle", output(o, secret, X.Ctx.find(c, 2, ns() ++ "/" ++ secret)))
    # the controller's own metrics, served on /metrics beside bend-kube's
    Hp.Metrics.add(c, "bundle_syncs_total", "bundle=\"" ++ C.Obj.name(o) ++ "\"", 1)
    Hp.Metrics.set(c, "bundle_secret_keys", "bundle=\"" ++ C.Obj.name(o) ++ "\"",
      U32.from_nat(List.length(&2, J.Json, keys(J.Json.get(Maybe.default(&2, J.Json,
        X.Ctx.find(c, 2, ns() ++ "/" ++ secret), J.JNull{}), "data")))))
    done(r)

def reconcile.of(+o: J.Json, c: X.Ctx) -> IO(Q.Action):
  run(o, c, J.Json.str_or(J.Json.at(o, ["data", "secret"]), ""))

def reconcile(o: J.Json, c: X.Ctx) -> IO(Q.Action):
  reconcile.of(o, c)

def main() -> IO(Unit):
  Kb.Kube.control(~reconcile, spec(), Kb.Opts.with_port(Kb.Opts.default(), 0))
