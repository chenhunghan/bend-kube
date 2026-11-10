import Base
import ../src/json.bend as J
import ../src/core.bend as C
import ../src/config.bend as K
import ../src/client.bend as Cl
import ../src/queue.bend as Q
import ../src/control.bend as X
import ../src/kube.bend as Kb
import ../src/log.bend as L

# A two-cluster syncer, as vcluster's: every ConfigMap labelled
# bend-kube/sync=true in bend-demo, in the controller's own cluster (the
# "virtual" one), gets a copy in bend-demo-host on the host cluster that
# HOST_KUBECONFIG names. The copy is named <name>-x-<namespace> and
# annotated with where it came from, so a change to it on the host maps
# back to its source (X.RAnnotated).
#
# The host watch is a related watch on another cluster (X.Spec.watch_on),
# filtered by annotations (X.Spec.watch_filter): a copy deleted, or
# re-pointed at another source, is synced again at once; an edit of its
# data alone is not (the source owns the data, and its next change
# overwrites it). The reconcile writes through that watch's config
# (X.Ctx.cluster(ctx, 1)). A source's deletion leaves its copy; a syncer
# that must clean up adds a finalizer, as guard.bend does.

def src() -> C.Api:
  C.Api{C.Res.config_maps(), C.InNs{"bend-demo"}}

def host_ns() -> String:
  "bend-demo-host"

def host() -> C.Api:
  C.Api{C.Res.config_maps(), C.InNs{host_ns()}}

def copy_name(+o: J.Json) -> String:
  C.Obj.name(o) ++ "-x-" ++ C.Obj.namespace(o)

def copy(+o: J.Json) -> J.Json:
  J.Json.obj([J.KV{"apiVersion", J.JStr{"v1"}}, J.KV{"kind", J.JStr{"ConfigMap"}},
    J.KV{"metadata", J.Json.obj([J.KV{"name", J.JStr{copy_name(o)}},
      J.KV{"namespace", J.JStr{host_ns()}},
      J.KV{"labels", J.Json.obj([J.KV{"bend-kube/synced", J.JStr{"true"}}])},
      J.KV{"annotations", J.Json.obj([J.KV{"bend-kube/object-namespace", J.JStr{C.Obj.namespace(o)}},
        J.KV{"bend-kube/object-name", J.JStr{C.Obj.name(o)}}])}])},
    J.KV{"data", J.Json.get(o, "data")}])

def synced(+name: String, +server: String, r: Result<&2, &2, Cl.KErr, J.Json>) -> IO(Q.Action):
  match r:
    case Done{j}:
      do IO<Q.Action>:
        L.Log.info("synced", [L.Log.kv("name", name), L.Log.kv("host", server), L.Log.kv("rv", C.Obj.rv(j))])
        return Q.AwaitChange{}
    case Fail{+e}:
      do IO<Q.Action>:
        L.Log.error("sync failed", [L.Log.kv("name", name), L.Log.kv("error", Cl.KErr.show(e))])
        return Q.Retry{Cl.KErr.show(e)}

def reconcile.on(+o: J.Json, +hc: K.Config) -> IO(Q.Action):
  IO.bind(Result<&2, &2, Cl.KErr, J.Json>, Q.Action,
    Cl.Client.apply(hc, host(), copy_name(o), "bend-kube-sync", copy(o)),
    r => synced(C.Obj.key(o), K.Config.host(hc), r))

def reconcile(o: J.Json, ctx: X.Ctx) -> IO(Q.Action):
  reconcile.on(o, X.Ctx.cluster(ctx, 1))

def spec(+hc: K.Config) -> X.Spec:
  X.Spec.watch_filter(X.Spec.watch_on(
    X.Spec.watches_where(X.Spec.label(X.Spec.of(src()), "bend-kube/sync=true"), host(), "bend-kube/synced=true", "",
      X.RAnnotated{"bend-kube/object-namespace", "bend-kube/object-name"}), hc),
    [X.PAnnotations{}])

def opts() -> Kb.Opts:
  Kb.Opts.with_timeout(Kb.Opts.with_election(Kb.Opts.default(), "bend-demo", "bend-kube-sync"), 60000)

def start(c: Result<&2, &2, String, K.Config>) -> IO(Unit):
  match c:
    case Done{hc}:
      IO.bind(K.Config, Unit, Kb.Kube.connect(hc, 20, 40),
        +h => IO.bind(Unit, Unit, L.Log.info("host cluster", [L.Log.kv("server", K.Config.host(h))]),
          u => Kb.Kube.control(~reconcile, spec(h), opts())))
    case Fail{e}:
      IO.die(Unit, 1, "sync: no host cluster: " ++ e)

def path(r: Result<&1, &1, U32 & String, String>) -> IO(Unit):
  match r:
    case Done{p}:
      IO.bind(Result<&2, &2, String, K.Config>, Unit, Cl.Config.from_kubeconfig(p, ""), start)
    case Fail{e}:
      IO.die(Unit, 1, "sync: set HOST_KUBECONFIG to the host cluster's kubeconfig")

def main() -> IO(Unit):
  IO.bind(Result<&1, &1, U32 & String, String>, Unit, IO.get_env("HOST_KUBECONFIG"), path)
