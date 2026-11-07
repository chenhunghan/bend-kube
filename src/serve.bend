import Base
import ./runtime.bend as R
import ./utf8.bend as U

# Serve
# =====
#
# The health and metrics endpoints a Deployment's probes and Prometheus
# scrape (controller-runtime's /healthz, /readyz and /metrics), over plain
# HTTP/1.1. Each connection is served by its own computation, reads at
# most 8KiB within 5s, and is closed after one answer.
#
# /healthz answers 200 while the process serves. /readyz and /metrics ask
# the status keeper for the controller's latest snapshot; a replica that
# is not the leader has none, and answers ready (standby).

def Serve.Res(-A: Type) -> Type:
  Result<&1, &1, U32 & String, A>

def Serve.size(s: String) -> U32:
  U.Utf8.size(s)

def Serve.reason.go(ok: Bool, missing: Bool) -> String:
  match ok missing:
    case True{} _:
      "OK"
    case False{} True{}:
      "Not Found"
    case False{} False{}:
      "Service Unavailable"

def Serve.reason(+code: U32) -> String:
  Serve.reason.go(U32.is_eq(code, 200), U32.is_eq(code, 404))

def Serve.reply(+code: U32, ctype: String, +body: String) -> String:
  "HTTP/1.1 " ++ U32.show(code) ++ " " ++ Serve.reason(code) ++ "\r\nContent-Type: " ++ ctype
    ++ "\r\nContent-Length: " ++ U32.show(Serve.size(body)) ++ "\r\nConnection: close\r\n\r\n"
    ++ body

def Serve.first_line.go(ls: List<&2, String>) -> String:
  match ls:
    case Con{l, t}:
      l
    case Nil{}:
      ""

def Serve.first_line(s: String) -> String:
  Serve.first_line.go(String.lines(s))

def Serve.path.go(parts: List<&2, String>) -> String:
  match parts:
    case Con{m, Con{p, rest}}:
      p
    case _:
      ""

# The request line's path.
def Serve.path(req: String) -> String:
  Serve.path.go(String.split(String.trim(Serve.first_line(req)), ' '))

def Serve.probe.answer(m: Poll<&1, &1, Maybe<&1, List<&2, R.Snap>>, Unit>) ->
  Maybe<&2, List<&2, R.Snap>>:
  match m:
    case Ready{Some{x}}:
      Some{x}
    case _:
      None{}

# Every controller's snapshot from the status keeper (none on a standby
# replica), or None if the keeper did not answer within 2s.
def Serve.probe(+status: Chan(R.SMsg)) -> IO(Maybe<&2, List<&2, R.Snap>>):
  IO.bind(Chan(List<&2, R.Snap>), Maybe<&2, List<&2, R.Snap>>, Chan.new(List<&2, R.Snap>, 1),
    +c => IO.bind(Poll<&1, &1, Result<&1, &1, R.SMsg, Unit>, R.SMsg>, Maybe<&2, List<&2, R.Snap>>,
      Chan.try_send(R.SMsg, status, R.SGet{c}, 1000),
      u => IO.bind(Poll<&1, &1, Maybe<&1, List<&2, R.Snap>>, Unit>, Maybe<&2, List<&2, R.Snap>>,
        Chan.try_recv(List<&2, R.Snap>, c, 2000),
        m => IO.pure(Maybe<&2, List<&2, R.Snap>>, Serve.probe.answer(m)))))

def Serve.unavailable() -> String:
  Serve.reply(503, "text/plain", "status unavailable\n")

def Serve.all_ready(ss: List<&2, R.Snap>) -> Bool:
  match ss:
    case Nil{}:
      True{}
    case Con{R.Snap{nm, r, a, b, c, d, e, q, h, sm, cz}, t}:
      Bool.and(r, Serve.all_ready(t))

def Serve.ready.go(standby: Bool, ready: Bool) -> String:
  match standby ready:
    case True{} _:
      Serve.reply(200, "text/plain", "standby\n")
    case False{} True{}:
      Serve.reply(200, "text/plain", "ok\n")
    case False{} False{}:
      Serve.reply(503, "text/plain", "store not synced\n")

# Ready when every controller's store has listed; a standby is ready.
def Serve.ready(+ss: List<&2, R.Snap>) -> String:
  Serve.ready.go(List.is_empty(&2, R.Snap, ss), Serve.all_ready(ss))

def Serve.bool(b: Bool) -> String:
  match b:
    case True{}:
      "1"
    case False{}:
      "0"

def Serve.head(+name: String, kind: String, help: String) -> String:
  "# HELP " ++ name ++ " " ++ help ++ "\n# TYPE " ++ name ++ " " ++ kind ++ "\n"

def Serve.snap.name(s: R.Snap) -> String:
  match s:
    case R.Snap{n, r, a, b, c, d, e, q, h, sm, cz}:
      n

