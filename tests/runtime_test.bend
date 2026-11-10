import Base
import ../src/json.bend as J
import ../src/core.bend as C
import ../src/http.bend as H
import ../src/watcher.bend as W
import ../src/store.bend as S
import ../src/queue.bend as Q
import ../src/control.bend as X
import ../src/runtime.bend as R
import ../src/client.bend as Cl
import ../src/config.bend as K
import ../src/kube.bend as Kb

# Scenarios through the controller loop's pure steps: dispatch past keys
# whose objects are gone, one pending wake per key however often it is
# requeued, a stale sleeper that does nothing, and how a watch stream's
# end is read.

def cm(name: String) -> J.Json:
  J.Json.obj([J.KV{"metadata", J.Json.obj([J.KV{"name", J.JStr{name}},
    J.KV{"namespace", J.JStr{"ns"}}, J.KV{"resourceVersion", J.JStr{"1"}}])}])

def spec(+max: U32) -> X.Spec:
  X.Spec.max(X.Spec.of(C.Api{C.Res.config_maps(), C.InNs{"ns"}}), max)

def state(+max: U32) -> R.CState:
  R.CState{S.Store.new(), Nil{}, Q.Queue.new(max), R.Stats{0, 0, 0, R.Hist.zero(), R.Sum{0, 0}},
    None{}, R.Tim.new(), Nil{}}

def st(r: R.CState & List<&2, Q.Timer>) -> R.CState:
  match r:
    case (s, ts):
      s

def msg(s: R.CState, +m: R.Msg, +now: U32, +max: U32) -> R.CState & List<&2, R.Sleep>:
  R.Ctl.plan(R.Ctl.on_msg(R.Ctl.at(s, now), m, spec(max)))

def planned(r: R.CState & List<&2, R.Sleep>) -> R.CState:
  match r:
    case (s, ss):
      s

def sleeps.go(ss: List<&2, R.Sleep>) -> String:
  match ss:
    case Nil{}:
      "none"
    case Con{R.Sleep{k, due, ms}, Nil{}}:
      k ++ " at " ++ U32.show(due)
    case Con{R.Sleep{k, due, ms}, t}:
      k ++ " at " ++ U32.show(due) ++ ", " ++ sleeps.go(t)

def sleeps(r: R.CState & List<&2, R.Sleep>) -> String:
  match r:
    case (s, ss):
      sleeps.go(ss)

def jobs.go(js: List<&2, R.Job>) -> String:
  match js:
    case Nil{}:
      "none"
    case Con{R.Job{k, o, f}, Nil{}}:
      k
    case Con{R.Job{k, o, f}, t}:
      k ++ " " ++ jobs.go(t)

def jobs(r: R.CState & List<&2, R.Job>) -> String:
  match r:
    case (s, js):
      jobs.go(js)

def dispatched(r: R.CState & List<&2, R.Job>) -> R.CState:
  match r:
    case (s, js):
      s

def end.of(i: W.Input) -> String:
  match i:
    case W.IWatchEnd{}:
      "resume at once"
    case W.IWatchErr{c}:
      "back off"
    case _:
      "?"

def end(r: H.Resp) -> String:
  end.of(R.Drv.end_input(r))

def store_of(s: R.CState) -> S.Store:
  match s:
    case R.CState{st, cs, q, x, p, t, mq}:
      st

def with_queue(+s: S.Store) -> R.CState:
  R.CState{s, Nil{}, Q.Queue.add_all(["ns/gone1", "ns/gone2", "ns/live"], Q.Queue.new(1)),
    R.Stats{0, 0, 0, R.Hist.zero(), R.Sum{0, 0}}, None{}, R.Tim.new(), Nil{}}

def action(a: Q.Action) -> String:
  match a:
    case Q.Retry{m}:
      "Retry " ++ m
    case Q.RetryIn{m, ms}:
      "RetryIn " ++ U32.show(ms) ++ "ms: " ++ m
    case Q.Requeue{ms}:
      "Requeue " ++ U32.show(ms)
    case _:
      "other"

