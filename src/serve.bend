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

def Serve.probe.answer(m: Poll<&1, &1, Maybe<&1, List<&2, R.Snap>>, Unit>) -> List<&2, R.Snap>:
  match m:
    case Ready{Some{x}}:
      x
    case _:
      Nil{}

# Every controller's snapshot from the status keeper, which answers at once
# (none on a standby replica).
def Serve.probe(+status: Chan(R.SMsg)) -> IO(List<&2, R.Snap>):
  IO.bind(Chan(List<&2, R.Snap>), List<&2, R.Snap>, Chan.new(List<&2, R.Snap>, 1),
    +c => IO.bind(Result<&1, &1, R.SMsg, Unit>, List<&2, R.Snap>,
      Chan.send(R.SMsg, status, R.SGet{c}),
      u => IO.bind(Poll<&1, &1, Maybe<&1, List<&2, R.Snap>>, Unit>, List<&2, R.Snap>,
        Chan.try_recv(List<&2, R.Snap>, c, 500),
        m => IO.pure(List<&2, R.Snap>, Serve.probe.answer(m)))))

def Serve.all_ready(ss: List<&2, R.Snap>) -> Bool:
  match ss:
    case Nil{}:
      True{}
    case Con{R.Snap{nm, r, a, b, c, d, e}, t}:
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
    case R.Snap{n, r, a, b, c, d, e}:
      n

def Serve.snap.pick.go(r: Bool, +a: U32, +b: U32, +c: U32, +d: U32, +e: U32, i0: Bool, i1: Bool,
  i2: Bool, i3: Bool, i4: Bool) -> String:
  match i0 i1 i2 i3 i4:
    case True{} _ _ _ _:
      Serve.bool(r)
    case False{} True{} _ _ _:
      U32.show(a)
    case False{} False{} True{} _ _:
      U32.show(b)
    case False{} False{} False{} True{} _:
      U32.show(c)
    case False{} False{} False{} False{} True{}:
      U32.show(d)
    case _ _ _ _ _:
      U32.show(e)

def Serve.snap.pick(+i: U32, r: Bool, +a: U32, +b: U32, +c: U32, +d: U32, +e: U32) -> String:
  Serve.snap.pick.go(r, a, b, c, d, e, U32.is_eq(i, 0), U32.is_eq(i, 1), U32.is_eq(i, 2),
    U32.is_eq(i, 3), U32.is_eq(i, 4))

# The field-th number of a snapshot (0 ready, 1 reconciles, 2 errors,
# 3 events, 4 running, 5 objects).
def Serve.snap.field(s: R.Snap, +i: U32) -> String:
  match s:
    case R.Snap{n, r, +a, +b, +c, +d, +e}:
      Serve.snap.pick(i, r, a, b, c, d, e)

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
    ++ Serve.family(ss, "bendkube_store_ready", "gauge", "Whether the primary store has listed.", 0)

def Serve.metrics(+ss: List<&2, R.Snap>) -> String:
  Serve.reply(200, "text/plain; version=0.0.4", Serve.text(ss))

# The answer to a request.
def Serve.route(path: String, +status: Chan(R.SMsg)) -> IO(String):
  match path:
    case "/healthz":
      IO.pure(String, Serve.reply(200, "text/plain", "ok\n"))
    case "/readyz":
      IO.bind(List<&2, R.Snap>, String, Serve.probe(status), m => IO.pure(String, Serve.ready(m)))
    case "/metrics":
      IO.bind(List<&2, R.Snap>, String, Serve.probe(status), m => IO.pure(String, Serve.metrics(m)))
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
def Serve.loop(fuel: Nat, ev: AEv, +status: Chan(R.SMsg)) -> IO(Unit):
  match fuel ev:
    case 0n AGot{l, r}:
      Listener.close(l)
    case 1n+f AGot{l, r}:
      IO.bind(Unit, Unit, Serve.accepted(r, status),
        u => IO.bind(Listener & Serve.Res(Socket), Unit, TCP.accept(l),
          p => Serve.loop(f, AEv.got(p), status)))

def Serve.listening(r: Serve.Res(Listener), +status: Chan(R.SMsg)) -> IO(Unit):
  match r:
    case Done{l}:
      IO.bind(Listener & Serve.Res(Socket), Unit, TCP.accept(l),
        p => Serve.loop(4294967295n, AEv.got(p), status))
    case Fail{(c, m)}:
      IO.print_err("health server: " ++ m)

# Serves the endpoints on 0.0.0.0:port.
def Serve.run(+port: U32, +status: Chan(R.SMsg)) -> IO(Unit):
  IO.bind(Serve.Res(Listener), Unit, TCP.listen("0.0.0.0", port), r => Serve.listening(r, status))
