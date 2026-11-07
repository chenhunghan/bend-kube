import Base
import ../src/json.bend as J
import ../src/core.bend as C
import ../src/config.bend as K
import ../src/client.bend as Cl
import ../src/queue.bend as Q
import ../src/kube.bend as Kb
import ../src/control.bend as X
import ../src/cond.bend as Co
import ../src/sys.bend as Y
import ../src/time.bend as T
import ../src/helpers.bend as Hp
import ../src/log.bend as L
import ./gen/website.bend as Wb

# A typed operator: each Website (deploy/website-crd.yaml, types generated
# into gen/website.bend by tools/gen.py) is served by a Deployment it
# owns. The spec is decoded into WebsiteSpec; a bad one is reported as a
# Warning event and left until it changes. The Deployment is kept by
# server-side apply; the Website's status (phase, readyReplicas,
# observedGeneration) by its status subresource. Deployment changes
# reconcile their Website through ownerReferences. The generation predicate
# keeps the operator's own status writes from waking it: only spec changes
# (and deletions) of a Website, and any change to its Deployment, do.

def websites() -> C.Api:
  Wb.Website.api(C.AllNs{})

def deployments(ns: String) -> C.Api:
  C.Api{C.Res.deployments(), C.InNs{ns}}

def manager() -> String:
  "bend-kube-website"

def env.to(xs: List<&2, Wb.WebsiteSpecEnvItem>) -> List<&2, J.Json>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{e, t}:
      Wb.WebsiteSpecEnvItem.to(e) <> env.to(t)

def labels(+o: J.Json) -> J.Json:
  J.Json.obj([J.KV{"app.kubernetes.io/name", J.JStr{C.Obj.name(o)}},
    J.KV{"app.kubernetes.io/managed-by", J.JStr{manager()}}])

# The Deployment a Website asks for.
def deployment(+o: J.Json, s: Wb.WebsiteSpec) -> J.Json:
  match s:
    case Wb.WebsiteSpec{image, replicas, port, env}:
      J.Json.obj([J.KV{"apiVersion", J.JStr{"apps/v1"}}, J.KV{"kind", J.JStr{"Deployment"}},
        J.KV{"metadata", J.Json.obj([J.KV{"name", J.JStr{C.Obj.name(o)}},
          J.KV{"namespace", J.JStr{C.Obj.namespace(o)}},
          J.KV{"ownerReferences", J.Json.arr([C.Obj.owner_ref(o, Wb.Website.res())])}])},
        J.KV{"spec", J.Json.obj([
          J.KV{"replicas", J.Json.u32(Maybe.default(&2, U32, replicas, 1))},
          J.KV{"selector", J.Json.obj([J.KV{"matchLabels", labels(o)}])},
          J.KV{"template", J.Json.obj([
            J.KV{"metadata", J.Json.obj([J.KV{"labels", labels(o)}])},
            J.KV{"spec", J.Json.obj([J.KV{"containers", J.Json.arr([J.Json.obj([
              J.KV{"name", J.JStr{"web"}}, J.KV{"image", J.JStr{image}},
              J.KV{"ports", J.Json.arr([J.Json.obj([J.KV{"containerPort",
                J.Json.u32(Maybe.default(&2, U32, port, 80))}])])},
              J.KV{"env", J.Json.arr(env.to(env))}])])}])}])}])}])

def phase.go(done: Bool) -> String:
  match done:
    case True{}:
      "Ready"
    case False{}:
      "Progressing"

def ready(+d: J.Json) -> U32:
  Maybe.default(&2, U32, J.Json.as_u32(J.Json.at(d, ["status", "readyReplicas"])), 0)

def phase(+ready: U32, +want: U32) -> String:
  phase.go(U32.is_ge(ready, want))

# The Website's status, from the Deployment the apply answered with.
def status(+o: J.Json, +d: J.Json, +want: U32) -> Wb.WebsiteStatus:
  Wb.WebsiteStatus{Some{phase(ready(d), want)}, Some{ready(d)}, Some{C.Obj.generation(o)}, Nil{}}

def ready_cond.status(done: Bool) -> String:
  match done:
    case True{}:
      "True"
    case False{}:
      "False"

def ready_cond.reason(done: Bool) -> String:
  match done:
    case True{}:
      "ReplicasReady"
    case False{}:
      "ReplicasStarting"

def ready_cond.go(+o: J.Json, +r: U32, +want: U32, +now: String, +done: Bool) -> List<&2, J.Json>:
  Co.Cond.set(Co.Cond.list(o), Co.Cond.make("Ready", ready_cond.status(done), ready_cond.reason(done),
    U32.show(r) ++ " of " ++ U32.show(want) ++ " replicas ready", C.Obj.generation(o), now))

