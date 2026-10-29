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
# hands the lease back (status 0).

type LOpts is Data:
  LOpts{ns: String, name: String, id: String, dur: U32, deadline: U32, retry: U32}

def LOpts.default(ns: String, name: String, id: String) -> LOpts:
  LOpts{ns, name, id, 15, 10000, 2000}

def LOpts.api(o: LOpts) -> C.Api:
  match o:
    case LOpts{ns, n, i, d, dl, r}:
      C.Api{C.Res.leases(), C.InNs{ns}}

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
  LRead{w: T.Wall, r: Result<&2, &2, Cl.KErr, J.Json>}
  LDecided{now: U32, d: Result<&2, &2, Cl.KErr, E.Decision>}
  LWrote{now: U32, ok: Bool, late: Bool}
  LFail{stop: Bool}

def Leader.wrote(r: Result<&2, &2, Cl.KErr, J.Json>) -> Bool:
  Result.is_done(&2, &2, Cl.KErr, J.Json, r)

def Leader.late(+now: U32, +last: U32, +deadline: U32) -> Bool:
  U32.is_gt((now - last : U32), deadline)

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
def Leader.run(fuel: Nat, ev: LEv, +cfg: K.Config, +o: LOpts, +obs: E.Obs, +leading: Bool,
  +last: U32, start: Maybe<&1, IO(Unit)>) -> IO(Unit):
  match fuel ev:
    case 0n e:
      IO.pure(Unit, Unit{})
    case 1n+f LTry{}:
      IO.bind(U32 & (U32 & U32), Unit, Y.Sys.wall(),
        w => IO.bind(Result<&2, &2, Cl.KErr, J.Json>, Unit,
          Cl.Client.get(cfg, LOpts.api(o), LOpts.name(o)),
          r => Leader.run(f, LRead{T.Wall.of(w), r}, cfg, o, obs, leading, last, start)))
    case 1n+f LRead{+w, r}:
      Leader.run(f, LDecided{T.Wall.ms(w), Leader.decide(Leader.read(r), o, obs, w)}, cfg, o, obs,
        leading, last, start)
    case 1n+f LDecided{+now, Done{E.Decision{E.LCreate{l}, ob}}}:
      IO.bind(Result<&2, &2, Cl.KErr, J.Json>, Unit, Cl.Client.create(cfg, LOpts.api(o), l),
        r => Leader.run(f, LWrote{now, Leader.wrote(r), Leader.late(now, last, LOpts.deadline(o))},
          cfg, o, ob, leading, last, start))
    case 1n+f LDecided{+now, Done{E.Decision{E.LUpdate{l}, ob}}}:
      IO.bind(Result<&2, &2, Cl.KErr, J.Json>, Unit,
        Cl.Client.replace(cfg, LOpts.api(o), LOpts.name(o), l),
        r => Leader.run(f, LWrote{now, Leader.wrote(r), Leader.late(now, last, LOpts.deadline(o))},
          cfg, o, ob, leading, last, start))
    case 1n+f LDecided{+now, Done{E.Decision{E.LWait{}, ob}}}:
      Leader.run(f, LWrote{now, False{}, Leader.late(now, last, LOpts.deadline(o))}, cfg, o, ob,
        leading, last, start)
    case 1n+f LDecided{+now, Fail{e}}:
      IO.bind(Unit, Unit, L.Log.warn("lease read failed", [L.Log.kv("error", Cl.KErr.show(e))]),
        u => Leader.run(f, LWrote{now, False{}, Leader.late(now, last, LOpts.deadline(o))}, cfg, o,
          obs, leading, last, start))
    case 1n+f LWrote{now, True{}, late}:
      IO.bind(Unit, Unit, Leader.started(leading, start),
        u => IO.bind(Unit, Unit, IO.sleep(LOpts.retry(o)),
          u2 => Leader.run(f, LTry{}, cfg, o, obs, True{}, now, None{})))
    case 1n+f LWrote{now, False{}, late}:
      Leader.run(f, LFail{Bool.and(leading, late)}, cfg, o, obs, leading, last, start)
    case 1n+f LFail{True{}}:
      Leader.lost()
    case 1n+f LFail{False{}}:
      IO.bind(Unit, Unit, IO.sleep(LOpts.retry(o)),
        u => Leader.run(f, LTry{}, cfg, o, obs, leading, last, start))

def Leader.release.mine(+cfg: K.Config, +o: LOpts, l: J.Json, mine: Bool) -> IO(Unit):
  match mine:
    case True{}:
      IO.bind(Result<&2, &2, Cl.KErr, J.Json>, Unit,
        Cl.Client.replace(cfg, LOpts.api(o), LOpts.name(o), l),
        r => L.Log.info("released leader lease", Nil{}))
    case False{}:
      IO.pure(Unit, Unit{})

# Hands the lease back if it is ours.
def Leader.release.got(r: Result<&2, &2, Cl.KErr, J.Json>, +cfg: K.Config, +o: LOpts,
  w: T.Wall) -> IO(Unit):
  match r o:
    case Done{+l} LOpts{ns, n, +id, d, dl, rt}:
      Leader.release.mine(cfg, LOpts{ns, n, id, d, dl, rt}, E.Lease.release(l, T.Wall.micro(w)),
        String.eq(E.Lease.holder(l), id))
    case _ _:
      IO.pure(Unit, Unit{})

def Leader.release(+cfg: K.Config, +o: LOpts) -> IO(Unit):
  IO.bind(U32 & (U32 & U32), Unit, Y.Sys.wall(),
    w => IO.bind(Result<&2, &2, Cl.KErr, J.Json>, Unit,
      Cl.Client.get(cfg, LOpts.api(o), LOpts.name(o)), r => Leader.release.got(r, cfg, o, T.Wall.of(w))))

# On SIGTERM or SIGINT: release the lease, then exit 0.
def Leader.on_signal(+cfg: K.Config, +o: LOpts) -> IO(Unit):
  IO.bind(U32, Unit, Y.Sys.signal(),
    sig => IO.bind(Unit, Unit, L.Log.info("terminating", [L.Log.kv("signal", U32.show(sig))]),
      u => IO.bind(Unit, Unit, Leader.release(cfg, o), u2 => IO.exit(0))))

# Runs work only while we hold the lease (client-go's RunOrDie).
def Leader.elect(+cfg: K.Config, +o: LOpts, work: IO(Unit)) -> IO(Unit):
  IO.bind(Unit, Unit, IO.spawn(Unit, Leader.on_signal(cfg, o)),
    u => Leader.run(4294967295n, LTry{}, cfg, o, E.Obs.none(), False{}, 0, Some{work}))
