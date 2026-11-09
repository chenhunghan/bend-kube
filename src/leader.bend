import Base
import ./json.bend as J
import ./core.bend as C
import ./config.bend as K
import ./client.bend as Cl
import ./time.bend as T
import ./sys.bend as Y
import ./log.bend as L
import ./lease.bend as E

# Leader
# ======
#
# client-go's leaderelection loop over lease.bend's decisions, with its
# defaults: a 15s lease, renewed every 2s, given up when no renewal lands
# for 10s. Losing the lease exits the process (status 1), as client-go's
# usual OnStoppedLeading does, so two leaders never act at once; SIGTERM
# drains the running reconciles and hands the lease back (status 0).

type LOpts is Data:
  LOpts{ns: String, name: String, id: String, dur: U32, deadline: U32, retry: U32}

def LOpts.default(ns: String, name: String, id: String) -> LOpts:
  LOpts{ns, name, id, 15, 10000, 2000}

def LOpts.api(o: LOpts) -> C.Api:
  match o:
    case LOpts{ns, n, i, d, dl, r}:
      C.Api{C.Res.leases(), C.InNs{ns}}

def LOpts.id(o: LOpts) -> String:
  match o:
    case LOpts{ns, n, i, d, dl, r}:
      i

def LOpts.name(o: LOpts) -> String:
  match o:
    case LOpts{ns, n, i, d, dl, r}:
      n

def LOpts.retry(o: LOpts) -> U32:
  match o:
    case LOpts{ns, n, i, d, dl, r}:
      r

def LOpts.deadline(o: LOpts) -> U32:
  match o:
    case LOpts{ns, n, i, d, dl, r}:
      dl

def Leader.read.err(e: Cl.KErr, missing: Bool) -> Result<&2, &2, Cl.KErr, Maybe<&2, J.Json>>:
  match missing:
    case True{}:
      Done{None{}}
    case False{}:
      Fail{e}

# The Lease read: Some, None on 404, or the error.
def Leader.read(r: Result<&2, &2, Cl.KErr, J.Json>) -> Result<&2, &2, Cl.KErr, Maybe<&2, J.Json>>:
  match r:
    case Done{l}:
      Done{Some{l}}
    case Fail{+e}:
      Leader.read.err(e, U32.is_eq(Cl.KErr.code(e), 404))

def Leader.decide(r: Result<&2, &2, Cl.KErr, Maybe<&2, J.Json>>, +o: LOpts, +obs: E.Obs, +mono: U32,
  +w: T.Wall) -> Result<&2, &2, Cl.KErr, E.Decision>:
  match r o:
    case Done{cur} LOpts{ns, n, id, d, dl, rt}:
      Done{E.Lease.decide(cur, ns, n, id, obs, mono, d, T.Wall.micro(w))}
    case Fail{e} _:
      Fail{e}

# What the loop just saw.
type LEv is Type:
  LTry{}
  LAt{w: T.Wall, mono: U32}
  LRead{w: T.Wall, mono: U32, r: Result<&2, &2, Cl.KErr, J.Json>}
  LDecided{now: U32, d: Result<&2, &2, Cl.KErr, E.Decision>}
  LCheck{now: U32, ok: Bool}
  LWrote{now: U32, ok: Bool, late: Bool}
  LFail{stop: Bool}

def Leader.wrote(r: Result<&2, &2, Cl.KErr, J.Json>) -> Bool:
  Result.is_done(&2, &2, Cl.KErr, J.Json, r)

def Leader.timed.of(m: Maybe<&1, Result<&2, &2, Cl.KErr, J.Json>>) -> Result<&2, &2, Cl.KErr, J.Json>:
  match m:
    case Some{r}:
      r
    case None{}:
      Fail{Cl.KNet{0, "lease call timed out"}}

# A lease call that takes longer than ms fails.
def Leader.timed(+ms: U32, act: IO(Result<&2, &2, Cl.KErr, J.Json>)) -> IO(Result<&2, &2, Cl.KErr, J.Json>):
  IO.bind(Maybe<&1, Result<&2, &2, Cl.KErr, J.Json>>, Result<&2, &2, Cl.KErr, J.Json>,
    IO.within(Result<&2, &2, Cl.KErr, J.Json>, ms, act),
    m => IO.pure(Result<&2, &2, Cl.KErr, J.Json>, Leader.timed.of(m)))