# Tokens the rate limiter adds over a second of ticks.
def tokens.go(n: Nat, +qps: U32, +every: U32, +burst: U32, +carry: U32, +acc: U32) -> U32:
  match n:
    case 0n:
      acc
    case 1n+k:
      tokens.go(k, qps, every, burst, Cl.Limit.carry(qps, every, carry),
        (acc + U32.from_nat(Cl.Limit.tick(qps, every, burst, carry)) : U32))

def tokens(+qps: U32, +burst: U32) -> String:
  U32.show(tokens.go(U32.to_nat((1000 / Cl.Limit.every(qps) : U32)), qps, Cl.Limit.every(qps), burst, 0, 0))

# The action a failed call suggests, from a reply's status and body.
def failed.of(r: Result<&2, &2, Cl.KErr, J.Json>) -> String:
  match r:
    case Fail{+e}:
      action(Cl.KErr.action(e))
    case Done{x}:
      "no error"

def failed(+code: U32, body: String) -> String:
  failed.of(Cl.Client.json.of(Done{Cl.Reply{code, body, None{}}}))

def failed_h(+code: U32, body: String, +secs: U32) -> String:
  failed.of(Cl.Client.json.of(Done{Cl.Reply{code, body, Some{secs}}}))

def waits(st: R.CState, +key: String) -> Bool:
  match st:
    case R.CState{s, cs, q, x, p, t, mq}:
      Q.Queue.waiting(q, key)

def kcfg(+host: String) -> K.Config:
  K.Config{host, 443, "", K.NoSrc{}, K.NoSrc{}, K.NoSrc{}, K.NoSrc{}, "default", None{}, None{}, "", None{}}

def cms() -> C.Api:
  C.Api{C.Res{"", "v1", "ConfigMap", "configmaps", True{}}, C.AllNs{}}

def pods() -> C.Api:
  C.Api{C.Res{"", "v1", "Pod", "pods", True{}}, C.AllNs{}}

def plan_line(ws: List<&2, R.Watch>) -> String:
  match ws:
    case Nil{}:
      ""
    case Con{R.Watch{a, l, f, None{}, ss}, t}:
      " " ++ C.Api.path(a) ++ "@main x" ++ Nat.show(List.length(&2, R.Sub, ss)) ++ plan_line(t)
    case Con{R.Watch{a, l, f, Some{c}, ss}, t}:
      " " ++ C.Api.path(a) ++ "@" ++ K.Config.host(c) ++ " x" ++ Nat.show(List.length(&2, R.Sub, ss))
        ++ plan_line(t)

# Two controllers: both watch ConfigMaps in their own cluster (one shared
# watch); the second also watches them on the host cluster, twice (one
# more watch, two subscribers), and pods there.
def plan(+ch: Chan(R.Msg)) -> String:
  plan_line(R.Plan.build([X.Spec.of(cms()),
    X.Spec.watch_on(X.Spec.watches(X.Spec.watch_on(X.Spec.watches(X.Spec.watch_on(X.Spec.watches(
      X.Spec.of(cms()), cms(), X.RAll{}), kcfg("host")), cms(), X.RAll{}), kcfg("host")), pods(), X.RAll{}),
      kcfg("host"))], [ch, ch], Nil{}))

# Pools per cluster: two watches on host and one on far (a primary on far
# too) need two pools, not four; the controllers' own config needs none.
def pool_hosts(cs: List<&2, K.Config>) -> String:
  match cs:
    case Nil{}:
      ""
    case Con{c, t}:
      " " ++ K.Config.server(c) ++ pool_hosts(t)

def pool_plan() -> String:
  pool_hosts(Kb.Pool.unique(Kb.Pool.of_specs([X.Spec.on(X.Spec.watch_on(X.Spec.watches(X.Spec.watch_on(
    X.Spec.watches(X.Spec.of(cms()), cms(), X.RAll{}), kcfg("host")), pods(), X.RAll{}), kcfg("host")),
    kcfg("far")), X.Spec.of(pods())])))

def late(m: Maybe<&2, String>) -> String:
  match m:
    case Some{k}:
      k
    case None{}:
      "-"

# Running reconciles by start time, for the watchdog.
def running() -> Map<&2, U32>:
  Map.set(&2, U32, Map.set(&2, U32, Map.new(&2, U32), "ns/a", 1000), "ns/b", 4000)

