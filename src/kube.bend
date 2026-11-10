import Base
import ./json.bend as J
import ./core.bend as C
import ./config.bend as K
import ./client.bend as Cl
import ./queue.bend as Q
import ./control.bend as X
import ./runtime.bend as R
import ./serve.bend as V
import ./leader.bend as E
import ./sys.bend as Y
import ./log.bend as L

# Kube
# ====
#
# The entry point a controller binary calls (the kube crate's facade):
# infer the config, rate-limit the client, serve health and metrics, elect
# a leader when asked, run the controllers, and on SIGTERM drain the
# running reconciles before exiting.
#
# Kube.control runs one controller from a spec (X.Spec: predicates,
# related watches), reconciling with rec(obj, ctx); Kube.control_all runs
# several sharing their watches. Kube.run and Kube.run_all are the older
# forms, whose reconcile gets only the config.

# max: reconciles at once and label: the primary's label selector, both
# for Kube.run only (a spec carries its own); port: health and metrics (0:
# off); leader: the Lease to hold while running; grace: how long SIGTERM
# waits for running reconciles, in ms; qps and burst: the client's rate
# limit (qps 0: none); timeout: the reconcile timeout of every spec
# that sets none (X.Spec.timeout), in ms (0: none).
type Opts is Data:
  Opts{max: U32, port: U32, leader: Maybe<&2, E.LOpts>, label: String, grace: U32, qps: U32,
    burst: U32, timeout: U32}

# 8 reconciles at once, health and metrics on :8080, no leader election, a
# 20s grace period (with up to 4s to hand the lease back, inside
# Kubernetes' default 30s), 50 requests a second with bursts of 100, and
# no reconcile timeout.
def Opts.default() -> Opts:
  Opts{8, 8080, None{}, "", 20000, 50, 100, 0}

def Opts.with_leader(o: Opts, ns: String, name: String, id: String) -> Opts:
  match o:
    case Opts{m, p, l, s, g, q, b, t}:
      Opts{m, p, Some{E.LOpts.default(ns, name, id)}, s, g, q, b, t}

# Leader election under a Lease in ns named name, identified as this
# replica: its HOSTNAME (the pod name) and a random suffix, so two replicas
# never share an identity. Prefer this to with_leader.
def Opts.with_election(o: Opts, ns: String, name: String) -> Opts:
  Opts.with_leader(o, ns, name, "")

# Leader election with every setting given (E.LOpts: namespace, name,
# identity, lease seconds, renew deadline ms, retry ms).
def Opts.with_lease(o: Opts, lo: E.LOpts) -> Opts:
  match o:
    case Opts{m, p, l, s, g, q, b, t}:
      Opts{m, p, Some{lo}, s, g, q, b, t}

def Opts.with_label(o: Opts, label: String) -> Opts:
  match o:
    case Opts{m, p, l, s, g, q, b, t}:
      Opts{m, p, l, label, g, q, b, t}

def Opts.with_max(o: Opts, max: U32) -> Opts:
  match o:
    case Opts{m, p, l, s, g, q, b, t}:
      Opts{max, p, l, s, g, q, b, t}

def Opts.with_port(o: Opts, port: U32) -> Opts:
  match o:
    case Opts{m, p, l, s, g, q, b, t}:
      Opts{m, port, l, s, g, q, b, t}

def Opts.with_grace(o: Opts, ms: U32) -> Opts:
  match o:
    case Opts{m, p, l, s, g, q, b, t}:
      Opts{m, p, l, s, ms, q, b, t}

# A reconcile timeout, ms, for every spec that sets none (0: none, the
# default), as controller-runtime's manager-wide ReconciliationTimeout. A
# spec's own X.Spec.timeout wins. Bend cannot cancel a reconcile, so a
# reconcile past it exits the process (status 1), as X.Spec.timeout says.
def Opts.with_timeout(o: Opts, ms: U32) -> Opts:
  match o:
    case Opts{m, p, l, s, g, q, b, t}:
      Opts{m, p, l, s, g, q, b, ms}

# qps 0 turns the rate limit off.
def Opts.with_rate(o: Opts, qps: U32, burst: U32) -> Opts:
  match o:
    case Opts{m, p, l, s, g, q, b, t}:
      Opts{m, p, l, s, g, qps, burst, t}

def Kube.serve.go(+port: U32, +status: Chan(R.SMsg), +meter: Chan(X.Meter), off: Bool) -> IO(Unit):
  match off:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.spawn(Unit, V.Serve.run(port, status, meter))

