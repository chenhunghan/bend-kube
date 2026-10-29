import Base
import ../src/json.bend as J
import ../src/core.bend as C
import ../src/config.bend as K
import ../src/queue.bend as Q
import ../src/kube.bend as Kb
import ../src/helpers.bend as Hp
import ../src/log.bend as L

# A finalizer guard: every ConfigMap labeled bend-kube/guard=true in
# bend-demo carries the finalizer bend-kube.dev/guard. While it lives, the
# guard records a Normal "Guarded" event (and checks again every 10
# minutes); when it is deleted, the guard records "Released", removes its
# finalizer, and the deletion completes.

def api() -> C.Api:
  C.Api{C.Res.config_maps(), C.InNs{"bend-demo"}}

def finalizer() -> String:
  "bend-kube.dev/guard"

def apply(+o: J.Json, +cfg: K.Config) -> IO(Q.Action):
  do IO<Q.Action>:
    L.Log.info("guarding", [L.Log.kv("name", C.Obj.name(o))])
    Hp.Event.publish(cfg, o, C.Res.config_maps(), False{}, "Guarded", "Reconcile",
      "bend-kube guard holds this ConfigMap", "bend-kube-guard")
    return Q.Requeue{600000}

def cleanup(+o: J.Json, +cfg: K.Config) -> IO(Q.Action):
  do IO<Q.Action>:
    L.Log.info("releasing", [L.Log.kv("name", C.Obj.name(o))])
    Hp.Event.publish(cfg, o, C.Res.config_maps(), False{}, "Released", "Cleanup",
      "bend-kube guard released this ConfigMap", "bend-kube-guard")
    return Q.AwaitChange{}

def apply.of(o: J.Json, cfg: K.Config) -> IO(Q.Action):
  apply(o, cfg)

def cleanup.of(o: J.Json, cfg: K.Config) -> IO(Q.Action):
  cleanup(o, cfg)

def reconcile(o: J.Json, cfg: K.Config) -> IO(Q.Action):
  Hp.Finalizer.run(~apply.of, ~cleanup.of, cfg, api(), finalizer(), o)

def main() -> IO(Unit):
  Kb.Kube.run(~reconcile, api(), Nil{},
    Kb.Opts.with_label(Kb.Opts.default(), "bend-kube/guard=true"))
