import Base
import ./json.bend as J
import ./core.bend as C

# Lease
# =====
#
# Leader election over a coordination.k8s.io/v1 Lease, deciding as
# client-go's LeaderElector.tryAcquireOrRenew does:
#
# - No Lease: create one naming us.
# - A Lease held by someone else whose record we saw change less than
#   leaseDuration ago (by our own clock: remote timestamps are never
#   compared, so clock skew cannot steal a lease): wait.
# - Otherwise (ours, unheld, or expired): write it naming us, through the
#   resourceVersion the read returned, so of two contenders only one
#   write lands (optimistic concurrency).
#
# Taking a lease from another holder counts a transition and resets
# acquireTime; renewing our own keeps both.

# What we last saw of the record, and when (our clock, in ms).
type Obs is Data:
  Obs{holder: String, renew: String, at: U32}

type LeaseAct is Data:
  LCreate{lease: J.Json}
  LUpdate{lease: J.Json}
  LWait{}

type Decision is Data:
  Decision{act: LeaseAct, obs: Obs}

def Obs.none() -> Obs:
  Obs{"", "", 0}

def Lease.spec(+l: J.Json, field: String) -> J.Json:
  J.Json.get(J.Json.get(l, "spec"), field)

def Lease.holder(+l: J.Json) -> String:
  J.Json.str_or(Lease.spec(l, "holderIdentity"), "")

def Lease.renew_time(+l: J.Json) -> String:
  J.Json.str_or(Lease.spec(l, "renewTime"), "")

def Lease.transitions(+l: J.Json) -> U32:
  Maybe.default(&2, U32, J.Json.as_u32(Lease.spec(l, "leaseTransitions")), 0)

def Lease.new_spec(id: String, +dur: U32, acquire: String, renew: String, +trans: U32) -> J.Json:
  J.Json.obj([J.KV{"holderIdentity", J.JStr{id}}, J.KV{"leaseDurationSeconds", J.Json.u32(dur)},
    J.KV{"acquireTime", J.JStr{acquire}}, J.KV{"renewTime", J.JStr{renew}},
    J.KV{"leaseTransitions", J.Json.u32(trans)}])

# A fresh Lease naming us.
def Lease.fresh(ns: String, name: String, id: String, +dur: U32, +now: String) -> J.Json:
  J.Json.obj([J.KV{"apiVersion", J.JStr{"coordination.k8s.io/v1"}}, J.KV{"kind", J.JStr{"Lease"}},
    J.KV{"metadata", J.Json.obj([J.KV{"name", J.JStr{name}}, J.KV{"namespace", J.JStr{ns}}])},
    J.KV{"spec", Lease.new_spec(id, dur, now, now, 0)}])

def Lease.observe.go(h: String, r: String, o: Obs, +now: U32, same: Bool) -> Obs:
  match same:
    case True{}:
      o
    case False{}:
      Obs{h, r, now}

# The record seen now: the old observation if nothing changed, else a new
# one stamped now.
def Lease.observe(+l: J.Json, o: Obs, +now: U32) -> Obs:
  match o:
    case Obs{+h, +r, at}:
      Lease.observe.go(Lease.holder(l), Lease.renew_time(l), Obs{h, r, at}, now,
        Bool.and(String.eq(h, Lease.holder(l)), String.eq(r, Lease.renew_time(l))))

# Whether another holder's lease is still live by our clock.
def Lease.held(+l: J.Json, +me: String, o: Obs, +now: U32, +dur: U32) -> Bool:
  match o:
    case Obs{h, r, +at}:
      Bool.and(Bool.not(String.is_empty(Lease.holder(l))),
        Bool.and(Bool.not(String.eq(Lease.holder(l), me)),
          U32.is_lt((now - at : U32), (dur * 1000 : U32))))

def Lease.take.go(+l: J.Json, me: String, +dur: U32, +now: String, ours: Bool) -> J.Json:
  match ours:
    case True{}:
      J.Json.set(l, "spec", Lease.new_spec(me, dur,
        J.Json.str_or(Lease.spec(l, "acquireTime"), now), now, Lease.transitions(l)))
    case False{}:
      J.Json.set(l, "spec", Lease.new_spec(me, dur, now, now, (Lease.transitions(l) + 1 : U32)))

# The Lease rewritten to name us, keeping its metadata (resourceVersion).
def Lease.take(+l: J.Json, +me: String, +dur: U32, +now: String) -> J.Json:
  Lease.take.go(l, me, dur, now, String.eq(Lease.holder(l), me))

def Lease.decide.fin(+l: J.Json, +me: String, o: Obs, +dur: U32, +now: String, held: Bool) ->
  Decision:
  match held:
    case True{}:
      Decision{LWait{}, o}
    case False{}:
      Decision{LUpdate{Lease.take(l, me, dur, now)}, o}

def Lease.decide.held(+l: J.Json, +me: String, +o: Obs, +now_ms: U32, +dur: U32, +now: String) ->
  Decision:
  Lease.decide.fin(l, me, o, dur, now, Lease.held(l, me, o, now_ms, dur))

def Lease.decide.got(+l: J.Json, +me: String, o: Obs, +now_ms: U32, +dur: U32, +now: String) ->
  Decision:
  Lease.decide.held(l, me, Lease.observe(l, o, now_ms), now_ms, dur, now)

# One round: the Lease read (None when absent), us, what we saw before,
# our clock in ms, the lease duration in seconds, and the time to stamp.
def Lease.decide(cur: Maybe<&2, J.Json>, ns: String, name: String, +me: String, o: Obs,
  +now_ms: U32, +dur: U32, +now: String) -> Decision:
  match cur:
    case None{}:
      Decision{LCreate{Lease.fresh(ns, name, me, dur, now)}, Obs{me, now, now_ms}}
    case Some{+l}:
      Lease.decide.got(l, me, o, now_ms, dur, now)

# The Lease handed back: no holder, a one-second duration, so the next
# candidate takes it at once (client-go's ReleaseOnCancel).
def Lease.release(+l: J.Json, +now: String) -> J.Json:
  J.Json.set(l, "spec", Lease.new_spec("", 1, now, now, Lease.transitions(l)))
