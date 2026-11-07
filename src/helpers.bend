import Base
import ./json.bend as J
import ./core.bend as C
import ./config.bend as K
import ./client.bend as Cl
import ./queue.bend as Q
import ./finalizer.bend as F
import ./control.bend as X
import ./sys.bend as Y
import ./time.bend as T
import ./log.bend as L
import ./utf8.bend as U

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

# After a cleanup: a failed one (Retry, RetryIn) or an unfinished one
# (Hold) keeps the finalizer and runs again; a finished one removes it, through a patch that tests it is still ours.
def Fin.cleaned.go(+cfg: K.Config, api: C.Api, name: String, patch: J.Json, +a: Q.Action, keep: Bool) ->
  IO(Q.Action):
  match keep:
    case True{}:
      IO.pure(Q.Action, a)
    case False{}:
      IO.bind(Result<&2, &2, Cl.KErr, J.Json>, Q.Action, Cl.Client.patch(cfg, api, name, C.PJson{}, patch),
        r => Fin.removed(a, r))

def Fin.cleaned(+cfg: K.Config, api: C.Api, name: String, patch: J.Json, +a: Q.Action) -> IO(Q.Action):
  Fin.cleaned.go(cfg, api, name, patch, a, F.Fin.keeps(a))

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

def Fin.ctl.go(~apply: J.Json -> X.Ctx -> IO(Q.Action), ~cleanup: J.Json -> X.Ctx -> IO(Q.Action),
  +ctx: X.Ctx, +api: C.Api, +o: J.Json, s: F.FState) -> IO(Q.Action):
  match s:
    case F.FApply{}:
      apply(o, ctx)
    case F.FAdd{p}:
      IO.bind(Result<&2, &2, Cl.KErr, J.Json>, Q.Action,
        Cl.Client.patch(X.Ctx.cfg(ctx), api, C.Obj.name(o), C.PJson{}, p), Fin.added)
    case F.FCleanup{p}:
      IO.bind(Q.Action, Q.Action, cleanup(o, ctx),
        a => Fin.cleaned(X.Ctx.cfg(ctx), api, C.Obj.name(o), p, a))
    case F.FDone{}:
      IO.pure(Q.Action, Q.AwaitChange{})

# Finalizer.run for Kube.control: apply and cleanup get the reconcile
# context (config, caches, failure count). Adding the finalizer changes
# metadata.finalizers, which every predicate passes, so the reconcile that
# follows sees it even under X.PGeneration.
def Finalizer.control(~apply: J.Json -> X.Ctx -> IO(Q.Action),
  ~cleanup: J.Json -> X.Ctx -> IO(Q.Action), +ctx: X.Ctx, +api: C.Api, name: String,
  +o: J.Json) -> IO(Q.Action):
  Fin.ctl.go(~apply, ~cleanup, ctx, api, o, F.Fin.state(o, name))

# Events
# ------

# The note, cut to the API's 1 kB (by UTF-8 bytes; a character cut in two
# becomes U+FFFD).
def Event.note(note: String) -> String:
  U.Utf8.decode_all(List.take(&2, U32, U.Utf8.encode(note), 1024n))

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
  +controller: String, +now: String, id: String, inst: String) -> J.Json:
  J.Json.obj([J.KV{"apiVersion", J.JStr{"events.k8s.io/v1"}}, J.KV{"kind", J.JStr{"Event"}},
    J.KV{"metadata", J.Json.obj([J.KV{"name", J.JStr{C.Obj.name(o) ++ "." ++ id}},
      J.KV{"namespace", J.JStr{Event.ns(C.Obj.namespace(o))}}])},
    J.KV{"eventTime", J.JStr{now}}, J.KV{"reportingController", J.JStr{controller}},
    J.KV{"reportingInstance", J.JStr{inst}}, J.KV{"action", J.JStr{action}},
    J.KV{"reason", J.JStr{reason}}, J.KV{"type", J.JStr{Event.kind(warn)}}, J.KV{"note", J.JStr{Event.note(note)}},
    J.KV{"regarding", Event.regarding(o, r)}])

def Event.sent(r: Result<&2, &2, Cl.KErr, J.Json>) -> IO(Unit):
  match r:
    case Done{e}:
      IO.pure(Unit, Unit{})
    case Fail{e}:
      L.Log.warn("publishing event failed", [L.Log.kv("error", Cl.KErr.show(e))])

# When, a unique suffix, and who reports (the pod: HOSTNAME, else the
# controller's name).
type Stamp is Data:
  Stamp{now: String, id: String, inst: String}

def Event.inst(h: Result<&1, &1, U32 & String, String>, +controller: String) -> String:
  match h:
    case Done{x}:
      x
    case Fail{e}:
      controller

def Event.stamp(+w: T.Wall, inst: String) -> Stamp:
  Stamp{T.Wall.micro(w), T.Wall.id(w), inst}

def Event.post(+cfg: K.Config, +o: J.Json, +r: C.Res, warn: Bool, reason: String, action: String,
  note: String, controller: String, st: Stamp) -> IO(Unit):
  match st:
    case Stamp{now, id, inst}:
      IO.bind(Result<&2, &2, Cl.KErr, J.Json>, Unit,
        Cl.Client.create(cfg, C.Api{C.Res.events(), C.InNs{Event.ns(C.Obj.namespace(o))}},
          Event.body(o, r, warn, reason, action, note, controller, now, id, inst)),
        Event.sent)

# Records an Event about o (of resource r). A failure is logged, never
# raised: events are best effort, as client-go's are.
def Event.publish(+cfg: K.Config, +o: J.Json, +r: C.Res, warn: Bool, reason: String, action: String,
  note: String, +controller: String) -> IO(Unit):
  IO.bind(U32 & (U32 & U32), Unit, Y.Sys.wall(),
    w => IO.bind(Result<&1, &1, U32 & String, String>, Unit, IO.get_env("HOSTNAME"),
      h => Event.post(cfg, o, r, warn, reason, action, note, controller,
        Event.stamp(T.Wall.of(w), Event.inst(h, controller)))))

# Metrics
# -------

def Metrics.send(m: Maybe<&2, Chan(X.Meter)>, x: X.Meter) -> IO(Unit):
  match m:
    case Some{ch}:
      IO.bind(Result<&1, &1, X.Meter, Unit>, Unit, Chan.send(X.Meter, ch, x), u => IO.pure(Unit, Unit{}))
    case None{}:
      IO.pure(Unit, Unit{})

# Adds n to the controller's counter name (labels: the inside of the
# braces, as `kind="x"`, "" for none); /metrics serves it beside
# bend-kube's own.
def Metrics.add(c: X.Ctx, name: String, labels: String, n: U32) -> IO(Unit):
  Metrics.send(X.Ctx.meter(c), X.MAdd{name, labels, n})

# Sets the controller's gauge name.
def Metrics.set(c: X.Ctx, name: String, labels: String, v: U32) -> IO(Unit):
  Metrics.send(X.Ctx.meter(c), X.MSet{name, labels, v})