def Kube.port.of(+port: U32, e: Result<&1, &1, U32 & String, String>) -> U32:
  match e:
    case Done{v}:
      Maybe.default(&2, U32, U32.read(v), port)
    case Fail{x}:
      port

def Kube.serve.at(+port: U32, +status: Chan(R.SMsg), +meter: Chan(X.Meter)) -> IO(Unit):
  Kube.serve.go(port, status, meter, U32.is_eq(port, 0))

# The health and metrics port: BEND_KUBE_PORT when set (0 for none), else
# Opts.port.
def Kube.serve(+port: U32, +status: Chan(R.SMsg), +meter: Chan(X.Meter)) -> IO(Unit):
  IO.bind(Result<&1, &1, U32 & String, String>, Unit, IO.get_env("BEND_KUBE_PORT"),
    e => Kube.serve.at(Kube.port.of(port, e), status, meter))

# Without leader election: on SIGTERM or SIGINT, drain, then exit 0; a
# second signal exits at once.
def Kube.on_signal(drain: IO(Bool)) -> IO(Unit):
  IO.bind(U32, Unit, Y.Sys.signal(),
    sig => IO.bind(Unit, Unit, L.Log.info("terminating", [L.Log.kv("signal", U32.show(sig))]),
      u => IO.bind(Unit, Unit, IO.spawn(Unit, E.Leader.again()),
        u1 => IO.bind(Bool, Unit, drain, d => IO.exit(0)))))

def Kube.ident.of(h: Result<&1, &1, U32 & String, String>, r: Result<&1, &1, U32 & String, U32>) ->
  String:
  match h r:
    case Done{host} Done{x}:
      host ++ "_" ++ U32.show(x)
    case Fail{e} Done{x}:
      "bend-kube_" ++ U32.show(x)
    case Done{host} Fail{e}:
      host
    case Fail{e} Fail{e2}:
      "bend-kube"

# This replica's identity: the pod name and a random suffix.
def Kube.ident() -> IO(String):
  IO.bind(Result<&1, &1, U32 & String, String>, String, IO.get_env("HOSTNAME"),
    h => IO.bind(Result<&1, &1, U32 & String, U32>, String, IO.random_u32(),
      r => IO.pure(String, Kube.ident.of(h, r))))

def Kube.elect.as(+cfg: K.Config, lo: E.LOpts, drain: IO(Bool), work: IO(Unit), auto: Bool) -> IO(Unit):
  match lo auto:
    case E.LOpts{ns, n, id, d, dl, rt} True{}:
      IO.bind(String, Unit, Kube.ident(),
        +me => IO.bind(Unit, Unit, L.Log.info("leader identity", [L.Log.kv("id", me)]),
          u => E.Leader.elect(cfg, E.LOpts{ns, n, me, d, dl, rt}, drain, work)))
    case x False{}:
      E.Leader.elect(cfg, x, drain, work)

def Kube.elect(+cfg: K.Config, l: Maybe<&2, E.LOpts>, drain: IO(Bool), work: IO(Unit)) -> IO(Unit):
  match l:
    case Some{+lo}:
      Kube.elect.as(cfg, lo, drain, work, String.is_empty(E.LOpts.id(lo)))
    case None{}:
      IO.bind(Unit, Unit, IO.spawn(Unit, Kube.on_signal(drain)), u => work)

# Each watch on another cluster gets a pool of its own: a pool holds
# connections to one API server, never shared across servers.
def Kube.pool_on(m: Maybe<&2, K.Config>) -> IO(Maybe<&2, K.Config>):
  match m:
    case None{}:
      IO.pure(Maybe<&2, K.Config>, None{})
    case Some{c}:
      IO.bind(Chan(Socket), Maybe<&2, K.Config>, Chan.new(Socket, 8),
        p => IO.pure(Maybe<&2, K.Config>, Some{K.Config.with_pool(c, p)}))

def Kube.pool_secs(ss: List<&2, X.Sec>) -> IO(List<&2, X.Sec>):
  match ss:
    case Nil{}:
      IO.pure(List<&2, X.Sec>, Nil{})
    case Con{X.Sec{a, l, f, r, d, ps, c}, t}:
      IO.bind(Maybe<&2, K.Config>, List<&2, X.Sec>, Kube.pool_on(c),
        c2 => IO.bind(List<&2, X.Sec>, List<&2, X.Sec>, Kube.pool_secs(t),
          t2 => IO.pure(List<&2, X.Sec>, X.Sec{a, l, f, r, d, ps, c2} <> t2)))

