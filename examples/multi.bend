import Base
import ../src/json.bend as J
import ../src/core.bend as C
import ../src/config.bend as K
import ../src/client.bend as Cl
import ../src/queue.bend as Q
import ../src/runtime.bend as R
import ../src/kube.bend as Kb
import ../src/log.bend as L

# Two controllers in one process, sharing their watches: a mirror (as
# mirror.bend: ConfigMaps in bend-demo, owning their copies) and an
# auditor that logs every ConfigMap it sees. Three subscriptions (the
# mirror's primary and owned, the auditor's primary) are one watch on
# the API server.

def api() -> C.Api:
  C.Api{C.Res.config_maps(), C.InNs{"bend-demo"}}

def mirror.body(+o: J.Json) -> J.Json:
  J.Json.obj([J.KV{"apiVersion", J.JStr{"v1"}}, J.KV{"kind", J.JStr{"ConfigMap"}},
    J.KV{"metadata", J.Json.obj([J.KV{"name", J.JStr{C.Obj.name(o) ++ "-mirror"}},
      J.KV{"namespace", J.JStr{C.Obj.namespace(o)}},
      J.KV{"ownerReferences", J.Json.arr([C.Obj.owner_ref(o, C.Res.config_maps())])}])},
    J.KV{"data", J.Json.get(o, "data")}])

def mirror.done(r: Result<&2, &2, Cl.KErr, J.Json>) -> IO(Q.Action):
  match r:
    case Done{j}:
      IO.pure(Q.Action, Q.Requeue{300000})
    case Fail{+e}:
      IO.pure(Q.Action, Q.Retry{Cl.KErr.show(e)})

def mirror(+o: J.Json, cfg: K.Config, copy: Bool) -> IO(Q.Action):
  match copy:
    case True{}:
      IO.pure(Q.Action, Q.AwaitChange{})
    case False{}:
      IO.bind(Result<&2, &2, Cl.KErr, J.Json>, Q.Action,
        Cl.Client.apply(cfg, api(), C.Obj.name(o) ++ "-mirror", "bend-kube-multi", mirror.body(o)),
        mirror.done)

def audit(+o: J.Json) -> IO(Q.Action):
  IO.bind(Unit, Q.Action, L.Log.info("audit", [L.Log.kv("configmap", C.Obj.key(o)), L.Log.kv("rv", C.Obj.rv(o))]),
    u => IO.pure(Q.Action, Q.AwaitChange{}))

def rec.go(+o: J.Json, cfg: K.Config, first: Bool) -> IO(Q.Action):
  match first:
    case True{}:
      mirror(o, cfg, String.ends_with(C.Obj.name(o), "-mirror"))
    case False{}:
      audit(o)

def rec(i: U32, o: J.Json, cfg: K.Config) -> IO(Q.Action):
  rec.go(o, cfg, U32.is_eq(i, 0))

def main() -> IO(Unit):
  Kb.Kube.run_all(~rec, [R.Ctrl{api(), "", [api()], 4}, R.Ctrl{api(), "", Nil{}, 2}], Kb.Opts.default())