def Serve.nth(xs: List<&2, String>, n: Nat) -> String:
  match xs n:
    case Nil{} k:
      "0"
    case Con{x, t} 0n:
      x
    case Con{x, t} 1n+k:
      Serve.nth(t, k)

# The field-th number of a snapshot (0 ready, 1 reconciles, 2 errors,
# 3 events, 4 running, 5 objects, 6 queued).
def Serve.snap.field(s: R.Snap, +i: U32) -> String:
  match s:
    case R.Snap{n, r, a, b, c, d, e, q, h, sm, cz}:
      Serve.nth([Serve.bool(r), U32.show(a), U32.show(b), U32.show(c), U32.show(d), U32.show(e),
        U32.show(q)], U32.to_nat(i))

# Reconcile durations as a Prometheus histogram: cumulative buckets in
# seconds, the sum and the count.
def Serve.les() -> List<&2, String>:
  ["0.005", "0.01", "0.025", "0.05", "0.1", "0.25", "0.5", "1", "2.5", "5", "10", "+Inf"]

def Serve.buckets(+name: String, +ctl: String, les: List<&2, String>, cs: List<&2, U32>,
  +acc: U32) -> String:
  match les cs:
    case Con{le, lt} Con{+c, ct}:
      name ++ "_bucket{controller=\"" ++ ctl ++ "\",le=\"" ++ le ++ "\"} " ++ U32.show((acc + c : U32))
        ++ "\n" ++ Serve.buckets(name, ctl, lt, ct, (acc + c : U32))
    case _ _:
      name ++ "_count{controller=\"" ++ ctl ++ "\"} " ++ U32.show(acc) ++ "\n"

def Serve.pad3(+n: U32) -> String:
  String.drop(U32.show((n + 1000 : U32)), 1n)

def Serve.secs(x: R.Sum) -> String:
  match x:
    case R.Sum{s, +m}:
      U32.show(s) ++ "." ++ Serve.pad3(m)

def Serve.cache.go(+ctl: String, cz: List<&2, U32>, +i: U32) -> String:
  match cz:
    case Nil{}:
      ""
    case Con{c, t}:
      "bendkube_cache_objects{controller=\"" ++ ctl ++ "\",cache=\"" ++ U32.show(i) ++ "\"} "
        ++ U32.show(c) ++ "\n" ++ Serve.cache.go(ctl, t, (i + 1 : U32))

def Serve.caches(ss: List<&2, R.Snap>) -> String:
  match ss:
    case Nil{}:
      ""
    case Con{R.Snap{n, r, a, b, c, d, e, q, h, sm, cz}, t}:
      Serve.cache.go(n, cz, 1) ++ Serve.caches(t)

def Serve.hist(ss: List<&2, R.Snap>, +name: String) -> String:
  match ss:
    case Nil{}:
      ""
    case Con{R.Snap{+n, r, a, b, c, d, e, q, h, sm, cz}, t}:
      Serve.buckets(name, n, Serve.les(), h, 0)
        ++ name ++ "_sum{controller=\"" ++ n ++ "\"} " ++ Serve.secs(sm) ++ "\n" ++ Serve.hist(t, name)

# One sample per controller, labeled with its kind.
def Serve.samples(ss: List<&2, R.Snap>, +name: String, +field: U32) -> String:
  match ss:
    case Nil{}:
      ""
    case Con{+x, t}:
      name ++ "{controller=\"" ++ Serve.snap.name(x) ++ "\"} " ++ Serve.snap.field(x, field) ++ "\n"
        ++ Serve.samples(t, name, field)

def Serve.family(+ss: List<&2, R.Snap>, +name: String, kind: String, help: String, +field: U32) -> String:
  Serve.head(name, kind, help) ++ Serve.samples(ss, name, field)

# The Prometheus text format: one sample per controller; a standby
# replica reports only that it leads nothing.
def Serve.text(+ss: List<&2, R.Snap>) -> String:
  Serve.head("bendkube_leader", "gauge", "Whether this replica runs the controllers.")
    ++ "bendkube_leader " ++ Serve.bool(Bool.not(List.is_empty(&2, R.Snap, ss))) ++ "\n"
    ++ Serve.family(ss, "bendkube_reconcile_total", "counter", "Reconciles finished.", 1)
    ++ Serve.family(ss, "bendkube_reconcile_errors_total", "counter", "Reconciles that asked to retry.", 2)
    ++ Serve.family(ss, "bendkube_watch_events_total", "counter", "Watcher outputs received.", 3)
    ++ Serve.family(ss, "bendkube_reconcile_running", "gauge", "Reconciles running now.", 4)
    ++ Serve.family(ss, "bendkube_store_objects", "gauge", "Objects in the primary store.", 5)
    ++ Serve.family(ss, "bendkube_store_ready", "gauge", "Whether every cache has listed.", 0)
    ++ Serve.family(ss, "bendkube_queue_depth", "gauge", "Keys waiting to reconcile.", 6)
    ++ Serve.head("bendkube_cache_objects", "gauge", "Objects in each related watch's cache, by its number.")
    ++ Serve.caches(ss)
    ++ Serve.head("bendkube_reconcile_duration_seconds", "histogram", "How long reconciles take.")
    ++ Serve.hist(ss, "bendkube_reconcile_duration_seconds")