# A mapper: a ConfigMap of the first related watch names the primary in
# its data.for; any other watch's object names nothing.
def mapper.pick(one: Bool, +k: String) -> List<&2, String>:
  match one:
    case True{}:
      [k]
    case False{}:
      Nil{}

def mapper.go(+n: U32, +f: String, +idx: U32) -> List<&2, String>:
  mapper.pick(U32.is_eq(n, 1), "ns/" ++ f ++ "@" ++ U32.show(idx))

def mapper(n: U32, o: J.Json, c: X.Ctx) -> List<&2, String>:
  mapper.go(n, J.Json.str_or(J.Json.at(o, ["data", "for"]), ""), X.Ctx.idx(c))

def mspec() -> X.Spec:
  X.Spec.watches(X.Spec.of(C.Api{C.Res.config_maps(), C.InNs{"ns"}}), C.Api{C.Res.config_maps(), C.InNs{"ns"}}, X.RMap{})

def ref_cm(+name: String, +f: String) -> J.Json:
  J.Json.obj([J.KV{"metadata", J.Json.obj([J.KV{"name", J.JStr{name}}, J.KV{"namespace", J.JStr{"ns"}},
    J.KV{"resourceVersion", J.JStr{"1"}}])}, J.KV{"data", J.Json.obj([J.KV{"for", J.JStr{f}}])}])

def show_bool(b: Bool) -> String:
  match b:
    case True{}:
      "queued"
    case False{}:
      "not queued"

def map_line.of(r: R.CState & List<&2, Q.Timer>) -> String:
  match r:
    case (R.CState{s, cs, +q, x, p, t, mq}, ts):
      "a: " ++ show_bool(Q.Queue.waiting(q, "ns/a@0")) ++ ", b: " ++ show_bool(Q.Queue.waiting(q, "ns/b@0"))
        ++ ", pending left: " ++ Nat.show(List.length(&2, X.Mapped, mq))

# A related object moved from primary a to b: both reconcile, through the
# mapper, after the batch; the pending objects are then gone.
def map_line(+c: R.CCtx) -> String:
  map_line.of(R.Ctl.mapped(~mapper, R.Ctl.on_msg(R.Ctl.at(
    st(R.Ctl.mapped(~mapper, R.Ctl.on_msg(R.Ctl.at(R.CState{S.Store.new(), [S.Store.new()], Q.Queue.new(8),
      R.Stats{0, 0, 0, R.Hist.zero(), R.Sum{0, 0}}, None{}, R.Tim.new(), Nil{}}, 10),
      R.MOuts{1, [W.OApply{ref_cm("r", "a")}]}, mspec()), c)), 20),
    R.MOuts{1, [W.OApply{ref_cm("r", "b")}]}, mspec()), c))

def pending(r: R.CState & List<&2, Q.Timer>) -> String:
  match r:
    case (R.CState{s, cs, q, x, p, t, mq}, ts):
      Nat.show(List.length(&2, X.Mapped, mq))

# The second batch hands the mapper the object as it is and as it was cached.
def map_pending(+c: R.CCtx) -> String:
  "first batch " ++ pending(R.Ctl.on_msg(R.Ctl.at(R.CState{S.Store.new(), [S.Store.new()], Q.Queue.new(8),
      R.Stats{0, 0, 0, R.Hist.zero(), R.Sum{0, 0}}, None{}, R.Tim.new(), Nil{}}, 10),
      R.MOuts{1, [W.OApply{ref_cm("r", "a")}]}, mspec()))
    ++ ", second " ++ pending(R.Ctl.on_msg(R.Ctl.at(
    st(R.Ctl.mapped(~mapper, R.Ctl.on_msg(R.Ctl.at(R.CState{S.Store.new(), [S.Store.new()], Q.Queue.new(8),
      R.Stats{0, 0, 0, R.Hist.zero(), R.Sum{0, 0}}, None{}, R.Tim.new(), Nil{}}, 10),
      R.MOuts{1, [W.OApply{ref_cm("r", "a")}]}, mspec()), c)), 20),
    R.MOuts{1, [W.OApply{ref_cm("r", "b")}]}, mspec()))

