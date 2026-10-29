import Base
import ./json.bend as J
import ./core.bend as C
import ./config.bend as K
import ./client.bend as Cl
import ./queue.bend as Q
import ./runtime.bend as R
import ./serve.bend as V
import ./leader.bend as E
import ./log.bend as L

# Kube
# ====
#
# The entry point a controller binary calls (the kube crate's facade):
# infer the config, serve health and metrics, elect a leader when asked,
# and run the controller.

# max: reconciles at once; port: health and metrics (0: off); leader: the
# Lease to hold while running; label: the primary watch's label selector.
type Opts is Data:
  Opts{max: U32, port: U32, leader: Maybe<&2, E.LOpts>, label: String}

# 8 reconciles at once, health and metrics on :8080, no leader election.
def Opts.default() -> Opts:
  Opts{8, 8080, None{}, ""}

def Opts.with_leader(o: Opts, ns: String, name: String, id: String) -> Opts:
  match o:
    case Opts{m, p, l, s}:
      Opts{m, p, Some{E.LOpts.default(ns, name, id)}, s}

def Opts.with_label(o: Opts, label: String) -> Opts:
  match o:
    case Opts{m, p, l, s}:
      Opts{m, p, l, label}

def Kube.serve.go(+port: U32, +status: Chan(R.SMsg), off: Bool) -> IO(Unit):
  match off:
    case True{}:
      IO.pure(Unit, Unit{})
    case False{}:
      IO.spawn(Unit, V.Serve.run(port, status))

def Kube.serve(+port: U32, +status: Chan(R.SMsg)) -> IO(Unit):
  Kube.serve.go(port, status, U32.is_eq(port, 0))

def Kube.elect(+cfg: K.Config, l: Maybe<&2, E.LOpts>, work: IO(Unit)) -> IO(Unit):
  match l:
    case Some{+lo}:
      E.Leader.elect(cfg, lo, work)
    case None{}:
      work

def Kube.start(~rec: J.Json -> K.Config -> IO(Q.Action), +cfg: K.Config, +primary: C.Api,
  owned: List<&2, C.Api>, o: Opts) -> IO(Unit):
  match o:
    case Opts{+m, +p, l, sel}:
      IO.bind(Chan(R.Msg), Unit, R.Controller.inbox(),
        +inbox => IO.bind(Chan(R.SMsg), Unit, R.Keeper.start(),
          +status => IO.bind(Unit, Unit, Kube.serve(p, status),
            u => IO.bind(Unit, Unit, L.Log.info("starting controller",
              [L.Log.kv("kind", R.Api.kind(primary)), L.Log.kv("server", K.Config.host(cfg))]),
              u2 => Kube.elect(cfg, l,
                R.Controller.start(~rec, cfg, primary, sel, owned, m, inbox, status))))))

# Up to 8 idle keep-alive connections shared by every request.
def Kube.pool() -> IO(Chan(Socket)):
  Chan.new(Socket, 8)

def Kube.configured(~rec: J.Json -> K.Config -> IO(Q.Action), c: Result<&2, &2, String, K.Config>,
  primary: C.Api, owned: List<&2, C.Api>, o: Opts) -> IO(Unit):
  match c:
    case Done{cfg}:
      IO.bind(Chan(Socket), Unit, Kube.pool(),
        p => Kube.start(~rec, K.Config.with_pool(cfg, p), primary, owned, o))
    case Fail{e}:
      IO.die(Unit, 1, "bend-kube: no config: " ++ e)

# Runs a controller for primary, owning owned, reconciling with rec.
def Kube.run(~rec: J.Json -> K.Config -> IO(Q.Action), primary: C.Api, owned: List<&2, C.Api>,
  o: Opts) -> IO(Unit):
  IO.bind(Result<&2, &2, String, K.Config>, Unit, Cl.Config.infer(),
    c => Kube.configured(~rec, c, primary, owned, o))

# Several controllers in one process, sharing their watches (Manager):
# rec(i, obj, cfg) reconciles for the i-th controller of cs. Opts.label is
# unused here (each Ctrl has its own); max likewise.
def Kube.start_all(~rec: U32 -> J.Json -> K.Config -> IO(Q.Action), +cfg: K.Config, +cs: List<&2, R.Ctrl>,
  o: Opts) -> IO(Unit):
  match o:
    case Opts{m, +p, l, sel}:
      IO.bind(Chan(R.SMsg), Unit, R.Keeper.start(),
        +status => IO.bind(Unit, Unit, Kube.serve(p, status),
          u => IO.bind(Unit, Unit, L.Log.info("starting controllers",
            [L.Log.kv("count", Nat.show(List.length(&2, R.Ctrl, cs))), L.Log.kv("server", K.Config.host(cfg))]),
            u2 => Kube.elect(cfg, l, R.Manager.start(~rec, cfg, cs, status)))))

def Kube.configured_all(~rec: U32 -> J.Json -> K.Config -> IO(Q.Action),
  c: Result<&2, &2, String, K.Config>, cs: List<&2, R.Ctrl>, o: Opts) -> IO(Unit):
  match c:
    case Done{cfg}:
      IO.bind(Chan(Socket), Unit, Kube.pool(),
        p => Kube.start_all(~rec, K.Config.with_pool(cfg, p), cs, o))
    case Fail{e}:
      IO.die(Unit, 1, "bend-kube: no config: " ++ e)

def Kube.run_all(~rec: U32 -> J.Json -> K.Config -> IO(Q.Action), cs: List<&2, R.Ctrl>, o: Opts) -> IO(Unit):
  IO.bind(Result<&2, &2, String, K.Config>, Unit, Cl.Config.infer(),
    c => Kube.configured_all(~rec, c, cs, o))
