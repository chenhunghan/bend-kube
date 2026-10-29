import Base
import ./json.bend as J
import ./core.bend as C
import ./config.bend as K
import ./client.bend as Cl
import ./queue.bend as Q
import ./finalizer.bend as F
import ./sys.bend as Y
import ./time.bend as T
import ./log.bend as L

# Helpers
# =======
#
# What a reconciler reaches for: kube-runtime's finalizer() and an Event
# recorder (client-go's record.EventRecorder, on events.k8s.io/v1).

# Finalizers
# ----------

def Fin.added(r: Result<&2, &2, Cl.KErr, J.Json>) -> IO(Q.Action):
  match r:
    case Done{o}:
      # the patch itself triggers the next reconcile
      IO.pure(Q.Action, Q.AwaitChange{})
    case Fail{+e}:
      IO.bind(Unit, Q.Action, L.Log.warn("adding finalizer failed", [L.Log.kv("error", Cl.KErr.show(e))]),
        u => IO.pure(Q.Action, Q.Retry{Cl.KErr.show(e)}))

def Fin.removed(a: Q.Action, r: Result<&2, &2, Cl.KErr, J.Json>) -> IO(Q.Action):
  match r:
    case Done{o}:
      IO.pure(Q.Action, a)
    case Fail{+e}:
      IO.bind(Unit, Q.Action, L.Log.warn("removing finalizer failed", [L.Log.kv("error", Cl.KErr.show(e))]),
        u => IO.pure(Q.Action, Q.Retry{Cl.KErr.show(e)}))

# After a cleanup: a failed one keeps the finalizer (and retries); a
# finished one removes it, through a patch that tests it is still ours.
def Fin.cleaned(+cfg: K.Config, api: C.Api, name: String, patch: J.Json, a: Q.Action) -> IO(Q.Action):
  match a:
    case Q.Retry{m}:
      IO.pure(Q.Action, Q.Retry{m})
    case +x:
      IO.bind(Result<&2, &2, Cl.KErr, J.Json>, Q.Action, Cl.Client.patch(cfg, api, name, C.PJson{}, patch),
        r => Fin.removed(x, r))

def Fin.run.go(~apply: J.Json -> K.Config -> IO(Q.Action), ~cleanup: J.Json -> K.Config -> IO(Q.Action),
  +cfg: K.Config, +api: C.Api, +o: J.Json, s: F.FState) -> IO(Q.Action):
  match s:
    case F.FApply{}:
      apply(o, cfg)
    case F.FAdd{p}:
      IO.bind(Result<&2, &2, Cl.KErr, J.Json>, Q.Action, Cl.Client.patch(cfg, api, C.Obj.name(o), C.PJson{}, p),
        Fin.added)
    case F.FCleanup{p}:
      IO.bind(Q.Action, Q.Action, cleanup(o, cfg), a => Fin.cleaned(cfg, api, C.Obj.name(o), p, a))
    case F.FDone{}:
      IO.pure(Q.Action, Q.AwaitChange{})

# Reconciles o under the finalizer called name (kube-runtime's finalizer):
# apply while it lives, cleanup once it is deleted. Both must be
# idempotent; a cleanup that answers Retry keeps the object alive.
def Finalizer.run(~apply: J.Json -> K.Config -> IO(Q.Action),
  ~cleanup: J.Json -> K.Config -> IO(Q.Action), +cfg: K.Config, +api: C.Api, name: String,
  +o: J.Json) -> IO(Q.Action):
  Fin.run.go(~apply, ~cleanup, cfg, api, o, F.Fin.state(o, name))

# Events
# ------

def Event.regarding(+o: J.Json, +r: C.Res) -> J.Json:
  J.Json.obj([J.KV{"apiVersion", J.JStr{C.Res.api_version(r)}}, J.KV{"kind", J.JStr{C.Res.kind(r)}},
    J.KV{"name", J.JStr{C.Obj.name(o)}}, J.KV{"namespace", J.JStr{C.Obj.namespace(o)}},
    J.KV{"uid", J.JStr{C.Obj.uid(o)}}, J.KV{"resourceVersion", J.JStr{C.Obj.rv(o)}}])

def Event.kind(warn: Bool) -> String:
  match warn:
    case True{}:
      "Warning"
    case False{}:
      "Normal"

def Event.ns.go(ns: String, empty: Bool) -> String:
  match empty:
    case True{}:
      "default"
    case False{}:
      ns

# Cluster-scoped objects record their events in "default".
def Event.ns(+ns: String) -> String:
  Event.ns.go(ns, String.is_empty(ns))

# The Event is named "<object>.<unix microseconds>", as client-go names
# them "<object>.<unix nanoseconds in hex>".
def Event.body(+o: J.Json, +r: C.Res, warn: Bool, reason: String, action: String, note: String,
  +controller: String, +now: String, id: String) -> J.Json:
  J.Json.obj([J.KV{"apiVersion", J.JStr{"events.k8s.io/v1"}}, J.KV{"kind", J.JStr{"Event"}},
    J.KV{"metadata", J.Json.obj([J.KV{"name", J.JStr{C.Obj.name(o) ++ "." ++ id}},
      J.KV{"namespace", J.JStr{Event.ns(C.Obj.namespace(o))}}])},
    J.KV{"eventTime", J.JStr{now}}, J.KV{"reportingController", J.JStr{controller}},
    J.KV{"reportingInstance", J.JStr{controller}}, J.KV{"action", J.JStr{action}},
    J.KV{"reason", J.JStr{reason}}, J.KV{"type", J.JStr{Event.kind(warn)}}, J.KV{"note", J.JStr{note}},
    J.KV{"regarding", Event.regarding(o, r)}])

def Event.sent(r: Result<&2, &2, Cl.KErr, J.Json>) -> IO(Unit):
  match r:
    case Done{e}:
      IO.pure(Unit, Unit{})
    case Fail{e}:
      L.Log.warn("publishing event failed", [L.Log.kv("error", Cl.KErr.show(e))])

type Stamp is Data:
  Stamp{now: String, id: String}

def Event.stamp(+w: T.Wall) -> Stamp:
  Stamp{T.Wall.micro(w), T.Wall.id(w)}

def Event.post(+cfg: K.Config, +o: J.Json, +r: C.Res, warn: Bool, reason: String, action: String,
  note: String, controller: String, st: Stamp) -> IO(Unit):
  match st:
    case Stamp{now, id}:
      IO.bind(Result<&2, &2, Cl.KErr, J.Json>, Unit,
        Cl.Client.create(cfg, C.Api{C.Res.events(), C.InNs{Event.ns(C.Obj.namespace(o))}},
          Event.body(o, r, warn, reason, action, note, controller, now, id)),
        Event.sent)

# Records an Event about o (of resource r). A failure is logged, never
# raised: events are best effort, as client-go's are.
def Event.publish(+cfg: K.Config, +o: J.Json, +r: C.Res, warn: Bool, reason: String, action: String,
  note: String, controller: String) -> IO(Unit):
  IO.bind(U32 & (U32 & U32), Unit, Y.Sys.wall(),
    w => Event.post(cfg, o, r, warn, reason, action, note, controller, Event.stamp(T.Wall.of(w))))