def map_report(+c: R.CCtx) -> String:
  "mapped relation: " ++ map_line(c) ++ "; objects for the mapper: " ++ map_pending(c)

def ca_of(r: Result<&2, &2, String, K.Config>) -> String:
  match r:
    case Done{K.Config{h, p, b, ca, cert, key, tok, ns, pl, lm, sn, fc}}:
      K.Src.ident(ca)
    case Fail{e}:
      "fail: " ++ e

def js.of(r: Result<&2, &2, String, J.Json>) -> J.Json:
  match r:
    case Done{j}:
      j
    case Fail{e}:
      J.JStr{"bad json: " ++ e}

def kc(+ca: String) -> J.Json:
  js.of(J.Json.parse("{\"current-context\": \"c\", \"contexts\": [{\"name\": \"c\", \"context\": {\"cluster\": \"k\", \"user\": \"u\"}}], \"clusters\": [{\"name\": \"k\", \"cluster\": {\"server\": \"https://h:6443\"" ++ ca ++ "}}], \"users\": [{\"name\": \"u\", \"user\": {}}]}"))

def main() -> IO(Unit):
  # One slot. Three keys are queued; the first two are gone from the cache
  # (their objects deleted), the third is live: dispatch must reach it.
  +listed = planned(msg(state(1), R.MOuts{0, [W.OInit{}, W.OInitApply{cm("live")}, W.OInitDone{}]}, 1000, 1))
  +gone = with_queue(store_of(listed))
  # Requeues: a key asks for 60s, then 30s (earlier: a new wake), then 90s
  # (later: keeps the 30s wake, takes the newer generation).
  +run0 = dispatched(R.Ctl.dispatch(listed))
  +s1 = planned(msg(run0, R.MDone{"ns/live", Q.Requeue{60000}, 5}, 1000, 1))
  +run1 = dispatched(R.Ctl.dispatch(planned(msg(s1, R.MOuts{0, [W.OApply{cm("live")}]}, 2000, 1))))
  +s2 = planned(msg(run1, R.MDone{"ns/live", Q.Requeue{30000}, 5}, 3000, 1))
  +run2 = dispatched(R.Ctl.dispatch(planned(msg(s2, R.MOuts{0, [W.OApply{cm("live")}]}, 4000, 1))))
  +s3 = planned(msg(run2, R.MDone{"ns/live", Q.Requeue{90000}, 5}, 5000, 1))
  # The 61000 sleeper wakes: stale (the key's wake is 33000), so nothing
  # runs; the 33000 one fires and the key runs.
  +stale = st(R.Ctl.on_wake(s3, "ns/live", 61000))
  +fired = st(R.Ctl.on_wake(s3, "ns/live", 33000))
  # A relist in two pages after an outage: a new object on the first page
  # must not run (and be dropped) before the second page swaps the cache in.
  +page1 = planned(msg(listed, R.MOuts{0, [W.OInit{}, W.OInitApply{cm("new")}]}, 6000, 1))
  +page2 = planned(msg(dispatched(R.Ctl.dispatch(page1)),
    R.MOuts{0, [W.OInitApply{cm("live")}, W.OInitDone{}]}, 7000, 1))
  do IO<Unit>:
    IO.print("relist page 1 of 2 (new object): runs " ++ jobs(R.Ctl.dispatch(page1)))
    IO.print("relist page 2 of 2 (swap): runs " ++ jobs(R.Ctl.dispatch(page2))
      ++ "; ns/new waits its turn (one slot): " ++ Bool.show(waits(dispatched(R.Ctl.dispatch(page2)), "ns/new")))
    IO.print("dispatch with gone keys ahead of a live one: " ++ jobs(R.Ctl.dispatch(gone)))
    IO.print("requeue 60s at t=1000: sleeper " ++ sleeps(msg(run0, R.MDone{"ns/live", Q.Requeue{60000}, 5}, 1000, 1)))
    IO.print("requeue 30s at t=3000: sleeper " ++ sleeps(msg(run1, R.MDone{"ns/live", Q.Requeue{30000}, 5}, 3000, 1)))
    IO.print("requeue 90s at t=5000: sleeper " ++ sleeps(msg(run2, R.MDone{"ns/live", Q.Requeue{90000}, 5}, 5000, 1)))
    IO.print("stale sleeper wakes: runs " ++ jobs(R.Ctl.dispatch(stale)))
    IO.print("the key's own sleeper wakes: runs " ++ jobs(R.Ctl.dispatch(fired)))
    IO.print("watch ends whole: " ++ end(H.Resp{H.PDone{}, None{}, Nil{}}))
    IO.print("watch cut mid-stream: " ++ end(H.Resp{H.PErr{"connection closed mid-response"}, None{}, Nil{}}))
    IO.print("watch closed before answering: " ++ end(H.Resp{H.PLost{"closed"}, None{}, Nil{}}))
    IO.print("own metrics:\n" ++ R.Meter.render(
      Map.set(&2, U32, Map.set(&2, U32, Map.set(&2, U32, Map.new(&2, U32), "syncs_total{b=\"a\"}", 3),
        "syncs_total{b=\"c\"}", 1), "keys", 2),
      Map.set(&2, U32, Map.set(&2, U32, Map.new(&2, U32), "syncs_total", 0), "keys", 1)))
    IO.print("a 429 naming its delay: " ++ failed(429, "{\"kind\": \"Status\", \"code\": 429, \"reason\": \"TooManyRequests\", \"message\": \"slow down\", \"details\": {\"retryAfterSeconds\": 7}}"))
    IO.print("a proxy's 429, Retry-After: 4 and a text body: " ++ failed_h(429, "Too Many Requests", 4))
    IO.print("a Retry-After of 99999999s, capped: " ++ failed_h(429, "Too Many Requests", 99999999))
    IO.print("a 500 without one: " ++ failed(500, "{\"kind\": \"Status\", \"code\": 500, \"reason\": \"InternalError\", \"message\": \"boom\"}"))
    IO.print("tokens in the first second (a fraction carries over) at qps 1, 3, 7, 50, 75, 333, 1000: " ++ tokens(1, 100) ++ " "
      ++ tokens(3, 100) ++ " " ++ tokens(7, 100) ++ " " ++ tokens(50, 100) ++ " " ++ tokens(75, 100)
      ++ " " ++ tokens(333, 100) ++ " " ++ tokens(1000, 100))
    ch : Chan(R.Msg) <- Chan.new(R.Msg, 1)
    IO.print("watches across clusters:" ++ plan(ch))
    IO.print("pools for other clusters:" ++ pool_plan())
    IO.print("a server in logs: " ++ K.Config.server(K.Config.with_server_name(kcfg("10.0.0.1"), "kubernetes.default.svc")))
    IO.print("watchdog, 2s timeout: at 2500 " ++ late(R.Dog.late(running(), 2500, 2000)) ++ "; at 3001 "
      ++ late(R.Dog.late(running(), 3001, 2000)) ++ "; nothing running " ++ late(R.Dog.late(Map.new(&2, U32), 99999, 2000))
      ++ "; across the clock's wrap " ++ late(R.Dog.late(Map.set(&2, U32, Map.new(&2, U32), "ns/w", 4294967000), 500, 2000))
      ++ " then " ++ late(R.Dog.late(Map.set(&2, U32, Map.new(&2, U32), "ns/w", 4294967000), 2000, 2000)))
    mch : Chan(R.Msg) <- Chan.new(R.Msg, 1)
    sch : Chan(R.SMsg) <- Chan.new(R.SMsg, 1)
    mtr : Chan(X.Meter) <- Chan.new(X.Meter, 1)
    IO.print(map_report(R.CCtx{kcfg("main"), mspec(), mch, sch, 0, mtr, None{}}))
    IO.print("kubeconfig CA: bad base64 " ++ ca_of(K.Kube.config(kc(", \"certificate-authority-data\": \"%%%\""), ""))
      ++ "; good " ++ ca_of(K.Kube.config(kc(", \"certificate-authority-data\": \"cGVt\""), "")) ++ "; none " ++ ca_of(K.Kube.config(kc(""), "")))
