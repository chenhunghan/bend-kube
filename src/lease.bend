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
#   compared, so clock skew cannot steal a lease; our clock stepping back
#   counts as no time passing, so a step cannot either): wait.
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

def Lease.elapsed.go(+d: U32, back: Bool) -> U32:
  match back:
    case True{}:
      0
    case False{}:
      d

# Time since an observation, by our clock: a clock that stepped back (now
# before at, by the wrapped difference) counts as no time at all, so a
# clock step can never make a live lease look expired.
def Lease.elapsed(+now: U32, +at: U32) -> U32:
  Lease.elapsed.go((now - at : U32), U32.is_ge((now - at : U32), 2147483648))

def Lease.observe.same(o: Obs, +now: U32, back: Bool) -> Obs:
  match o back:
    case Obs{h, r, at} True{}:
      # the clock stepped back: count from now
      Obs{h, r, now}
    case x False{}:
      x

def Obs.at(o: Obs) -> U32:
  match o:
    case Obs{h, r, at}:
      at

def Lease.observe.go(h: String, r: String, +o: Obs, +now: U32, same: Bool) -> Obs:
  match same:
    case True{}:
      Lease.observe.same(o, now, U32.is_ge((now - Obs.at(o) : U32), 2147483648))
    case False{}:
      Obs{h, r, now}

# The record seen now: the old observation if nothing changed, else a new
# one stamped now.
def Lease.observe(+l: J.Json, o: Obs, +now: U32) -> Obs:
  match o:
    case Obs{+h, +r, at}:
      Lease.observe.go(Lease.holder(l), Lease.renew_time(l), Obs{h, r, at}, now,
        Bool.and(String.eq(h, Lease.holder(l)), String.eq(r, Lease.renew_time(l))))

def Lease.duration.pos(+d: U32, +dur: U32, zero: Bool) -> U32:
  match zero:
    case True{}:
      dur
    case False{}:
      d

def Lease.duration.go(m: Maybe<&2, U32>, +dur: U32) -> U32:
  match m:
    case Some{+d}:
      Lease.duration.pos(d, dur, U32.is_eq(d, 0))
    case None{}:
      dur

# The holder's own lease duration (spec.leaseDurationSeconds), so a
# contender configured shorter cannot expire a holder early; ours when the
# Lease does not say.
def Lease.duration(+l: J.Json, +dur: U32) -> U32:
  Lease.duration.go(J.Json.as_u32(Lease.spec(l, "leaseDurationSeconds")), dur)

# Whether another holder's lease is still live by our clock.
def Lease.held(+l: J.Json, +me: String, o: Obs, +now: U32, +dur: U32) -> Bool:
  match o:
    case Obs{h, r, +at}:
      Bool.and(Bool.not(String.is_empty(Lease.holder(l))),
        Bool.and(Bool.not(String.eq(Lease.holder(l), me)),
          U32.is_lt(Lease.elapsed(now, at), (Lease.duration(l, dur) * 1000 : U32))))

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

def Lease.timing.go(zero: Bool, short: Bool, tight: Bool) -> Maybe<&2, String>:
  match zero short tight:
    case True{} s t:
      Some{"leader election: lease duration, renew deadline and retry period must all be above zero"}
    case False{} True{} t:
      Some{"leader election: the lease duration must be longer than the renew deadline"}
    case False{} False{} True{}:
      Some{"leader election: the renew deadline must be longer than 1.2 retry periods"}
    case False{} False{} False{}:
      None{}

# Settings over a day are refused before any arithmetic, which then cannot
# overflow.
def Lease.timing.big(+dur: U32, +deadline: U32, +retry: U32, big: Bool) -> Maybe<&2, String>:
  match big:
    case True{}:
      Some{"leader election: lease duration, renew deadline and retry period must each be at most a day"}
    case False{}:
      Lease.timing.go(Bool.or(Bool.or(U32.is_eq(dur, 0), U32.is_eq(deadline, 0)), U32.is_eq(retry, 0)),
        U32.is_le((dur * 1000 : U32), deadline), U32.is_le((deadline * 10 : U32), (retry * 12 : U32)))

# Election timing that keeps two leaders from acting at once, as
# client-go's NewLeaderElector checks it: every setting above zero, the
# lease (dur, seconds) longer than the renew deadline (ms), and the
# deadline longer than 1.2 retry periods (ms). The fault, if any.
def Lease.timing(+dur: U32, +deadline: U32, +retry: U32) -> Maybe<&2, String>:
  Lease.timing.big(dur, deadline, retry,
    Bool.or(Bool.or(U32.is_gt(dur, 86400), U32.is_gt(deadline, 86400000)), U32.is_gt(retry, 86400000)))

def Lease.room.left(+deadline: U32, +spent: U32, left: Bool) -> U32:
  match left:
    case True{}:
      (deadline - spent : U32)
    case False{}:
      1

def Lease.room.go(+deadline: U32, +spent: U32) -> U32:
  Lease.room.left(deadline, spent, U32.is_lt(spent, deadline))

# How long a lease call may take: while leading, what is left of the renew
# deadline since the last renewal (at least 1ms); else the whole deadline.

def Lease.room(+now: U32, +last: U32, +deadline: U32, leading: Bool) -> U32:
  match leading:
    case True{}:
      Lease.room.go(deadline, (now - last : U32))
    case False{}:
      deadline

# Renewal timing (the leader loop, leader.bend)
# ----------------------------------------------

# How long to wait before the next try: the retry period, but for a
# leader never past its renew deadline, so it notices the deadline in time
# (the loop checks it before every request).
def Lease.nap(+now: U32, +last: U32, +deadline: U32, +retry: U32, leading: Bool) -> U32:
  match leading:
    case True{}:
      U32.min(retry, Lease.room(now, last, deadline, True{}))
    case False{}:
      retry

# Whether the renew deadline has passed since the last renewal (reaching it
# counts: a standby may act from then on).
def Lease.late(+now: U32, +last: U32, +deadline: U32) -> Bool:
  U32.is_ge((now - last : U32), deadline)

# Whether a write that just succeeded came too late to act on: a leader
# counts from its last renewal (last), a candidate from the start of the
# attempt that won (attempt). Past the renew deadline, a standby may
# already judge the lease expired, so the writer must stop, not start.
def Lease.overdue(+now: U32, +last: U32, +attempt: U32, +deadline: U32, leading: Bool) -> Bool:
  match leading:
    case True{}:
      Lease.late(now, last, deadline)
    case False{}:
      Lease.late(now, attempt, deadline)