def Serve.metrics(+ss: List<&2, R.Snap>) -> String:
  Serve.reply(200, "text/plain; version=0.0.4", Serve.text(ss))

def Serve.or_unavailable(m: Maybe<&2, List<&2, R.Snap>>, metrics: Bool) -> String:
  match m metrics:
    case Some{+ss} True{}:
      Serve.metrics(ss)
    case Some{+ss} False{}:
      Serve.ready(ss)
    case None{} _:
      Serve.unavailable()

# The answer to a request.
def Serve.route(path: String, +status: Chan(R.SMsg)) -> IO(String):
  match path:
    case "/healthz":
      IO.pure(String, Serve.reply(200, "text/plain", "ok\n"))
    case "/readyz":
      IO.bind(Maybe<&2, List<&2, R.Snap>>, String, Serve.probe(status),
        m => IO.pure(String, Serve.or_unavailable(m, False{})))
    case "/metrics":
      IO.bind(Maybe<&2, List<&2, R.Snap>>, String, Serve.probe(status),
        m => IO.pure(String, Serve.or_unavailable(m, True{})))
    case _:
      IO.pure(String, Serve.reply(404, "text/plain", "not found\n"))

def Serve.answer.done(p: Socket & Poll<&1, &1, Result<&1, &1, (U32 & String) & List<&2, U32>,
  Unit>, List<&2, U32>>) -> IO(Unit):
  match p:
    case (s, r):
      Socket.close(s)

def Serve.answer(s: Socket, text: String) -> IO(Unit):
  IO.bind(Socket & Poll<&1, &1, Result<&1, &1, (U32 & String) & List<&2, U32>, Unit>,
    List<&2, U32>>, Unit, TCP.try_send(s, text, 5000), Serve.answer.done)

def Serve.handle.got(p: Socket & Poll<&1, &1, Serve.Res(Maybe<&1, String>), Unit>,
  +status: Chan(R.SMsg)) -> IO(Unit):
  match p:
    case (s, Ready{Done{Some{req}}}):
      IO.bind(String, Unit, Serve.route(Serve.path(req), status), t => Serve.answer(s, t))
    case (s, _):
      Socket.close(s)

def Serve.handle(s: Socket, +status: Chan(R.SMsg)) -> IO(Unit):
  IO.bind(Socket & Poll<&1, &1, Serve.Res(Maybe<&1, String>), Unit>, Unit,
    TCP.try_recv(s, 8192, 5000), p => Serve.handle.got(p, status))

def Serve.accepted(r: Serve.Res(Socket), +status: Chan(R.SMsg)) -> IO(Unit):
  match r:
    case Done{s}:
      IO.spawn(Unit, Serve.handle(s, status))
    case Fail{e}:
      IO.pure(Unit, Unit{})

type AEv is Type:
  AGot{l: Listener, r: Result<&1, &1, U32 & String, Socket>}

def AEv.got(p: Listener & Serve.Res(Socket)) -> AEv:
  match p:
    case (l, r):
      AGot{l, r}

# Accepts forever (fuel permitting), serving each connection on its own.
def Serve.loop(outer: Nat, fuel: Nat, ev: AEv, +status: Chan(R.SMsg)) -> IO(Unit):
  match outer fuel ev:
    case 0n 0n AGot{l, r}:
      Listener.close(l)
    case 1n+o 0n e:
      Serve.loop(o, 4294967295n, e, status)
    case o 1n+f AGot{l, r}:
      IO.bind(Unit, Unit, Serve.accepted(r, status),
        u => IO.bind(Listener & Serve.Res(Socket), Unit, TCP.accept(l),
          p => Serve.loop(o, f, AEv.got(p), status)))

def Serve.listening(r: Serve.Res(Listener), +status: Chan(R.SMsg)) -> IO(Unit):
  match r:
    case Done{l}:
      IO.bind(Listener & Serve.Res(Socket), Unit, TCP.accept(l),
        p => Serve.loop(4294967295n, 4294967295n, AEv.got(p), status))
    case Fail{(c, m)}:
      # probes and metrics are part of the contract with the kubelet: a
      # port that cannot be bound is fatal (as in controller-runtime)
      IO.die(Unit, 1, "bend-kube: health server cannot listen: " ++ m)

# Serves the endpoints on 0.0.0.0:port.
def Serve.run(+port: U32, +status: Chan(R.SMsg)) -> IO(Unit):
  IO.bind(Serve.Res(Listener), Unit, TCP.listen("0.0.0.0", port), r => Serve.listening(r, status))