# The Ready condition (meta.SetStatusCondition: its transition time moves
# only when its status does).
def ready_cond(+o: J.Json, +d: J.Json, +want: U32, +now: String) -> List<&2, J.Json>:
  ready_cond.go(o, ready(d), want, now, U32.is_ge(ready(d), want))

# The status patch: the typed fields, and the conditions.
def status_body(+o: J.Json, +d: J.Json, +want: U32, +now: String) -> J.Json:
  J.Json.set(Wb.Website.status_patch(status(o, d, want)), "status",
    J.Json.set(J.Json.get(Wb.Website.status_patch(status(o, d, want)), "status"), "conditions",
      J.Json.arr(ready_cond(o, d, want, now))))

def reported(r: Result<&2, &2, Cl.KErr, J.Json>) -> IO(Q.Action):
  match r:
    case Done{x}:
      # deployment changes come back through the owned watch
      IO.pure(Q.Action, Q.Requeue{300000})
    case Fail{+e}:
      IO.bind(Unit, Q.Action, L.Log.warn("status update failed", [L.Log.kv("error", Cl.KErr.show(e))]),
        u => IO.pure(Q.Action, Q.Retry{Cl.KErr.show(e)}))

def websites.ns(ns: String) -> C.Api:
  Wb.Website.api(C.InNs{ns})

def applied(+o: J.Json, +cfg: K.Config, +want: U32, r: Result<&2, &2, Cl.KErr, J.Json>) -> IO(Q.Action):
  match r:
    case Done{+d}:
      IO.bind(U32 & (U32 & U32), Q.Action, Y.Sys.wall(),
        w => IO.bind(Result<&2, &2, Cl.KErr, J.Json>, Q.Action,
          Cl.Client.patch_status(cfg, websites.ns(C.Obj.namespace(o)), C.Obj.name(o), C.PMerge{},
            status_body(o, d, want, T.Wall.rfc3339(T.Wall.of(w)))),
          reported))
    case Fail{+e}:
      IO.bind(Unit, Q.Action, L.Log.error("apply failed", [L.Log.kv("website", C.Obj.key(o)),
        L.Log.kv("error", Cl.KErr.show(e))]), u => IO.pure(Q.Action, Q.Retry{Cl.KErr.show(e)}))

def spec.want(s: Wb.WebsiteSpec) -> U32:
  match s:
    case Wb.WebsiteSpec{i, r, p, e}:
      Maybe.default(&2, U32, r, 1)

def run(+o: J.Json, +cfg: K.Config, w: Result<&2, &2, String, Wb.Website>) -> IO(Q.Action):
  match w:
    case Done{Wb.Website{m, +spec, st}}:
      IO.bind(Result<&2, &2, Cl.KErr, J.Json>, Q.Action,
        Cl.Client.apply(cfg, deployments(C.Obj.namespace(o)), C.Obj.name(o), manager(), deployment(o, spec)),
        r => applied(o, cfg, spec.want(spec), r))
    case Fail{+e}:
      do IO<Q.Action>:
        L.Log.warn("invalid website", [L.Log.kv("website", C.Obj.key(o)), L.Log.kv("error", e)])
        Hp.Event.publish(cfg, o, Wb.Website.res(), True{}, "InvalidSpec", "Reconcile", e, manager())
        return Q.AwaitChange{}

def reconcile.of(+o: J.Json, +cfg: K.Config) -> IO(Q.Action):
  run(o, cfg, Wb.Website.of(o))

def reconcile(o: J.Json, c: X.Ctx) -> IO(Q.Action):
  reconcile.of(o, X.Ctx.cfg(c))

# Websites, filtered by generation, owning Deployments.
def spec() -> X.Spec:
  X.Spec.filter(X.Spec.owns(X.Spec.of(websites()), C.Api{C.Res.deployments(), C.AllNs{}}),
    [X.PGeneration{}])

def main.id(r: Result<&1, &1, U32 & String, String>) -> IO(Unit):
  match r:
    case Done{id}:
      Kb.Kube.control(~reconcile, spec(),
        Kb.Opts.with_election(Kb.Opts.default(), "bend-kube-system", "bend-kube-website"))
    case Fail{e}:
      # outside a pod (no HOSTNAME): run alone, without leader election
      Kb.Kube.control(~reconcile, spec(), Kb.Opts.default())

def main() -> IO(Unit):
  IO.bind(Result<&1, &1, U32 & String, String>, Unit, IO.get_env("HOSTNAME"), main.id)