def Kube.pool_specs(ss: List<&2, X.Spec>) -> IO(List<&2, X.Spec>):
  match ss:
    case Nil{}:
      IO.pure(List<&2, X.Spec>, Nil{})
    case Con{X.Spec{p, l, fs, ps, secs, m, to, c}, t}:
      IO.bind(Maybe<&2, K.Config>, List<&2, X.Spec>, Kube.pool_on(c),
        c2 => IO.bind(List<&2, X.Sec>, List<&2, X.Spec>, Kube.pool_secs(secs),
          secs2 => IO.bind(List<&2, X.Spec>, List<&2, X.Spec>, Kube.pool_specs(t),
            t2 => IO.pure(List<&2, X.Spec>, X.Spec{p, l, fs, ps, secs2, m, to, c2} <> t2))))

def Kube.timeouts(ss: List<&2, X.Spec>, +ms: U32) -> List<&2, X.Spec>:
  match ss:
    case Nil{}:
      Nil{}
    case Con{s, t}:
      X.Spec.timeout_or(s, ms) <> Kube.timeouts(t, ms)

def Kube.start.go(~rec: J.Json -> X.Ctx -> IO(Q.Action), +cfg: K.Config, +ecfg: K.Config,
  +specs: List<&2, X.Spec>, +p: U32, l: Maybe<&2, E.LOpts>, +grace: U32) -> IO(Unit):
  IO.bind(List<&2, Chan(R.Msg)>, Unit, R.Manager.inboxes(List.length(&2, X.Spec, specs)),
    +chs => IO.bind(Chan(R.SMsg), Unit, R.Keeper.start(),
      +status => IO.bind(Chan(Unit), Unit, R.Manager.gate(),
        +gate => IO.bind(Chan(X.Meter), Unit, R.Meter.start(), +meter => IO.bind(Unit, Unit, Kube.serve(p, status, meter),
          u => IO.bind(Unit, Unit, L.Log.info("starting controllers",
            [L.Log.kv("count", Nat.show(List.length(&2, X.Spec, specs))),
              L.Log.kv("server", K.Config.host(cfg))]),
            u2 => Kube.elect(ecfg, l, R.Manager.stop(chs, gate, grace),
              R.Manager.start(~rec, cfg, specs, chs, status, meter, gate))))))))

# cfg serves the controllers (rate-limited); ecfg serves leader election,
# outside the rate limit, so a burst of reconciles never delays a renewal.
# Every spec without its own reconcile timeout takes Opts.timeout, and
# every watch on another cluster gets its own connection pool.
def Kube.start(~rec: J.Json -> X.Ctx -> IO(Q.Action), +cfg: K.Config, +ecfg: K.Config,
  specs: List<&2, X.Spec>, o: Opts) -> IO(Unit):
  match o:
    case Opts{m, +p, l, sel, +grace, q, b, +to}:
      IO.bind(List<&2, X.Spec>, Unit, Kube.pool_specs(Kube.timeouts(specs, to)),
        +ss => Kube.start.go(~rec, cfg, ecfg, ss, p, l, grace))

# Up to 8 idle keep-alive connections shared by every request.
def Kube.pool() -> IO(Chan(Socket)):
  Chan.new(Socket, 8)

def Kube.limited(+cfg: K.Config, +qps: U32, +burst: U32, off: Bool) -> IO(K.Config):
  match off:
    case True{}:
      IO.pure(K.Config, cfg)
    case False{}:
      IO.bind(Chan(Unit), K.Config, Cl.Limit.start(qps, burst),
        ch => IO.pure(K.Config, K.Config.with_limit(cfg, ch)))

# A config for another cluster (X.Spec.on, X.Spec.watch_on) with its own
# rate limit (qps 0: none), as Kube.control gives the controllers' config;
# Kube.control gives it its own connection pool.
def Kube.connect(+cfg: K.Config, +qps: U32, +burst: U32) -> IO(K.Config):
  Kube.limited(cfg, qps, burst, U32.is_eq(qps, 0))

def Kube.rate(o: Opts, +cfg: K.Config) -> IO(K.Config):
  match o:
    case Opts{m, p, l, s, g, +q, b, t}:
      Kube.limited(cfg, q, b, U32.is_eq(q, 0))