# The monotonic clock in ms (time since boot, never stepped): every timing
# decision (expiry, the renew deadline, lateness) uses it; the wall clock
# only stamps the Lease.
def Leader.mono() -> IO(U32):
  IO.bind(Nat, U32, IO.now(), n => IO.pure(U32, U32.from_nat(n)))

# On first acquiring: log and start the work.
def Leader.started(leading: Bool, start: Maybe<&1, IO(Unit)>) -> IO(Unit):
  match leading start:
    case False{} Some{act}:
      IO.bind(Unit, Unit, L.Log.info("became leader", Nil{}), u => IO.spawn(Unit, act))
    case _ _:
      IO.pure(Unit, Unit{})

# A leader that cannot renew within the deadline stops at once (a
# candidate that fails just tries again).
def Leader.lost() -> IO(Unit):
  IO.bind(Unit, Unit, L.Log.error("leader lease lost; exiting", Nil{}), u => IO.exit(1))

# A leader's renewal that landed only after the renew deadline counts as
# lost (client-go's RenewDeadline): a standby may already have judged the
# lease expired.
def Leader.renewed(late: Bool, go: IO(Unit)) -> IO(Unit):
  match late:
    case True{}:
      Leader.lost()
    case False{}:
      go

# The election loop. start runs once, when the lease is first ours.
def Leader.run(outer: Nat, fuel: Nat, ev: LEv, +cfg: K.Config, +o: LOpts, +obs: E.Obs, +leading: Bool,
  +last: U32, start: Maybe<&1, IO(Unit)>) -> IO(Unit):
  match outer fuel ev:
    case 0n 0n e:
      IO.bind(Unit, Unit, L.Log.error("leader election out of steps; exiting", Nil{}), u => IO.exit(1))
    case 1n+oc 0n e:
      Leader.run(oc, 4294967295n, e, cfg, o, obs, leading, last, start)
    case oc 1n+f LTry{}:
      IO.bind(U32 & (U32 & U32), Unit, Y.Sys.wall(),
        w => IO.bind(U32, Unit, Leader.mono(),
          m => Leader.run(oc, f, LAt{T.Wall.of(w), m}, cfg, o, obs, leading, last, start)))
    case oc 1n+f LAt{+w, +m}:
      # a leader past its renew deadline stops before trying again
      Leader.renewed(Bool.and(leading, E.Lease.late(m, last, LOpts.deadline(o))),
        IO.bind(Result<&2, &2, Cl.KErr, J.Json>, Unit,
          Leader.timed(E.Lease.room(m, last, LOpts.deadline(o), leading),
            Cl.Client.get(cfg, LOpts.api(o), LOpts.name(o))),
          r => IO.bind(U32, Unit, Leader.mono(),
            m2 => Leader.run(oc, f, LRead{w, m2, r}, cfg, o, obs, leading, last, start))))
    case oc 1n+f LRead{+w, +m, r}:
      Leader.run(oc, f, LDecided{m, Leader.decide(Leader.read(r), o, obs, m, w)}, cfg, o, obs,
        leading, last, start)
    case oc 1n+f LDecided{+now, Done{E.Decision{E.LCreate{l}, ob}}}:
      IO.bind(U32, Unit, Leader.mono(),
        +m1 => Leader.renewed(Bool.and(leading, E.Lease.late(m1, last, LOpts.deadline(o))),
          IO.bind(Result<&2, &2, Cl.KErr, J.Json>, Unit,
            Leader.timed(E.Lease.room(m1, last, LOpts.deadline(o), leading),
              Cl.Client.create(cfg, LOpts.api(o), l)),
            r => Leader.run(oc, f, LCheck{now, Leader.wrote(r)}, cfg, o, ob, leading, last, start))))
    case oc 1n+f LDecided{+now, Done{E.Decision{E.LUpdate{l}, ob}}}:
      IO.bind(U32, Unit, Leader.mono(),
        +m1 => Leader.renewed(Bool.and(leading, E.Lease.late(m1, last, LOpts.deadline(o))),
          IO.bind(Result<&2, &2, Cl.KErr, J.Json>, Unit,
            Leader.timed(E.Lease.room(m1, last, LOpts.deadline(o), leading),
              Cl.Client.replace(cfg, LOpts.api(o), LOpts.name(o), l)),
            r => Leader.run(oc, f, LCheck{now, Leader.wrote(r)}, cfg, o, ob, leading, last, start))))
    case oc 1n+f LDecided{+now, Done{E.Decision{E.LWait{}, ob}}}:
      Leader.run(oc, f, LCheck{now, False{}}, cfg, o, ob, leading, last, start)
    case oc 1n+f LDecided{+now, Fail{e}}:
      IO.bind(Unit, Unit, L.Log.warn("lease read failed", [L.Log.kv("error", Cl.KErr.show(e))]),
        u => Leader.run(oc, f, LCheck{now, False{}}, cfg, o, obs, leading, last, start))
    case oc 1n+f LCheck{+now, ok}:
      # lateness by the clock after the calls, not before them
      IO.bind(U32, Unit, Leader.mono(),
        +m2 => Leader.run(oc, f, LWrote{now, ok, E.Lease.overdue(m2, last, now, LOpts.deadline(o), leading)},
          cfg, o, obs, leading, last, start))
    case oc 1n+f LWrote{+now, True{}, late}:
      # a write that landed too late (a slow acquisition or renewal) stops
      # the process rather than starting or continuing work
      Leader.renewed(late,
        IO.bind(Unit, Unit, Leader.started(leading, start),
          u => IO.bind(U32, Unit, Leader.mono(),
            m3 => IO.bind(Unit, Unit,
              IO.sleep(E.Lease.nap(m3, now, LOpts.deadline(o), LOpts.retry(o), True{})),
              u2 => Leader.run(oc, f, LTry{}, cfg, o, obs, True{}, now, None{})))))
    case oc 1n+f LWrote{now, False{}, late}:
      Leader.run(oc, f, LFail{Bool.and(leading, late)}, cfg, o, obs, leading, last, start)
    case oc 1n+f LFail{True{}}:
      Leader.lost()
    case oc 1n+f LFail{False{}}:
      IO.bind(U32, Unit, Leader.mono(),
        m => IO.bind(Unit, Unit, IO.sleep(E.Lease.nap(m, last, LOpts.deadline(o), LOpts.retry(o), leading)),
          u => Leader.run(oc, f, LTry{}, cfg, o, obs, leading, last, start)))

