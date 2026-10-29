import Base
import ../src/json.bend as J
import ../src/core.bend as C
import ../src/config.bend as K
import ../src/client.bend as Cl
import ../src/queue.bend as Q
import ../src/kube.bend as Kb
import ../src/log.bend as L

# A ConfigMap mirror: every ConfigMap in bend-demo gets a "<name>-mirror"
# copy of its data, owned by it, kept by server-side apply. Deleting the
# original deletes the copy (garbage collection); editing or deleting the
# copy brings it back (the owned watch triggers the owner).

def api() -> C.Api:
  C.Api{C.Res.config_maps(), C.InNs{"bend-demo"}}

def mirror(+o: J.Json) -> J.Json:
  J.Json.obj([J.KV{"apiVersion", J.JStr{"v1"}}, J.KV{"kind", J.JStr{"ConfigMap"}},
    J.KV{"metadata", J.Json.obj([J.KV{"name", J.JStr{C.Obj.name(o) ++ "-mirror"}},
      J.KV{"namespace", J.JStr{C.Obj.namespace(o)}},
      J.KV{"labels", J.Json.obj([J.KV{"bend-kube/mirror-of", J.JStr{C.Obj.name(o)}}])},
      J.KV{"ownerReferences", J.Json.arr([C.Obj.owner_ref(o, C.Res.config_maps())])}])},
    J.KV{"data", J.Json.get(o, "data")}])

def applied(+name: String, r: Result<&2, &2, Cl.KErr, J.Json>) -> IO(Q.Action):
  match r:
    case Done{j}:
      do IO<Q.Action>:
        L.Log.info("mirrored", [L.Log.kv("name", name), L.Log.kv("rv", C.Obj.rv(j))])
        return Q.Requeue{300000}
    case Fail{+e}:
      do IO<Q.Action>:
        L.Log.error("mirror failed", [L.Log.kv("name", name), L.Log.kv("error", Cl.KErr.show(e))])
        return Q.Retry{Cl.KErr.show(e)}

def reconcile.go(+o: J.Json, cfg: K.Config, copy: Bool, deleting: Bool) -> IO(Q.Action):
  match copy deleting:
    case False{} False{}:
      IO.bind(Result<&2, &2, Cl.KErr, J.Json>, Q.Action,
        Cl.Client.apply(cfg, api(), C.Obj.name(o) ++ "-mirror", "bend-kube-mirror", mirror(o)),
        r => applied(C.Obj.name(o), r))
    case _ _:
      IO.pure(Q.Action, Q.AwaitChange{})

def reconcile.of(+o: J.Json, cfg: K.Config) -> IO(Q.Action):
  reconcile.go(o, cfg, String.ends_with(C.Obj.name(o), "-mirror"), C.Obj.is_deleting(o))

def reconcile(o: J.Json, cfg: K.Config) -> IO(Q.Action):
  reconcile.of(o, cfg)

def opts(id: String) -> Kb.Opts:
  Kb.Opts.with_leader(Kb.Opts.default(), "bend-demo", "bend-kube-mirror", id)

def main.id(r: Result<&1, &1, U32 & String, String>) -> IO(Unit):
  match r:
    case Done{id}:
      Kb.Kube.run(~reconcile, api(), [api()], opts(id))
    case Fail{e}:
      Kb.Kube.run(~reconcile, api(), [api()], opts("bend-kube-mirror"))

# The leader identity is the pod's name (HOSTNAME in a pod).
def main() -> IO(Unit):
  IO.bind(Result<&1, &1, U32 & String, String>, Unit, IO.get_env("HOSTNAME"), main.id)
