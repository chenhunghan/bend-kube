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
# limit (qps 0: none).
type Opts is Data:
  Opts{max: U32, port: U32, leader: Maybe<&2, E.LOpts>, label: String, grace: U32, qps: U32,
    burst: U32}

# 8 reconciles at once, health and metrics on :8080, no leader election, a
# 25s grace period (inside Kubernetes' default 30s), and 50 requests a
# second with bursts of 100.
def Opts.default() -> Opts:
  Opts{8, 8080, None{}, "", 25000, 50, 100}

def Opts.with_leader(o: Opts, ns: String, name: String, id: String) -> Opts:
  match o:
    case Opts{m, p, l, s, g, q, b}:
      Opts{m, p, Some{E.LOpts.default(ns, name, id)}, s, g, q, b}

def Opts.with_label(o: Opts, label: String) -> Opts:
  match o:
    case Opts{m, p, l, s, g, q, b}:
      Opts{m, p, l, label, g, q, b}

def Opts.with_max(o: Opts, max: U32) -> Opts:
  match o:
    case Opts{m, p, l, s, g, q, b}:
      Opts{max, p, l, s, g, q, b}

def Opts.with_port(o: Opts, port: U32) -> Opts:
  match o:
    case Opts{m, p, l, s, g, q, b}:
      Opts{m, port, l, s, g, q, b}

def Opts.with_grace(o: Opts, ms: U32) -> Opts:
  match o:
    case Opts{m, p, l, s, g, q, b}:
      Opts{m, p, l, s, ms, q, b}

# qps 0 turns the rate limit off.
def Opts.with_rate(o: Opts, qps: U32, burst: U32) -> Opts:
  match o:
    case Opts{m, p, l, s, g, q, b}:
      Opts{m, p, l, s, g, qps, burst}

def Kube.serve.go(+port: U32, +status: Chan(R.SMsg), off: Bool) -> IO(Unit):
  match off:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.spawn(Unit, V.Serve.run(port, status))

def Kube.serve(+port: U32, +status: Chan(R.SMsg)) -> IO(Unit):
  Kube.serve.go(port, status, U32.is_eq(port, 0))

# Without leader election: on SIGTERM or SIGINT, drain, then exit 0.
def Kube.on_signal(drain: IO(Unit)) -> IO(Unit):
  IO.bind(U32, Unit, Y.Sys.signal(),
    sig => IO.bind(Unit, Unit, L.Log.info("terminating", [L.Log.kv("signal", U32.show(sig))]),
      u => IO.bind(Unit, Unit, drain, u2 => IO.exit(0))))

def Kube.elect(+cfg: K.Config, l: Maybe<&2, E.LOpts>, drain: IO(Unit), work: IO(Unit)) -> IO(Unit):
  match l:
    case Some{+lo}:
      E.Leader.elect(cfg, lo, drain, work)
    case None{}:
      IO.bind(Unit, Unit, IO.spawn(Unit, Kube.on_signal(drain)), u => work)

def Kube.start(~rec: J.Json -> X.Ctx -> IO(Q.Action), +cfg: K.Config, +specs: List<&2, X.Spec>,
  o: Opts) -> IO(Unit):
  match o:
    case Opts{m, +p, l, sel, +grace, q, b}:
      IO.bind(List<&2, Chan(R.Msg)>, Unit, R.Manager.inboxes(List.length(&2, X.Spec, specs)),
        +chs => IO.bind(Chan(R.SMsg), Unit, R.Keeper.start(),
          +status => IO.bind(Unit, Unit, Kube.serve(p, status),
            u => IO.bind(Unit, Unit, L.Log.info("starting controllers",
              [L.Log.kv("count", Nat.show(List.length(&2, X.Spec, specs))),
                L.Log.kv("server", K.Config.host(cfg))]),
              u2 => Kube.elect(cfg, l, R.Manager.stop(chs, status, grace),
                R.Manager.start(~rec, cfg, specs, chs, status))))))

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

def Kube.rate(o: Opts, +cfg: K.Config) -> IO(K.Config):
  match o:
    case Opts{m, p, l, s, g, +q, b}:
      Kube.limited(cfg, q, b, U32.is_eq(q, 0))

def Kube.configured(~rec: J.Json -> X.Ctx -> IO(Q.Action), c: Result<&2, &2, String, K.Config>,
  specs: List<&2, X.Spec>, +o: Opts) -> IO(Unit):
  match c:
    case Done{cfg}:
      IO.bind(Chan(Socket), Unit, Kube.pool(),
        p => IO.bind(K.Config, Unit, Kube.rate(o, K.Config.with_pool(cfg, p)),
          cfg2 => Kube.start(~rec, cfg2, specs, o)))
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
    case Opts{m, p, l, s, g, q, b}:
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
