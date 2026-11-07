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

def Leader.decide(r: Result<&2, &2, Cl.KErr, Maybe<&2, J.Json>>, +o: LOpts, +obs: E.Obs,
  +w: T.Wall) -> Result<&2, &2, Cl.KErr, E.Decision>:
  match r o:
    case Done{cur} LOpts{ns, n, id, d, dl, rt}:
      Done{E.Lease.decide(cur, ns, n, id, obs, T.Wall.ms(w), d, T.Wall.micro(w))}
    case Fail{e} _:
      Fail{e}

# What the loop just saw.
type LEv is Type:
  LTry{}
  LAt{w: T.Wall}
  LRead{w: T.Wall, r: Result<&2, &2, Cl.KErr, J.Json>}
  LDecided{now: U32, d: Result<&2, &2, Cl.KErr, E.Decision>}
  LCheck{now: U32, ok: Bool}
  LWrote{now: U32, ok: Bool, late: Bool}
  LFail{stop: Bool}

def Leader.wrote(r: Result<&2, &2, Cl.KErr, J.Json>) -> Bool:
  Result.is_done(&2, &2, Cl.KErr, J.Json, r)

def Leader.late(+now: U32, +last: U32, +deadline: U32) -> Bool:
  U32.is_gt((now - last : U32), deadline)

def Leader.room.left(+deadline: U32, +spent: U32, left: Bool) -> U32:
  match left:
    case True{}:
      (deadline - spent : U32)
    case False{}:
      1

def Leader.room.go(+deadline: U32, +spent: U32) -> U32:
  Leader.room.left(deadline, spent, U32.is_lt(spent, deadline))

# How long a lease call may take: while leading, what is left of the renew
# deadline since the last renewal (at least 1ms); else the whole deadline.
def Leader.room(+now: U32, +last: U32, +deadline: U32, leading: Bool) -> U32:
  match leading:
    case True{}:
      Leader.room.go(deadline, (now - last : U32))
    case False{}:
      deadline

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

def Leader.ms(w: U32 & (U32 & U32)) -> U32:
  T.Wall.ms(T.Wall.of(w))

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
        w => Leader.run(oc, f, LAt{T.Wall.of(w)}, cfg, o, obs, leading, last, start))
    case oc 1n+f LAt{+w}:
      IO.bind(Result<&2, &2, Cl.KErr, J.Json>, Unit,
        Leader.timed(Leader.room(T.Wall.ms(w), last, LOpts.deadline(o), leading),
          Cl.Client.get(cfg, LOpts.api(o), LOpts.name(o))),
        r => Leader.run(oc, f, LRead{w, r}, cfg, o, obs, leading, last, start))
    case oc 1n+f LRead{+w, r}:
      Leader.run(oc, f, LDecided{T.Wall.ms(w), Leader.decide(Leader.read(r), o, obs, w)}, cfg, o, obs,
        leading, last, start)
    case oc 1n+f LDecided{+now, Done{E.Decision{E.LCreate{l}, ob}}}:
      IO.bind(U32 & (U32 & U32), Unit, Y.Sys.wall(),
        w1 => IO.bind(Result<&2, &2, Cl.KErr, J.Json>, Unit,
          Leader.timed(Leader.room(Leader.ms(w1), last, LOpts.deadline(o), leading),
            Cl.Client.create(cfg, LOpts.api(o), l)),
          r => Leader.run(oc, f, LCheck{now, Leader.wrote(r)}, cfg, o, ob, leading, last, start)))
    case oc 1n+f LDecided{+now, Done{E.Decision{E.LUpdate{l}, ob}}}:
      IO.bind(U32 & (U32 & U32), Unit, Y.Sys.wall(),
        w1 => IO.bind(Result<&2, &2, Cl.KErr, J.Json>, Unit,
          Leader.timed(Leader.room(Leader.ms(w1), last, LOpts.deadline(o), leading),
            Cl.Client.replace(cfg, LOpts.api(o), LOpts.name(o), l)),
          r => Leader.run(oc, f, LCheck{now, Leader.wrote(r)}, cfg, o, ob, leading, last, start)))
    case oc 1n+f LDecided{+now, Done{E.Decision{E.LWait{}, ob}}}:
      Leader.run(oc, f, LCheck{now, False{}}, cfg, o, ob, leading, last, start)
    case oc 1n+f LDecided{+now, Fail{e}}:
      IO.bind(Unit, Unit, L.Log.warn("lease read failed", [L.Log.kv("error", Cl.KErr.show(e))]),
        u => Leader.run(oc, f, LCheck{now, False{}}, cfg, o, obs, leading, last, start))
    case oc 1n+f LCheck{+now, ok}:
      # lateness by the clock after the calls, not before them
      IO.bind(U32 & (U32 & U32), Unit, Y.Sys.wall(),
        w2 => Leader.run(oc, f, LWrote{now, ok, Leader.late(Leader.ms(w2), last, LOpts.deadline(o))},
          cfg, o, obs, leading, last, start))
    case oc 1n+f LWrote{now, True{}, late}:
      IO.bind(Unit, Unit, Leader.started(leading, start),
        u => IO.bind(Unit, Unit, IO.sleep(LOpts.retry(o)),
          u2 => Leader.run(oc, f, LTry{}, cfg, o, obs, True{}, now, None{})))
    case oc 1n+f LWrote{now, False{}, late}:
      Leader.run(oc, f, LFail{Bool.and(leading, late)}, cfg, o, obs, leading, last, start)
    case oc 1n+f LFail{True{}}:
      Leader.lost()
    case oc 1n+f LFail{False{}}:
      IO.bind(Unit, Unit, IO.sleep(LOpts.retry(o)),
        u => Leader.run(oc, f, LTry{}, cfg, o, obs, leading, last, start))

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

# On SIGTERM or SIGINT: drain (stop starting reconciles and wait for the
# running ones, up to the grace period), release the lease, then exit 0.
def Leader.on_signal(+cfg: K.Config, +o: LOpts, drain: IO(Unit)) -> IO(Unit):
  IO.bind(U32, Unit, Y.Sys.signal(),
    sig => IO.bind(Unit, Unit, L.Log.info("terminating", [L.Log.kv("signal", U32.show(sig))]),
      u => IO.bind(Unit, Unit, IO.spawn(Unit, Leader.again()), u0 => IO.bind(Unit, Unit, drain,
        u1 => IO.bind(Unit, Unit, Leader.release(cfg, o), u2 => IO.exit(0))))))

# Runs work only while we hold the lease (client-go's RunOrDie); drain runs
# on SIGTERM before the lease is handed back.
def Leader.elect(+cfg: K.Config, +o: LOpts, drain: IO(Unit), work: IO(Unit)) -> IO(Unit):
  IO.bind(Unit, Unit, IO.spawn(Unit, Leader.on_signal(cfg, o, drain)),
    u => Leader.run(4294967295n, 4294967295n, LTry{}, cfg, o, E.Obs.none(), False{}, 0, Some{work}))