def Opts.elects(o: Opts) -> Bool:
  match o:
    case Opts{m, p, Some{l}, s, g, q, b, t}:
      True{}
    case _:
      False{}

def Kube.fenced(+cfg: K.Config, m: Maybe<&2, Chan(K.FenceMsg)>) -> K.Config:
  match m:
    case Some{ch}:
      K.Config.with_fence(cfg, ch)
    case None{}:
      cfg

# Under leader election, a leadership fence shared by the controllers'
# config and the election's (Leader.fence, Fence.check in client.bend).
def Kube.fence(on: Bool) -> IO(Maybe<&2, Chan(K.FenceMsg)>):
  match on:
    case True{}:
      IO.bind(Chan(K.FenceMsg), Maybe<&2, Chan(K.FenceMsg)>, Cl.Fence.start(),
        ch => IO.pure(Maybe<&2, Chan(K.FenceMsg)>, Some{ch}))
    case False{}:
      IO.pure(Maybe<&2, Chan(K.FenceMsg)>, None{})

def Kube.pooled(~rec: J.Json -> X.Ctx -> IO(Q.Action), +cfg: K.Config, specs: List<&2, X.Spec>,
  +o: Opts) -> IO(Unit):
  IO.bind(Maybe<&2, Chan(K.FenceMsg)>, Unit, Kube.fence(Opts.elects(o)),
    +fc => IO.bind(K.Config, Unit, Kube.rate(o, cfg),
      cfg2 => Kube.start(~rec, Kube.fenced(cfg2, fc), Kube.fenced(cfg, fc), specs, o)))

# Runs controllers against a given config (another cluster, a test
# server); Kube.control_all infers it. The config gets a connection pool
# and the rate limit.
def Kube.control_with(~rec: J.Json -> X.Ctx -> IO(Q.Action), cfg: K.Config, specs: List<&2, X.Spec>,
  +o: Opts) -> IO(Unit):
  IO.bind(Chan(Socket), Unit, Kube.pool(),
    p => Kube.pooled(~rec, K.Config.with_pool(cfg, p), specs, o))

def Kube.configured(~rec: J.Json -> X.Ctx -> IO(Q.Action), c: Result<&2, &2, String, K.Config>,
  specs: List<&2, X.Spec>, +o: Opts) -> IO(Unit):
  match c:
    case Done{cfg}:
      Kube.control_with(~rec, cfg, specs, o)
    case Fail{e}:
      IO.die(Unit, 1, "bend-kube: no config: " ++ e)

# Runs several controllers, sharing their watches (Manager): rec(obj, ctx)
# reconciles obj for controller X.Ctx.idx(ctx), its place in specs.
def Kube.control_all(~rec: J.Json -> X.Ctx -> IO(Q.Action), specs: List<&2, X.Spec>, o: Opts) ->
  IO(Unit):
  IO.bind(Result<&2, &2, String, K.Config>, Unit, Cl.Config.infer(),
    c => Kube.configured(~rec, c, specs, o))

# Runs one controller (kube-runtime's Controller::new(..).run(..)).
def Kube.control(~rec: J.Json -> X.Ctx -> IO(Q.Action), spec: X.Spec, o: Opts) -> IO(Unit):
  Kube.control_all(~rec, [spec], o)

def Opts.ctrl(o: Opts, primary: C.Api, owned: List<&2, C.Api>) -> R.Ctrl:
  match o:
    case Opts{m, p, l, s, g, q, b, t}:
      R.Ctrl{primary, s, owned, m}

# Runs a controller for primary, owning owned, reconciling with rec(obj,
# cfg); Opts.label and Opts.max shape it.
def Kube.run(~rec: J.Json -> K.Config -> IO(Q.Action), primary: C.Api, owned: List<&2, C.Api>,
  +o: Opts) -> IO(Unit):
  Kube.control(~(x => c => rec(x, X.Ctx.cfg(c))), R.Ctrl.spec(Opts.ctrl(o, primary, owned)), o)

# Several controllers in one process, sharing their watches: rec(i, obj,
# cfg) reconciles for the i-th controller of cs.
def Kube.run_all(~rec: U32 -> J.Json -> K.Config -> IO(Q.Action), cs: List<&2, R.Ctrl>, o: Opts) ->
  IO(Unit):
  Kube.control_all(~(x => c => rec(X.Ctx.idx(c), x, X.Ctx.cfg(c))), R.Ctrl.specs(cs), o)