def Leader.release.said(r: Result<&2, &2, Cl.KErr, J.Json>) -> IO(Bool):
  match r:
    case Done{x}:
      IO.bind(Unit, Bool, L.Log.info("released leader lease", Nil{}), u => IO.pure(Bool, True{}))
    case Fail{+e}:
      IO.bind(Unit, Bool, L.Log.warn("lease release failed", [L.Log.kv("error", Cl.KErr.show(e))]),
        u => IO.pure(Bool, False{}))

def Leader.release.mine(+cfg: K.Config, +o: LOpts, l: J.Json, mine: Bool) -> IO(Bool):
  match mine:
    case True{}:
      IO.bind(Result<&2, &2, Cl.KErr, J.Json>, Bool,
        Cl.Client.replace(cfg, LOpts.api(o), LOpts.name(o), l), Leader.release.said)
    case False{}:
      IO.pure(Bool, True{})

# Hands the lease back if it is ours; answers whether there is nothing
# left to do.
def Leader.release.got(r: Result<&2, &2, Cl.KErr, J.Json>, +cfg: K.Config, +o: LOpts,
  w: T.Wall) -> IO(Bool):
  match r o:
    case Done{+l} LOpts{ns, n, +id, d, dl, rt}:
      Leader.release.mine(cfg, LOpts{ns, n, id, d, dl, rt}, E.Lease.release(l, T.Wall.micro(w)),
        String.eq(E.Lease.holder(l), id))
    case Fail{+e} x:
      # the read failed: try again
      IO.bind(Unit, Bool, L.Log.warn("lease release read failed", [L.Log.kv("error", Cl.KErr.show(e))]),
        u => IO.pure(Bool, False{}))

def Leader.release.once(+cfg: K.Config, +o: LOpts) -> IO(Bool):
  IO.bind(U32 & (U32 & U32), Bool, Y.Sys.wall(),
    w => IO.bind(Result<&2, &2, Cl.KErr, J.Json>, Bool,
      Cl.Client.get(cfg, LOpts.api(o), LOpts.name(o)), r => Leader.release.got(r, cfg, o, T.Wall.of(w))))

def Leader.release.again(n: Nat, +cfg: K.Config, +o: LOpts, done: Bool) -> IO(Unit):
  match n done:
    case 1n+k False{}:
      IO.bind(Bool, Unit, Leader.release.once(cfg, o), d => Leader.release.again(k, cfg, o, d))
    case _ _:
      IO.pure(Unit, Unit{})

def Leader.release.timed(m: Maybe<&1, Unit>) -> IO(Unit):
  match m:
    case Some{u}:
      IO.pure(Unit, Unit{})
    case None{}:
      L.Log.warn("lease release timed out; the standby takes over when it expires", Nil{})

# Hands the lease back, reading it afresh and trying again if a renewal
# raced the write (a 409), up to three times, within 4s in all.
def Leader.release(+cfg: K.Config, +o: LOpts) -> IO(Unit):
  IO.bind(Maybe<&1, Unit>, Unit, IO.within(Unit, 4000, Leader.release.again(3n, cfg, o, False{})),
    Leader.release.timed)

# A second SIGTERM or SIGINT while draining exits at once.
def Leader.again() -> IO(Unit):
  IO.bind(U32, Unit, Y.Sys.signal(),
    sig => IO.bind(Unit, Unit, L.Log.warn("second signal; exiting now", Nil{}), u => IO.exit(1)))

# The lease goes back only after a clean drain. A reconcile still running
# past the grace period could otherwise overlap the next leader's; the
# process exits holding the lease, which expires after its duration.
def Leader.handover(+cfg: K.Config, +o: LOpts, drained: Bool) -> IO(Unit):
  match drained:
    case True{}:
      IO.bind(Unit, Unit, Leader.release(cfg, o), u => IO.exit(0))
    case False{}:
      IO.exit(0)

# On SIGTERM or SIGINT: drain (stop starting reconciles and wait for the
# running ones, up to the grace period), hand the lease back if nothing is
# left running, then exit 0; a second signal exits at once.
def Leader.on_signal(+cfg: K.Config, +o: LOpts, drain: IO(Bool)) -> IO(Unit):
  IO.bind(U32, Unit, Y.Sys.signal(),
    sig => IO.bind(Unit, Unit, L.Log.info("terminating", [L.Log.kv("signal", U32.show(sig))]),
      u => IO.bind(Unit, Unit, IO.spawn(Unit, Leader.again()),
        u0 => IO.bind(Bool, Unit, drain, d => Leader.handover(cfg, o, d)))))

# Runs work only while we hold the lease (client-go's RunOrDie); drain runs
# on SIGTERM before the lease is handed back.
def Leader.elect.go(+cfg: K.Config, +o: LOpts, drain: IO(Bool), work: IO(Unit)) -> IO(Unit):
  IO.bind(Unit, Unit, IO.spawn(Unit, Leader.on_signal(cfg, o, drain)),
    u => Leader.run(4294967295n, 4294967295n, LTry{}, cfg, o, E.Obs.none(), False{}, 0, Some{work}))

def LOpts.check(o: LOpts) -> Maybe<&2, String>:
  match o:
    case LOpts{ns, n, i, +d, +dl, +r}:
      E.Lease.timing(d, dl, r)

def Leader.elect.ok(+cfg: K.Config, +o: LOpts, drain: IO(Bool), work: IO(Unit), bad: Maybe<&2, String>) ->
  IO(Unit):
  match bad:
    case Some{e}:
      IO.die(Unit, 1, "bend-kube: " ++ e)
    case None{}:
      Leader.elect.go(cfg, o, drain, work)

# Runs work only while we hold the lease (client-go's RunOrDie), after
# checking the timing is safe (Lease.timing); drain runs on SIGTERM before
# the lease is handed back.
def Leader.elect(+cfg: K.Config, +o: LOpts, drain: IO(Bool), work: IO(Unit)) -> IO(Unit):
  Leader.elect.ok(cfg, o, drain, work, LOpts.check(o))
