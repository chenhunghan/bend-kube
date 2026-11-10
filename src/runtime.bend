import Base
import ./json.bend as J
import ./utf8.bend as U
import ./http.bend as H
import ./core.bend as C
import ./config.bend as K
import ./net.bend as N
import ./client.bend as Cl
import ./watcher.bend as W
import ./store.bend as S
import ./queue.bend as Q
import ./log.bend as L
import ./control.bend as X
import ./time.bend as T
import ./sys.bend as Y

# Runtime
# =======
#
# kube-runtime's Controller in Bend. Watchers run as their own IO
# computations and send what they see to one channel; the controller loop
# owns the store and the queue (both pure values), starts reconciles as
# concurrent computations, and arms timers, all of which answer on the
# same channel. Every decision is made by the pure modules (watcher.bend,
# store.bend, queue.bend); this file only performs them.
#
# Loops count down a nested fuel (2^64 steps, lazily), so they terminate by
# structure; at a million steps a second that is over 500,000 years. A loop
# that ever ran out would exit the process (Loop.spent), never idle.

type Msg is Data:
  MOuts{src: U32, outs: List<&2, W.Out>}
  MDone{key: String, act: Q.Action, ms: U32}
  MWake{key: String, at: U32}
  MStop{reply: Chan(Unit)}
  MTick{}

# The controller's state as the health server reports it.
type Snap is Data:
  Snap{name: String, ready: Bool, reconciles: U32, errors: U32, events: U32, running: U32,
    objects: U32, queued: U32, hist: List<&2, U32>, sum: Sum, cached: List<&2, U32>}

# The status keeper's inbox: a controller's latest snapshot (by its index),
# or a query for all of them (none until a controller runs: a standby
# replica).
type SMsg is Data:
  SPut{idx: U32, snap: Snap}
  SGet{reply: Chan(List<&2, Snap>)}

# A total of milliseconds, as whole seconds and the rest, so it lasts
# 136 years rather than 49 days.
type Sum is Data:
  Sum{secs: U32, ms: U32}

def Sum.add(x: Sum, +ms: U32) -> Sum:
  match x:
    case Sum{s, +m}:
      Sum{(s + ms / 1000 + (m + ms % 1000) / 1000 : U32), ((m + ms % 1000) % 1000 : U32)}

def Sum.sane.go(+ms: U32, ok: Bool) -> U32:
  match ok:
    case True{}:
      ms
    case False{}:
      0

# A duration of a day or more (a sleeping laptop) counts as 0.
def Sum.sane(+ms: U32) -> U32:
  Sum.sane.go(ms, U32.is_lt(ms, 86400000))

# Counters since start; hist counts reconciles by duration (Hist.bounds),
# sum is their total time.
type Stats is Data:
  Stats{reconciles: U32, errors: U32, events: U32, hist: List<&2, U32>, sum: Sum}

# A loop that used up its steps (2^64: never, in practice) exits, so the
# pod restarts, rather than leaving the process up and idle.
def Loop.spent(name: String) -> IO(Unit):
  IO.bind(Unit, Unit, L.Log.error("loop out of steps; exiting", [L.Log.kv("loop", name)]),
    u => IO.exit(1))

# Watcher driver
# --------------

# Who a watcher feeds: each subscriber's inbox, and the source number the
# outputs carry there (0 for a controller's primary, 1.. for its owned).
type Sub is Data:
  Sub{chan: Chan(Msg), src: U32}

type WCtx is Data:
  WCtx{cfg: K.Config, api: C.Api, label: String, field: String, subs: List<&2, Sub>}

# What the driver just saw.
type DEv is Type:
  DStart{}
  DListed{r: Result<&2, &2, Cl.KErr, J.Json>}
  DOpened{r: Result<&1, &1, U32 & String, N.Tls>}
  DRecv{sock: Socket, r: Result<&1, &1, U32 & String, List<&2, U32>>}
  DDig{sock: Socket, dig: Dig}
  DStepped{step: W.Step, sock: Maybe<&1, Socket>, more: Bool}
  DNext{sock: Maybe<&1, Socket>, wait: Bool, more: Bool}

def DEv.recv(p: Socket & Result<&1, &1, U32 & String, List<&2, U32>>) -> DEv:
  match p:
    case (s, r):
      DRecv{s, r}

# The inputs a run of watch lines makes; blank lines are skipped.
def Drv.inputs(ls: List<&2, List<&2, U32>>) -> List<&2, W.Input>:
  match ls:
    case Nil{}:
      Nil{}
    case Con{Nil{}, t}:
      Drv.inputs(t)
    case Con{l, t}:
      W.IEvent{C.WEvent.parse(U.Utf8.decode_all(l))} <> Drv.inputs(t)

# The same, with the lines decoded and parsed in parallel: each line is
# its own JSON document, so the halves split (to depth levels, up to 2^depth
# tasks) run as Bend parallel calls, on every core.
def Drv.inputs.par(+depth: Nat, +ls: List<&2, List<&2, U32>>) -> List<&2, W.Input>:
  match depth:
    case 0n:
      Drv.inputs(ls)
    case 1n+d:
      +half = Nat.div(List.length(&2, List<&2, U32>, ls), 2n)
      a b = Drv.inputs.par(d, List.take(&2, List<&2, U32>, ls, half)) Drv.inputs.par(d, List.drop(&2, List<&2, U32>, ls, half))
      List.append(&2, W.Input, a, b)

# After a recv: the stream's state, and the step its whole lines make.
type Dig is Data:
  Dig{step: W.Step, resp: H.Resp, carry: List<&2, U32>, more: Bool}

def Drv.status(r: H.Resp) -> U32:
  match r:
    case H.Resp{p, Some{H.Head{c, reason, hs}}, o}:
      c
    case _:
      200

def Drv.ended(r: H.Resp) -> Bool:
  match r:
    case H.Resp{H.PDone{}, h, o}:
      True{}
    case H.Resp{H.PErr{m}, h, o}:
      True{}
    case H.Resp{H.PLost{m}, h, o}:
      True{}
    case _:
      False{}

# How a watch stream ended: a whole response (the server's timeout) is an
# orderly end, resumed at once; a cut-off or broken one (a server or load
# balancer closing mid-stream or before answering) is a failure, which
# backs off, so a flapping server is not hammered.
def Drv.end_input(r: H.Resp) -> W.Input:
  match r:
    case H.Resp{H.PDone{}, h, o}:
      W.IWatchEnd{}
    case _:
      W.IWatchErr{0}

def Drv.digest.end.go(st: W.WState, outs: List<&2, W.Out>, +wait: Bool, +r: H.Resp,
  carry: List<&2, U32>, +end: Bool) -> Dig:
  match wait end:
    case True{} True{}:
      # already backing off (an error event came first): the end changes
      # nothing, so the failure count and the backoff stand
      Dig{W.Step{st, outs, True{}}, r, carry, False{}}
    case False{} True{}:
      Dig{W.Watcher.merge(W.Step{st, outs, False{}}, Drv.end_input(r)), r, carry, False{}}
    case w False{}:
      Dig{W.Step{st, outs, w}, r, carry, Bool.not(w)}

# A stream that ended cleanly is a watch timeout: the watcher resumes.
def Drv.digest.end(s: W.Step, r: H.Resp, carry: List<&2, U32>, +end: Bool) -> Dig:
  match s:
    case W.Step{st, outs, +wait}:
      Drv.digest.end.go(st, outs, wait, r, carry, end)

def Drv.digest.fin(st: W.WState, r: H.Resp, cl: List<&2, U32> & List<&2, List<&2, U32>>,
  +end: Bool) -> Dig:
  match cl:
    case (carry, lines):
      Drv.digest.end(W.Watcher.steps(Drv.inputs.par(3n, lines), W.Step{st, Nil{}, False{}}), r,
        carry, end)

def Drv.digest.lines(st: W.WState, rb: H.Resp & List<&2, U32>, carry: List<&2, U32>, +eof: Bool) ->
  Dig:
  match rb:
    case (+r, body):
      Drv.digest.fin(st, r, H.Lines.split(carry, body), Bool.or(eof, Drv.ended(r)))

def Drv.digest.ok(st: W.WState, r: H.Resp, carry: List<&2, U32>, +eof: Bool, +code: U32,
  ok: Bool) -> Dig:
  match ok:
    case True{}:
      Drv.digest.lines(st, H.Http.take(r), carry, eof)
    case False{}:
      Dig{W.Watcher.step(st, W.IWatchErr{code}), H.Http.resp.init(), Nil{}, False{}}

def Drv.digest.go(st: W.WState, r: H.Resp, carry: List<&2, U32>, +eof: Bool, +code: U32) -> Dig:
  Drv.digest.ok(st, r, carry, eof, code, U32.is_eq(code, 200))

def Drv.digest(st: W.WState, +r: H.Resp, carry: List<&2, U32>, +eof: Bool) -> Dig:
  Drv.digest.go(st, r, carry, eof, Drv.status(r))

def Drv.send(chan: Chan(Msg), +src: U32, outs: List<&2, W.Out>) -> IO(Unit):
  match outs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case xs:
      IO.bind(Result<&1, &1, Msg, Unit>, Unit, Chan.send(Msg, chan, MOuts{src, xs}),
        r => IO.pure(Unit, Unit{}))

# Hands the outputs to every subscriber (a shared watch fans out).
def Drv.send_all(subs: List<&2, Sub>, +outs: List<&2, W.Out>) -> IO(Unit):
  match subs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{Sub{ch, src}, t}:
      IO.bind(Unit, Unit, Drv.send(ch, src, outs), u => Drv.send_all(t, outs))

def Drv.jitter(+ms: U32, r: Result<&1, &1, U32 & String, U32>) -> U32:
  match r:
    case Done{x}:
      (ms + (x % ((ms >> 1n) + 1)) : U32)
    case Fail{e}:
      ms

def Drv.pause.go(+ms: U32, +fails: U32, path: String) -> IO(Unit):
  IO.bind(Unit, Unit, L.Log.warn("list or watch failed; backing off",
    [L.Log.kv("path", path), L.Log.kv("failures", U32.show(fails)),
      L.Log.kv("delay_ms", U32.show(ms))]), u => IO.sleep(ms))

# Sleeps the watcher's backoff, with up to 50% jitter, when asked to.
def Drv.pause(wait: Bool, +fails: U32, path: String) -> IO(Unit):
  match wait:
    case True{}:
      IO.bind(Result<&1, &1, U32 & String, U32>, Unit, IO.random_u32(),
        r => Drv.pause.go(Drv.jitter(W.Backoff.delay(fails), r), fails, path))
    case False{}:
      IO.pure(Unit, Unit{})

# A list from its first page (startup, or a relist after 410 Gone).
def Drv.note_list(first: Bool, path: String) -> IO(Unit):
  match first:
    case True{}:
      L.Log.info("listing", [L.Log.kv("path", path)])
    case False{}:
      IO.pure(Unit, Unit{})

def Drv.why(e: U32 & String) -> String:
  match e:
    case (c, m):
      m

def Drv.close(s: Maybe<&1, Socket>) -> IO(Unit):
  match s:
    case Some{x}:
      N.Tls.close(x)
    case None{}:
      IO.pure(Unit, Unit{})

def WState.fails(s: W.WState) -> U32:
  match s:
    case W.WState{p, f, first}:
      f

def WCtx.list_req(c: WCtx, cont: String) -> H.Req:
  match c:
    case WCtx{cfg, api, l, fs, subs}:
      C.Req.list(api, C.ListParams{l, fs, 500, cont, ""})

def WCtx.watch_req(c: WCtx, rv: String) -> H.Req:
  match c:
    case WCtx{cfg, api, l, fs, subs}:
      C.Req.watch(api, C.WatchParams{l, fs, 290, True{}}, rv)

def WCtx.path(c: WCtx) -> String:
  match c:
    case WCtx{cfg, api, l, fs, subs}:
      C.Api.path(api)

def WCtx.cfg(c: WCtx) -> K.Config:
  match c:
    case WCtx{cfg, api, l, fs, subs}:
      cfg

def WCtx.subs(c: WCtx) -> List<&2, Sub>:
  match c:
    case WCtx{cfg, api, l, fs, subs}:
      subs

# The watcher's loop: list, then watch and stream, reconnecting and
# relisting as the state machine says, until the fuel or the channel ends.
def Drv.run(outer: Nat, fuel: Nat, ev: DEv, +st: W.WState, +resp: H.Resp, +carry: List<&2, U32>,
  +ctx: WCtx) -> IO(Unit):
  match outer fuel ev:
    case 0n 0n e:
      Loop.spent("Drv.run")
    case 1n+o 0n e:
      Drv.run(o, 4294967295n, e, st, resp, carry, ctx)
    case o 1n+f DStart{}:
      match st:
        case W.WState{W.WList{+c}, +fl, +first}:
          IO.bind(Unit, Unit, Drv.note_list(first, WCtx.path(ctx)),
            u => IO.bind(Result<&2, &2, Cl.KErr, J.Json>, Unit,
              Cl.Client.json(WCtx.cfg(ctx), WCtx.list_req(ctx, c)),
              r => Drv.run(o, f, DListed{r}, W.WState{W.WList{c}, fl, first}, resp, carry, ctx)))
        case W.WState{W.WWatch{+rv}, +fl, +first}:
          IO.bind(Result<&1, &1, U32 & String, N.Tls>, Unit,
            Cl.Conn.open(WCtx.cfg(ctx), WCtx.watch_req(ctx, rv), False{}),
            r => Drv.run(o, f, DOpened{r}, W.WState{W.WWatch{rv}, fl, first}, resp, carry, ctx))
    case o 1n+f DListed{Done{+j}}:
      Drv.run(o, f, DStepped{W.Watcher.step(st, W.IPage{C.Page.of(j)}), None{}, False{}}, st, resp,
        carry, ctx)
    case o 1n+f DListed{Fail{+e}}:
      IO.bind(Unit, Unit, L.Log.warn("list failed",
        [L.Log.kv("path", WCtx.path(ctx)), L.Log.kv("error", Cl.KErr.show(e))]),
        u => Drv.run(o, f, DStepped{W.Watcher.step(st, W.IListErr{Cl.KErr.code(e)}), None{}, False{}}, st,
          resp, carry, ctx))
    case o 1n+f DOpened{Done{N.Tls{s}}}:
      IO.bind(Socket & Result<&1, &1, U32 & String, List<&2, U32>>, Unit,
        N.Tls.recv(s, 65536, 350000),
        p => Drv.run(o, f, DEv.recv(p), st, H.Http.resp.init(), Nil{}, ctx))
    case o 1n+f DOpened{Fail{e}}:
      IO.bind(Unit, Unit, L.Log.warn("watch failed to open",
        [L.Log.kv("path", WCtx.path(ctx)), L.Log.kv("error", Drv.why(e))]),
        u => Drv.run(o, f, DStepped{W.Watcher.step(st, W.IWatchErr{0}), None{}, False{}}, st, resp, carry,
          ctx))
    case o 1n+f DRecv{s, Done{+bs}}:
      Drv.run(o, f, DDig{s, Drv.digest(st, H.Http.feed(bs, resp), carry,
        List.is_empty(&2, U32, bs))}, st, resp, carry, ctx)
    case o 1n+f DDig{s, Dig{step, r2, c2, more}}:
      Drv.run(o, f, DStepped{step, Some{s}, more}, st, r2, c2, ctx)
    case o 1n+f DRecv{s, Fail{e}}:
      IO.bind(Unit, Unit, L.Log.warn("watch read failed",
        [L.Log.kv("path", WCtx.path(ctx)), L.Log.kv("error", Drv.why(e))]),
        u => Drv.run(o, f, DStepped{W.Watcher.step(st, W.IWatchErr{0}), Some{s}, False{}}, st, resp,
          carry, ctx))
    case o 1n+f DStepped{W.Step{st2, outs, wait}, s, more}:
      IO.bind(Unit, Unit, Drv.send_all(WCtx.subs(ctx), outs),
        u => Drv.run(o, f, DNext{s, wait, more}, st2, resp, carry, ctx))
    case o 1n+f DNext{Some{s}, False{}, True{}}:
      IO.bind(Socket & Result<&1, &1, U32 & String, List<&2, U32>>, Unit,
        N.Tls.recv(s, 65536, 350000), p => Drv.run(o, f, DEv.recv(p), st, resp, carry, ctx))
    case o 1n+f DNext{s, wait, more}:
      IO.bind(Unit, Unit, Drv.close(s),
        u => IO.bind(Unit, Unit, Drv.pause(wait, WState.fails(st), WCtx.path(ctx)),
          u2 => Drv.run(o, f, DStart{}, st, H.Http.resp.init(), Nil{}, ctx)))

# Controller
# ----------
#
# A controller's loop owns its caches (the primary's and one per related
# watch) and its queue, all pure values. A batch of watcher outputs is
# folded into its cache by control.bend, which says which keys it
# triggers; reconciles start once every cache has listed, each with a
# snapshot of the caches (X.Ctx). A stop request (MStop) starts no more
# reconciles and is answered once the running ones finish.

# The controller's clock: each key's pending wake (its deadline in wall
# ms, and the queue generation it carries), the time of the message being
# handled, when a status snapshot was last published (and its readiness),
# whether anything happened since, whether a publish tick is pending, and
# which watches (by source number) are midway through a relist.
type Tim is Data:
  Tim{at: Map<&2, U32>, gen: Map<&2, U32>, now: U32, snap: U32, ready: Bool, dirty: Bool, tick: Bool,
    relist: Map<&2, U32>}

def Tim.new() -> Tim:
  Tim{Map.new(&2, U32), Map.new(&2, U32), 0, 0, False{}, False{}, False{}, Map.new(&2, U32)}

type CState is Data:
  CState{store: S.Store, caches: List<&2, S.Store>, queue: Q.Queue, stats: Stats,
    stop: Maybe<&2, Chan(Unit)>, tim: Tim}

type CCtx is Data:
  CCtx{cfg: K.Config, spec: X.Spec, chan: Chan(Msg), status: Chan(SMsg), idx: U32,
    meter: Chan(X.Meter)}

# A reconcile to start: the key and the object the store holds for it.
type Job is Data:
  Job{key: String, obj: J.Json, fails: U32}

# What the controller loop just saw.
type CEv is Type:
  CMsg{m: Maybe<&1, Msg>}
  CTimed{m: Msg, now: U32}
  CHandled{r: CState & List<&2, Sleep>}
  CDisp{r: CState & List<&2, Job>}
  CNext{halt: Maybe<&2, Chan(Unit)>}
  CPeek{p: Poll<&1, &1, Maybe<&1, Msg>, Unit>}

def Caches.nth(cs: List<&2, S.Store>, n: Nat) -> S.Store:
  match cs n:
    case Nil{} k:
      S.Store.new()
    case Con{s, t} 0n:
      s
    case Con{s, t} 1n+k:
      Caches.nth(t, k)

def Caches.set(cs: List<&2, S.Store>, n: Nat, x: S.Store) -> List<&2, S.Store>:
  match cs n:
    case Nil{} k:
      Nil{}
    case Con{s, t} 0n:
      x <> t
    case Con{s, t} 1n+k:
      s <> Caches.set(t, k, x)

def Caches.sizes(cs: List<&2, S.Store>) -> List<&2, U32>:
  match cs:
    case Nil{}:
      Nil{}
    case Con{c, t}:
      U32.from_nat(S.Store.size(c)) <> Caches.sizes(t)

def Caches.ready(cs: List<&2, S.Store>) -> Bool:
  match cs:
    case Nil{}:
      True{}
    case Con{s, t}:
      Bool.and(S.Store.ready(s), Caches.ready(t))

def Secs.drop(ss: List<&2, X.Sec>, n: Nat) -> List<&2, String>:
  match ss n:
    case Nil{} k:
      Nil{}
    case Con{s, t} 0n:
      X.Sec.drop(s)
    case Con{s, t} 1n+k:
      Secs.drop(t, k)

def Secs.preds(ss: List<&2, X.Sec>, n: Nat) -> List<&2, X.Pred>:
  match ss n:
    case Nil{} k:
      Nil{}
    case Con{s, t} 0n:
      X.Sec.preds(s)
    case Con{s, t} 1n+k:
      Secs.preds(t, k)

def Secs.rel(ss: List<&2, X.Sec>, n: Nat) -> X.Rel:
  match ss n:
    case Nil{} k:
      X.ROwner{}
    case Con{s, t} 0n:
      X.Sec.rel(s)
    case Con{s, t} 1n+k:
      Secs.rel(t, k)

# Histogram
# ---------

# Reconcile durations: upper bounds in ms, as Prometheus' default buckets
# (5ms to 10s); the last count is everything slower.
def Hist.bounds() -> List<&2, U32>:
  [5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000]

def Hist.zero() -> List<&2, U32>:
  [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0]

# Whether ms falls in the first bucket of bs (the overflow when none is left).
def Hist.fits(bs: List<&2, U32>, +ms: U32) -> Bool:
  match bs:
    case Con{b, t}:
      U32.is_le(ms, b)
    case Nil{}:
      True{}

def Hist.bump.go(cs: List<&2, U32>, bs: List<&2, U32>, +ms: U32, hit: Bool) -> List<&2, U32>:
  match cs bs hit:
    case Con{+c, t} b True{}:
      (c + 1 : U32) <> t
    case Con{c, t} Con{b, +bt} False{}:
      c <> Hist.bump.go(t, bt, ms, Hist.fits(bt, ms))
    case Con{+c, t} Nil{} False{}:
      (c + 1 : U32) <> t
    case Nil{} b h:
      Nil{}

def Hist.bump(cs: List<&2, U32>, +ms: U32) -> List<&2, U32>:
  Hist.bump.go(cs, Hist.bounds(), ms, Hist.fits(Hist.bounds(), ms))

# Folding
# -------

def Stats.events(x: Stats, +n: U32) -> Stats:
  match x:
    case Stats{r, e, +v, h, sm}:
      Stats{r, e, (v + n : U32), h, sm}

def Stats.done(x: Stats, a: Q.Action, +ms: U32) -> Stats:
  match x a:
    case Stats{+r, +e, v, h, +sm} Q.Retry{m}:
      Stats{(r + 1 : U32), (e + 1 : U32), v, Hist.bump(h, Sum.sane(ms)), Sum.add(sm, Sum.sane(ms))}
    case Stats{+r, +e, v, h, +sm} Q.RetryIn{m, d}:
      Stats{(r + 1 : U32), (e + 1 : U32), v, Hist.bump(h, Sum.sane(ms)), Sum.add(sm, Sum.sane(ms))}
    case Stats{+r, e, v, h, +sm} _:
      Stats{(r + 1 : U32), e, v, Hist.bump(h, Sum.sane(ms)), Sum.add(sm, Sum.sane(ms))}

def Ctl.prim.put(cs: List<&2, S.Store>, q: Q.Queue, x: Stats, p: Maybe<&2, Chan(Unit)>, tm: Tim,
  f: X.Fold) -> CState:
  match f:
    case X.Fold{s, ks, g}:
      CState{s, cs, Q.Queue.forget_all(g, Q.Queue.add_all(ks, q)), x, p, tm}

def Ctl.rel.put(+n: Nat, s: S.Store, cs: List<&2, S.Store>, q: Q.Queue, x: Stats,
  p: Maybe<&2, Chan(Unit)>, tm: Tim, f: X.Fold) -> CState:
  match f:
    case X.Fold{c, ks, g}:
      CState{s, Caches.set(cs, n, c), Q.Queue.add_all(ks, q), x, p, tm}

# Outputs of watch src: the primary's (0) through its predicates, a related
# watch's (n) through its relation.
# Whether a watch is midway through a relist after a batch of its outputs:
# Init opens one, InitDone closes it.
def Relist.after(os: List<&2, W.Out>, open: Bool) -> Bool:
  match os:
    case Nil{}:
      open
    case Con{W.OInit{}, t}:
      Relist.after(t, True{})
    case Con{W.OInitDone{}, t}:
      Relist.after(t, False{})
    case Con{o, t}:
      Relist.after(t, open)

def Relist.mark(st: CState, +src: U32, open: Bool) -> CState:
  match st open:
    case CState{s, cs, q, x, p, Tim{at, gen, n, sn, rd, dt, tk, +rl}} True{}:
      CState{s, cs, q, x, p, Tim{at, gen, n, sn, rd, dt, tk, Q.Mp.on(rl, U32.show(src))}}
    case CState{s, cs, q, x, p, Tim{at, gen, n, sn, rd, dt, tk, +rl}} False{}:
      CState{s, cs, q, x, p, Tim{at, gen, n, sn, rd, dt, tk, Q.Mp.off(rl, U32.show(src))}}

def Relist.open(st: CState, +src: U32) -> Bool:
  match st:
    case CState{s, cs, q, x, p, Tim{at, gen, n, sn, rd, dt, tk, +rl}}:
      Q.Mp.has(rl, U32.show(src))

# Whether any watch is midway through a relist: its cache still holds the
# old list, so no reconcile may start (a key from an early page would be
# looked up in the old cache and dropped).
def Relist.any(st: CState) -> Bool:
  match st:
    case CState{s, cs, q, x, p, Tim{at, gen, n, sn, rd, dt, tk, rl}}:
      Bool.not(List.is_empty(&2, String, Map.keys(&2, U32, rl)))

def Ctl.on_outs.fold(st: CState, +src: U32, +outs: List<&2, W.Out>, +spec: X.Spec, own: Bool) -> CState:
  match st own:
    case CState{s, cs, q, x, p, tm} True{}:
      Ctl.prim.put(cs, q, Stats.events(x, U32.from_nat(List.length(&2, W.Out, outs))), p, tm,
        X.Fold.prim(X.Spec.preds(spec), outs, X.Fold{s, Nil{}, Nil{}}))
    case CState{+s, +cs, q, x, p, tm} False{}:
      Ctl.rel.put(U32.to_nat((src - 1 : U32)), s, cs, q,
        Stats.events(x, U32.from_nat(List.length(&2, W.Out, outs))), p, tm,
        X.Fold.rel_where(Secs.rel(X.Spec.secs(spec), U32.to_nat((src - 1 : U32))),
          Secs.preds(X.Spec.secs(spec), U32.to_nat((src - 1 : U32))), X.Spec.res(spec),
          X.Out.trim_all(Secs.drop(X.Spec.secs(spec), U32.to_nat((src - 1 : U32))), outs), s,
          X.Fold{Caches.nth(cs, U32.to_nat((src - 1 : U32))), Nil{}, Nil{}}))

# Outputs of watch src, folded (Ctl.on_outs.fold), with its relist state.
def Ctl.on_outs(+st: CState, +src: U32, +outs: List<&2, W.Out>, +spec: X.Spec, own: Bool) -> CState:
  Relist.mark(Ctl.on_outs.fold(st, src, outs, spec, own), src, Relist.after(outs, Relist.open(st, src)))

def Ctl.on_done(s: S.Store, cs: List<&2, S.Store>, x: Stats, p: Maybe<&2, Chan(Unit)>, tm: Tim,
  r: Q.Queue & List<&2, Q.Timer>) -> CState & List<&2, Q.Timer>:
  match r:
    case (q, ts):
      (CState{s, cs, q, x, p, tm}, ts)

# A finished key whose object is gone (deleted while it ran or waited) is
# forgotten, so the queue keeps nothing for it.
def Ctl.forget_gone(r: Q.Queue & List<&2, Q.Timer>, +key: String, gone: Bool) ->
  Q.Queue & List<&2, Q.Timer>:
  match r gone:
    case (q, ts) True{}:
      (Q.Queue.forget(q, key), Nil{})
    case x False{}:
      x

def Ctl.cached(m: Maybe<&2, J.Json>) -> Bool:
  match m:
    case Some{x}:
      True{}
    case None{}:
      False{}

def Ctl.on_done.st(st: CState, +key: String, +a: Q.Action, +ms: U32) ->
  CState & List<&2, Q.Timer>:
  match st:
    case CState{+s, cs, q, x, p, tm}:
      Ctl.on_done(s, cs, Stats.done(x, a, ms), p, tm,
        Ctl.forget_gone(Q.Queue.done(q, key, a), key, Bool.not(Ctl.cached(S.Store.get(s, key)))))

def Ctl.on_wake.go(st: CState, +key: String, mine: Bool) -> CState & List<&2, Q.Timer>:
  match st mine:
    case CState{s, cs, q, x, p, Tim{+at, +gen, n, sn, rd, dt, tk, rl}} True{}:
      (CState{s, cs, Q.Queue.wake(q, key, Q.Mp.get(gen, key)), x, p,
        Tim{Q.Mp.off(at, key), Q.Mp.off(gen, key), n, sn, rd, dt, tk, rl}}, Nil{})
    case y False{}:
      (y, Nil{})

def Tim.at(st: CState) -> Map<&2, U32>:
  match st:
    case CState{s, cs, q, x, p, Tim{at, gen, n, sn, rd, dt, tk, rl}}:
      at

# A sleeper woke: if it is still the one for its key's pending wake (the
# same deadline), the wake fires with the latest generation; an older
# sleeper, outdone by an earlier wake, does nothing.
def Ctl.on_wake(+st: CState, +key: String, +due: U32) -> CState & List<&2, Q.Timer>:
  Ctl.on_wake.go(st, key, Bool.and(Q.Mp.has(Tim.at(st), key), U32.is_eq(Q.Mp.get(Tim.at(st), key), due)))

def Ctl.on_stop(st: CState, r: Chan(Unit)) -> CState & List<&2, Q.Timer>:
  match st:
    case CState{s, cs, q, x, p, tm}:
      (CState{s, cs, q, x, Some{r}, tm}, Nil{})

# A dispatch pass: the queue, the jobs to start, and whether a popped key
# was gone from the store (its slot freed, so another pass may start more).
type Disp is Data:
  Disp{queue: Q.Queue, jobs: List<&2, Job>, dropped: Bool}

def Ctl.ticked(st: CState) -> CState:
  match st:
    case CState{s, cs, q, x, p, Tim{at, gen, n, sn, rd, dt, tk, rl}}:
      CState{s, cs, q, x, p, Tim{at, gen, n, sn, rd, dt, False{}, rl}}

# Scheduling
# ----------
#
# kube-runtime's scheduler: a key has at most one pending wake, the
# earliest asked for. A timer the queue arms for a key that already waits
# for an earlier (or equal) wake only takes its generation; otherwise it
# becomes the key's wake, and one sleeper is started for it. A later or
# equal request starts no sleeper; only an earlier one does, and the one it
# outdoes wakes to nothing when its time comes. So a key holds a live
# sleeper only for each strictly earlier wake asked, never one per requeue.

# A sleeper to start: wake key after ms, naming its deadline.
type Sleep is Data:
  Sleep{key: String, due: U32, ms: U32}

# A message's effect on the state, and the timers it arms.
def Ctl.on_msg(st: CState, m: Msg, +spec: X.Spec) -> CState & List<&2, Q.Timer>:
  match m:
    case MOuts{+src, outs}:
      (Ctl.on_outs(st, src, outs, spec, U32.is_eq(src, 0)), Nil{})
    case MDone{key, a, ms}:
      Ctl.on_done.st(st, key, a, ms)
    case MWake{key, g}:
      Ctl.on_wake(st, key, g)
    case MStop{r}:
      Ctl.on_stop(st, r)
    case MTick{}:
      (Ctl.ticked(st), Nil{})

# Whether a pending deadline at is no later than now + ms (an overdue one,
# whose sleeper is about to fire, is earlier).
def Tim.sooner(+at: U32, +now: U32, +ms: U32) -> Bool:
  Bool.or(U32.is_le((at - now : U32), ms), U32.is_ge((at - now : U32), 2147483648))

def Tim.arm.go(t: Tim, +key: String, +g: U32, +ms: U32, pending: Bool, sooner: Bool,
  ss: List<&2, Sleep>) -> Tim & List<&2, Sleep>:
  match t pending sooner:
    case Tim{at, gen, +n, sn, rd, dt, tk, rl} True{} True{}:
      (Tim{at, Map.set(&2, U32, gen, key, g), n, sn, rd, dt, tk, rl}, ss)
    case Tim{at, gen, +n, sn, rd, dt, tk, rl} _ _:
      (Tim{Map.set(&2, U32, at, key, (n + ms : U32)), Map.set(&2, U32, gen, key, g), n, sn, rd, dt, tk, rl},
        Sleep{key, (n + ms : U32), ms} <> ss)

def Tim.arm(t: Tim, tm: Q.Timer, ss: List<&2, Sleep>) -> Tim & List<&2, Sleep>:
  match t tm:
    case Tim{+at, gen, +n, sn, rd, dt, tk, rl} Q.Timer{+key, g, +ms}:
      Tim.arm.go(Tim{at, gen, n, sn, rd, dt, tk, rl}, key, g, ms, Q.Mp.has(at, key),
        Tim.sooner(Q.Mp.get(at, key), n, ms), ss)

def Tim.arm.pair(r: Tim & List<&2, Sleep>, t: Q.Timer) -> Tim & List<&2, Sleep>:
  match r:
    case (tm, ss):
      Tim.arm(tm, t, ss)

def Tim.arm_all.go(ts: List<&2, Q.Timer>, r: Tim & List<&2, Sleep>) -> Tim & List<&2, Sleep>:
  match ts:
    case Nil{}:
      r
    case Con{t, rest}:
      Tim.arm_all.go(rest, Tim.arm.pair(r, t))

def Ctl.plan.put(s: S.Store, cs: List<&2, S.Store>, q: Q.Queue, x: Stats, p: Maybe<&2, Chan(Unit)>,
  r: Tim & List<&2, Sleep>) -> CState & List<&2, Sleep>:
  match r:
    case (tm, ss):
      (CState{s, cs, q, x, p, tm}, ss)

# The queue's timers become the keys' wakes, and the sleepers to start.
def Ctl.plan(r: CState & List<&2, Q.Timer>) -> CState & List<&2, Sleep>:
  match r:
    case (CState{s, cs, q, x, p, tm}, ts):
      Ctl.plan.put(s, cs, q, x, p, Tim.arm_all.go(ts, (tm, Nil{})))

# The state at a message's arrival: the clock reads now.
def Ctl.at(st: CState, +now: U32) -> CState:
  match st:
    case CState{s, cs, q, x, p, Tim{at, gen, n, sn, rd, dt, tk, rl}}:
      CState{s, cs, q, x, p, Tim{at, gen, now, sn, rd, True{}, tk, rl}}

def Ctl.dispatch.forget(r: Q.Queue & List<&2, Q.Timer>, +key: String) -> Q.Queue:
  match r:
    case (q, ts):
      Q.Queue.forget(q, key)

def Ctl.dispatch.put(+key: String, m: Maybe<&2, J.Json>, d: Disp) -> Disp:
  match m d:
    case Some{o} Disp{+q, jobs, dr}:
      Disp{q, Job{key, o, Q.Queue.fails(q, key)} <> jobs, dr}
    case None{} Disp{q, jobs, dr}:
      # gone from the store: nothing to reconcile, and nothing to remember
      Disp{Ctl.dispatch.forget(Q.Queue.done(q, key, Q.AwaitChange{}), key), jobs, True{}}

def Ctl.dispatch.go(ks: List<&2, String>, +s: S.Store, d: Disp) -> Disp:
  match ks:
    case Nil{}:
      d
    case Con{+k, t}:
      Ctl.dispatch.go(t, s, Ctl.dispatch.put(k, S.Store.get(s, k), d))

def Ctl.dispatch.pop(r: Q.Queue & List<&2, String>, +s: S.Store, jobs: List<&2, Job>) -> Disp:
  match r:
    case (q, ks):
      Ctl.dispatch.go(ks, s, Disp{q, jobs, False{}})

# Passes until one drops no key: a key whose object is gone frees its slot
# for the keys behind it. Every pass that continues dropped a waiting key,
# so as many passes as keys wait (plus one) always suffice.
def Ctl.dispatch.loop(fuel: Nat, +s: S.Store, d: Disp) -> Disp:
  match fuel d:
    case 0n x:
      x
    case 1n+f Disp{q, jobs, True{}}:
      Ctl.dispatch.loop(f, s, Ctl.dispatch.pop(Q.Queue.pop_all(64n, q, Nil{}), s, jobs))
    case 1n+f x:
      x

def Ctl.dispatch.wrap(s: S.Store, cs: List<&2, S.Store>, x: Stats, p: Maybe<&2, Chan(Unit)>,
  tm: Tim, d: Disp) -> CState & List<&2, Job>:
  match d:
    case Disp{q, jobs, dr}:
      (CState{s, cs, q, x, p, tm}, jobs)

def Ctl.dispatch.ready(+s: S.Store, cs: List<&2, S.Store>, +q: Q.Queue, x: Stats,
  p: Maybe<&2, Chan(Unit)>, tm: Tim, ready: Bool) -> CState & List<&2, Job>:
  match ready:
    case True{}:
      Ctl.dispatch.wrap(s, cs, x, p, tm,
        Ctl.dispatch.loop(1n+U32.to_nat(Q.Queue.depth(q)), s, Disp{q, Nil{}, True{}}))
    case False{}:
      (CState{s, cs, q, x, p, tm}, Nil{})

def Ctl.stopping(p: Maybe<&2, Chan(Unit)>) -> Bool:
  match p:
    case Some{r}:
      True{}
    case None{}:
      False{}

# The reconciles to start now: none until every cache has its first list,
# none while a watch is midway through a relist, and none once stopping.
def Ctl.dispatch(st: CState) -> CState & List<&2, Job>:
  match st:
    case CState{+s, +cs, +q, +x, +p, +tm}:
      Ctl.dispatch.ready(s, cs, q, x, p, tm,
        Bool.and(Bool.and(Bool.and(S.Store.ready(s), Caches.ready(cs)), Bool.not(Ctl.stopping(p))),
          Bool.not(Relist.any(CState{s, cs, q, x, p, tm}))))

def Ctl.halt.go(p: Maybe<&2, Chan(Unit)>, idle: Bool) -> Maybe<&2, Chan(Unit)>:
  match idle:
    case True{}:
      p
    case False{}:
      None{}

# Whose stop request to answer: a stopping controller with nothing running.
def Ctl.halt(st: CState) -> Maybe<&2, Chan(Unit)>:
  match st:
    case CState{s, cs, +q, x, p, tm}:
      Ctl.halt.go(p, U32.is_eq(Q.Queue.nrun(q), 0))

def Ctl.ready(st: CState) -> Bool:
  match st:
    case CState{+s, +cs, q, x, p, tm}:
      Bool.and(S.Store.ready(s), Caches.ready(cs))

def Ctl.snap_due(st: CState) -> Bool:
  match st:
    case CState{s, cs, q, x, p, Tim{at, gen, +n, +sn, +rd, dt, tk, rl}}:
      Bool.or(Bool.or(U32.is_ge((n - sn : U32), 1000), U32.is_eq(sn, 0)),
        Bool.xor(rd, Ctl.ready(CState{s, cs, q, x, p, Tim{at, gen, n, sn, rd, dt, tk, rl}})))

def Ctl.ticking(st: CState) -> CState:
  match st:
    case CState{s, cs, q, x, p, Tim{at, gen, n, sn, rd, dt, tk, rl}}:
      CState{s, cs, q, x, p, Tim{at, gen, n, sn, rd, dt, True{}, rl}}

def Ctl.tick_pending(st: CState) -> Bool:
  match st:
    case CState{s, cs, q, x, p, Tim{at, gen, n, sn, rd, dt, tk, rl}}:
      tk

# What an idle loop does about its status: publish now (a second has
# passed, or readiness changed), arm one tick to publish when the second
# is up, or nothing (nothing changed, or a tick is already armed).
type Idle is Data:
  IPub{}
  ITick{}
  INone{}

def Ctl.idle.go(dirty: Bool, due: Bool, pending: Bool) -> Idle:
  match dirty due pending:
    case True{} True{} p:
      IPub{}
    case True{} False{} False{}:
      ITick{}
    case _ _ _:
      INone{}

def Ctl.dirty(st: CState) -> Bool:
  match st:
    case CState{s, cs, q, x, p, Tim{at, gen, n, sn, rd, dt, tk, rl}}:
      dt

def Ctl.idle(+st: CState) -> Idle:
  Ctl.idle.go(Ctl.dirty(st), Ctl.snap_due(st), Ctl.tick_pending(st))

def Ctl.snapped(st: CState) -> CState:
  match st:
    case CState{+s, +cs, q, x, p, Tim{at, gen, +n, sn, rd, dt, tk, rl}}:
      CState{s, cs, q, x, p, Tim{at, gen, n, U32.max(n, 1), Bool.and(S.Store.ready(s), Caches.ready(cs)), False{}, tk, rl}}

def Ctl.snap(st: CState, name: String) -> Snap:
  match st:
    case CState{+s, +cs, +q, Stats{r, e, v, h, sm}, p, tm}:
      Snap{name, Bool.and(S.Store.ready(s), Caches.ready(cs)), r, e, v, Q.Queue.nrun(q),
        U32.from_nat(S.Store.size(s)), Q.Queue.depth(q), h, sm, Caches.sizes(cs)}

def CCtx.status(c: CCtx) -> Chan(SMsg):
  match c:
    case CCtx{cfg, sp, ch, st, ix, mt}:
      st

def CCtx.idx(c: CCtx) -> U32:
  match c:
    case CCtx{cfg, sp, ch, st, ix, mt}:
      ix

def CCtx.spec(c: CCtx) -> X.Spec:
  match c:
    case CCtx{cfg, sp, ch, st, ix, mt}:
      sp

def CCtx.meter(c: CCtx) -> Chan(X.Meter):
  match c:
    case CCtx{cfg, sp, ch, st, ix, mt}:
      mt

def CCtx.kind(c: CCtx) -> String:
  X.Spec.kind(CCtx.spec(c))

def Ctl.name(+c: CCtx) -> String:
  U32.show(CCtx.idx(c)) ++ "/" ++ CCtx.kind(c)

# Publishes a status snapshot at most once a second, whenever readiness
# changes, and when the loop goes idle with changes unpublished (a snapshot
# walks the cache to count it).
def Ctl.publish(+st: CState, +ctx: CCtx, due: Bool) -> IO(CState):
  match due:
    case True{}:
      IO.bind(Result<&1, &1, SMsg, Unit>, CState,
        Chan.send(SMsg, CCtx.status(ctx), SPut{CCtx.idx(ctx), Ctl.snap(st, Ctl.name(ctx))}),
        u => IO.pure(CState, Ctl.snapped(st)))
    case False{}:
      IO.pure(CState, st)

def CCtx.chan(c: CCtx) -> Chan(Msg):
  match c:
    case CCtx{cfg, sp, ch, st, ix, mt}:
      ch

# At idle: publish, or arm the tick, then wait for the next message.
def Ctl.at_idle(+st: CState, +ctx: CCtx, i: Idle) -> IO(CState):
  match i:
    case IPub{}:
      Ctl.publish(st, ctx, True{})
    case ITick{}:
      IO.bind(Unit, CState,
        IO.spawn(Result<&1, &1, Msg, Unit>,
          IO.bind(Unit, Result<&1, &1, Msg, Unit>, IO.sleep(1000),
            u => Chan.send(Msg, CCtx.chan(ctx), MTick{}))),
        u => IO.pure(CState, Ctl.ticking(st)))
    case INone{}:
      IO.pure(CState, st)

# Up to 10% more for a delay of a second or more, so requeues armed
# together (a relist, a restart) spread out.
def Ctl.jitter(+ms: U32, r: Result<&1, &1, U32 & String, U32>) -> U32:
  match r:
    case Done{x}:
      (ms + (x % (ms / 10 + 1)) : U32)
    case Fail{e}:
      ms

def Ctl.delay(+ms: U32, long: Bool) -> IO(U32):
  match long:
    case True{}:
      IO.bind(Result<&1, &1, U32 & String, U32>, U32, IO.random_u32(),
        r => IO.pure(U32, Ctl.jitter(ms, r)))
    case False{}:
      IO.pure(U32, ms)

def Ctl.sleeps(ss: List<&2, Sleep>, +chan: Chan(Msg)) -> IO(Unit):
  match ss:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{Sleep{key, due, +ms}, t}:
      IO.bind(Unit, Unit,
        IO.spawn(Result<&1, &1, Msg, Unit>,
          IO.bind(U32, Result<&1, &1, Msg, Unit>, Ctl.delay(ms, U32.is_ge(ms, 1000)),
            d => IO.bind(Unit, Result<&1, &1, Msg, Unit>, IO.sleep(d),
              u => Chan.send(Msg, chan, MWake{key, due})))),
        u => Ctl.sleeps(t, chan))

def CCtx.cfg(c: CCtx) -> K.Config:
  match c:
    case CCtx{cfg, sp, ch, st, ix, mt}:
      cfg

# What a reconcile sees: the config, the controller's index and the caches.
def Ctl.ctx(st: CState, +c: CCtx) -> X.Ctx:
  match st:
    case CState{s, cs, q, x, p, tm}:
      X.Ctx{CCtx.cfg(c), CCtx.idx(c), s, cs, 0, Some{CCtx.meter(c)},
        X.Spec.clusters(CCtx.spec(c), CCtx.cfg(c))}

def Ctl.report(+key: String, +kind: String, a: Q.Action) -> IO(Unit):
  match a:
    case Q.Retry{m}:
      L.Log.warn("reconcile failed; retrying with backoff",
        [L.Log.kv("kind", kind), L.Log.kv("key", key), L.Log.kv("error", m)])
    case Q.RetryIn{m, ms}:
      L.Log.warn("reconcile failed; retrying",
        [L.Log.kv("kind", kind), L.Log.kv("key", key), L.Log.kv("error", m),
          L.Log.kv("delay_ms", U32.show(ms))])
    case _:
      IO.pure(Unit, Unit{})

# The monotonic clock in ms (never stepped; it wraps every 49.7 days, which
# the wrapped subtractions handle): requeue deadlines
# and reconcile durations are measured by it.
def Ctl.mono() -> IO(U32):
  IO.bind(Nat, U32, IO.now(), n => IO.pure(U32, U32.from_nat(n)))

def Ctl.job.end(+key: String, +a: Q.Action, +t0: U32, +kind: String, +chan: Chan(Msg)) ->
  IO(Result<&1, &1, Msg, Unit>):
  IO.bind(U32, Result<&1, &1, Msg, Unit>, Ctl.mono(),
    +t1 => IO.bind(Unit, Result<&1, &1, Msg, Unit>, Ctl.report(key, kind, a),
      u => Chan.send(Msg, chan, MDone{key, a, (t1 - t0 : U32)})))

def Ctl.hung(+key: String, +to: U32, m: Maybe<&1, Q.Action>) -> IO(Q.Action):
  match m:
    case Some{a}:
      IO.pure(Q.Action, a)
    case None{}:
      IO.bind(Unit, Q.Action, L.Log.error("reconcile hung past its timeout; exiting so the pod restarts",
        [L.Log.kv("key", key), L.Log.kv("timeout_ms", U32.show(to))]), u => IO.die(Q.Action, 1, "reconcile hung"))

# The reconcile itself, raced against its timeout when it has one.
# A reconcile that outlives its timeout exits the process: it cannot be
# cancelled, and freeing its key while it runs would run the key twice.
def Ctl.call(~rec: J.Json -> X.Ctx -> IO(Q.Action), +key: String, o: J.Json, +ctx: X.Ctx, +to: U32,
  unbounded: Bool) -> IO(Q.Action):
  match unbounded:
    case True{}:
      rec(o, ctx)
    case False{}:
      IO.bind(Maybe<&1, Q.Action>, Q.Action, IO.within(Q.Action, to, rec(o, ctx)),
        m => Ctl.hung(key, to, m))

def Ctl.job.go(~rec: J.Json -> X.Ctx -> IO(Q.Action), +key: String, o: J.Json, +ctx: X.Ctx,
  +kind: String, +chan: Chan(Msg), +to: U32, +t0: U32) -> IO(Result<&1, &1, Msg, Unit>):
  IO.bind(Q.Action, Result<&1, &1, Msg, Unit>, Ctl.call(~rec, key, o, ctx, to, U32.is_eq(to, 0)),
    a => Ctl.job.end(key, a, t0, kind, chan))

# A reconcile, timed; a failure is logged; MDone answers on the channel.
def Ctl.job(~rec: J.Json -> X.Ctx -> IO(Q.Action), +key: String, o: J.Json, +ctx: X.Ctx,
  +kind: String, +chan: Chan(Msg), +to: U32) -> IO(Result<&1, &1, Msg, Unit>):
  IO.bind(U32, Result<&1, &1, Msg, Unit>, Ctl.mono(),
    t0 => Ctl.job.go(~rec, key, o, ctx, kind, chan, to, t0))

# Starts a reconcile per job, each with the caches and its key's failure
# count; each answers MDone on the channel.
def Ctl.spawn(~rec: J.Json -> X.Ctx -> IO(Q.Action), jobs: List<&2, Job>, +chan: Chan(Msg),
  +ctx: X.Ctx, +kind: String, +to: U32) -> IO(Unit):
  match jobs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{Job{key, o, fl}, t}:
      IO.bind(Unit, Unit,
        IO.spawn(Result<&1, &1, Msg, Unit>,
          Ctl.job(~rec, key, o, X.Ctx.with_fails(ctx, fl), kind, chan, to)),
        u => Ctl.spawn(~rec, t, chan, ctx, kind, to))

# The controller loop: a message in, the state stepped, timers armed,
# reconciles started, the next message awaited; a stop request is answered
# once nothing runs, and ends the loop.
def Ctl.run(~rec: J.Json -> X.Ctx -> IO(Q.Action), outer: Nat, fuel: Nat, ev: CEv, +st: CState,
  +ctx: CCtx) -> IO(Unit):
  match outer fuel ev:
    case 0n 0n e:
      Loop.spent("Ctl.run")
    case 1n+o 0n e:
      Ctl.run(~rec, o, 4294967295n, e, st, ctx)
    case o 1n+f CMsg{None{}}:
      IO.pure(Unit, Unit{})
    case o 1n+f CMsg{Some{m}}:
      IO.bind(U32, Unit, Ctl.mono(),
        now => Ctl.run(~rec, o, f, CTimed{m, now}, st, ctx))
    case o 1n+f CTimed{m, +now}:
      Ctl.run(~rec, o, f, CHandled{Ctl.plan(Ctl.on_msg(Ctl.at(st, now), m, CCtx.spec(ctx)))}, st, ctx)
    case o 1n+f CHandled{(+st1, ss)}:
      IO.bind(Unit, Unit, Ctl.sleeps(ss, CCtx.chan(ctx)),
        u => Ctl.run(~rec, o, f, CDisp{Ctl.dispatch(st1)}, st1, ctx))
    case o 1n+f CDisp{(+st2, jobs)}:
      IO.bind(Unit, Unit, Ctl.spawn(~rec, jobs, CCtx.chan(ctx), Ctl.ctx(st2, ctx), CCtx.kind(ctx),
        X.Spec.timeout_of(CCtx.spec(ctx))),
        u => IO.bind(CState, Unit, Ctl.publish(st2, ctx, Ctl.snap_due(st2)),
          +st3 => Ctl.run(~rec, o, f, CNext{Ctl.halt(st3)}, st3, ctx)))
    case o 1n+f CNext{Some{r}}:
      IO.bind(Result<&1, &1, Unit, Unit>, Unit, Chan.send(Unit, r, Unit{}),
        u => L.Log.info("controller stopped", [L.Log.kv("controller", Ctl.name(ctx))]))
    case o 1n+f CNext{None{}}:
      IO.bind(Poll<&1, &1, Maybe<&1, Msg>, Unit>, Unit, Chan.try_recv(Msg, CCtx.chan(ctx), 0),
        p => Ctl.run(~rec, o, f, CPeek{p}, st, ctx))
    case o 1n+f CPeek{Ready{m}}:
      Ctl.run(~rec, o, f, CMsg{m}, st, ctx)
    case o 1n+f CPeek{Wait{u}}:
      # idle: publish what changed since the last snapshot, then wait
      IO.bind(CState, Unit, Ctl.at_idle(st, ctx, Ctl.idle(st)),
        +st4 => IO.bind(Maybe<&1, Msg>, Unit, Chan.recv(Msg, CCtx.chan(ctx)),
          m => Ctl.run(~rec, o, f, CMsg{m}, st4, ctx)))

def Ctl.watch.subs(+cfg: K.Config, api: C.Api, label: String, field: String, subs: List<&2, Sub>) ->
  IO(Unit):
  IO.spawn(Unit, Drv.run(4294967295n, 4294967295n, DStart{}, W.WState.init(), H.Http.resp.init(), Nil{},
    WCtx{cfg, api, label, field, subs}))

def Api.kind(a: C.Api) -> String:
  match a:
    case C.Api{r, s}:
      C.Res.kind(r)

def Keeper.all.put(r: Map<&2, Snap> & Snap, rest: List<&2, Snap>) -> List<&2, Snap>:
  match r:
    case (m, s):
      s <> rest

def Keeper.all.go(ks: List<&2, String>, +m: Map<&2, Snap>) -> List<&2, Snap>:
  match ks:
    case Nil{}:
      Nil{}
    case Con{k, t}:
      Keeper.all.put(Map.get(Snap, Snap{"", False{}, 0, 0, 0, 0, 0, 0, Hist.zero(), Sum{0, 0}, Nil{}}, m, k),
        Keeper.all.go(t, m))

def Keeper.all(+m: Map<&2, Snap>) -> List<&2, Snap>:
  Keeper.all.go(Map.keys(&2, Snap, m), m)

# The status keeper: holds each controller's latest snapshot and answers
# queries at once.
def Keeper.run(outer: Nat, fuel: Nat, m: Maybe<&1, SMsg>, +last: Map<&2, Snap>, +inbox: Chan(SMsg)) -> IO(Unit):
  match outer fuel m:
    case 0n 0n x:
      Loop.spent("Keeper.run")
    case 1n+o 0n x:
      Keeper.run(o, 4294967295n, x, last, inbox)
    case o 1n+f None{}:
      IO.pure(Unit, Unit{})
    case o 1n+f Some{SPut{i, s}}:
      IO.bind(Maybe<&1, SMsg>, Unit, Chan.recv(SMsg, inbox),
        x => Keeper.run(o, f, x, Map.set(&2, Snap, last, U32.show(i), s), inbox))
    case o 1n+f Some{SGet{r}}:
      IO.bind(Result<&1, &1, List<&2, Snap>, Unit>, Unit,
        Chan.send(List<&2, Snap>, r, Keeper.all(last)),
        u => IO.bind(Maybe<&1, SMsg>, Unit, Chan.recv(SMsg, inbox), x => Keeper.run(o, f, x, last, inbox)))

# Starts a status keeper; answers its inbox.
def Keeper.start() -> IO(Chan(SMsg)):
  IO.bind(Chan(SMsg), Chan(SMsg), Chan.new(SMsg, 4096),
    +c => IO.bind(Unit, Chan(SMsg), IO.spawn(Unit,
      IO.bind(Maybe<&1, SMsg>, Unit, Chan.recv(SMsg, c),
        x => Keeper.run(4294967295n, 4294967295n, x, Map.new(&2, Snap), c))), u => IO.pure(Chan(SMsg), c)))

def Ctl.loop(~rec: J.Json -> X.Ctx -> IO(Q.Action), +cfg: K.Config, +spec: X.Spec,
  +chan: Chan(Msg), +status: Chan(SMsg), +meter: Chan(X.Meter), +idx: U32) -> IO(Unit):
  Ctl.run(~rec, 4294967295n, 4294967295n,
    CDisp{(CState{S.Store.new(),
      List.replicate(S.Store, List.length(&2, X.Sec, X.Spec.secs(spec)), S.Store.new()),
      Q.Queue.new(X.Spec.max_of(spec)), Stats{0, 0, 0, Hist.zero(), Sum{0, 0}}, None{}, Tim.new()}, Nil{})},
    CState{S.Store.new(), Nil{}, Q.Queue.new(X.Spec.max_of(spec)), Stats{0, 0, 0, Hist.zero(), Sum{0, 0}},
      None{}, Tim.new()},
    CCtx{cfg, spec, chan, status, idx, meter})

def Controller.inbox() -> IO(Chan(Msg)):
  Chan.new(Msg, 4096)

# Meter
# -----
#
# The metrics controllers define (X.Meter): counters and gauges by name and
# labels, held by one computation and rendered for /metrics.

def Meter.key(+name: String, +labels: String, none: Bool) -> String:
  match none:
    case True{}:
      name
    case False{}:
      name ++ "{" ++ labels ++ "}"

def Meter.kind(k: U32) -> String:
  match k:
    case 0:
      "counter"
    case _:
      "gauge"

def Meter.sample(+k: String, mine: Bool, +vals: Map<&2, U32>) -> String:
  match mine:
    case True{}:
      k ++ " " ++ U32.show(Q.Mp.get(vals, k)) ++ "\n"
    case False{}:
      ""

def Meter.samples(ks: List<&2, String>, +name: String, +vals: Map<&2, U32>) -> String:
  match ks:
    case Nil{}:
      ""
    case Con{+k, t}:
      Meter.sample(k, Bool.or(String.eq(k, name), String.starts_with(k, name ++ "{")), vals)
        ++ Meter.samples(t, name, vals)

def Meter.render.go(ns: List<&2, String>, +vals: Map<&2, U32>, +kinds: Map<&2, U32>) -> String:
  match ns:
    case Nil{}:
      ""
    case Con{+n, t}:
      "# TYPE " ++ n ++ " " ++ Meter.kind(Q.Mp.get(kinds, n)) ++ "\n"
        ++ Meter.samples(Map.keys(&2, U32, vals), n, vals) ++ Meter.render.go(t, vals, kinds)

# Every series, family by family, in the Prometheus text format.
def Meter.render(+vals: Map<&2, U32>, +kinds: Map<&2, U32>) -> String:
  Meter.render.go(Map.keys(&2, U32, kinds), vals, kinds)

def Meter.run(outer: Nat, fuel: Nat, m: Maybe<&1, X.Meter>, +vals: Map<&2, U32>, +kinds: Map<&2, U32>,
  +inbox: Chan(X.Meter)) -> IO(Unit):
  match outer fuel m:
    case 0n 0n x:
      Loop.spent("Meter.run")
    case 1n+o 0n x:
      Meter.run(o, 4294967295n, x, vals, kinds, inbox)
    case o 1n+f None{}:
      IO.pure(Unit, Unit{})
    case o 1n+f Some{X.MAdd{+n, +l, +k}}:
      IO.bind(Maybe<&1, X.Meter>, Unit, Chan.recv(X.Meter, inbox),
        x => Meter.run(o, f, x,
          Map.set(&2, U32, vals, Meter.key(n, l, String.is_empty(l)),
            (Q.Mp.get(vals, Meter.key(n, l, String.is_empty(l))) + k : U32)),
          Map.set(&2, U32, kinds, n, 0), inbox))
    case o 1n+f Some{X.MSet{+n, +l, v}}:
      IO.bind(Maybe<&1, X.Meter>, Unit, Chan.recv(X.Meter, inbox),
        x => Meter.run(o, f, x, Map.set(&2, U32, vals, Meter.key(n, l, String.is_empty(l)), v),
          Map.set(&2, U32, kinds, n, 1), inbox))
    case o 1n+f Some{X.MDrop{+n, +l}}:
      IO.bind(Maybe<&1, X.Meter>, Unit, Chan.recv(X.Meter, inbox),
        x => Meter.run(o, f, x, Map.del(&2, U32, vals, Meter.key(n, l, String.is_empty(l))), kinds, inbox))
    case o 1n+f Some{X.MRead{r}}:
      IO.bind(Result<&1, &1, String, Unit>, Unit, Chan.send(String, r, Meter.render(vals, kinds)),
        u => IO.bind(Maybe<&1, X.Meter>, Unit, Chan.recv(X.Meter, inbox),
          x => Meter.run(o, f, x, vals, kinds, inbox)))

# Starts the meter; answers its inbox.
def Meter.start() -> IO(Chan(X.Meter)):
  IO.bind(Chan(X.Meter), Chan(X.Meter), Chan.new(X.Meter, 4096),
    +c => IO.bind(Unit, Chan(X.Meter), IO.spawn(Unit,
      IO.bind(Maybe<&1, X.Meter>, Unit, Chan.recv(X.Meter, c),
        x => Meter.run(4294967295n, 4294967295n, x, Map.new(&2, U32), Map.new(&2, U32), c))),
      u => IO.pure(Chan(X.Meter), c)))

# Manager
# -------
#
# Several controllers in one process (controller-runtime's Manager, with
# kube-runtime's shared reflectors): each runs its own loop, caches and
# queue, but a watch they share (the same resource, scope and label
# selector) runs once, and its outputs fan out to every controller that
# subscribed, so the API server sees one list and one watch per resource.
# A lone controller is a manager of one.

# The older way to name a controller: a primary with a label selector, the
# kinds it owns, and how many reconciles run at once (X.Spec says more).
type Ctrl is Data:
  Ctrl{primary: C.Api, label: String, owned: List<&2, C.Api>, max: U32}

def Ctrl.owns(os: List<&2, C.Api>, s: X.Spec) -> X.Spec:
  match os:
    case Nil{}:
      s
    case Con{a, t}:
      Ctrl.owns(t, X.Spec.owns(s, a))

def Ctrl.spec(c: Ctrl) -> X.Spec:
  match c:
    case Ctrl{p, l, os, m}:
      Ctrl.owns(os, X.Spec.max(X.Spec.label(X.Spec.of(p), l), m))

def Ctrl.specs(cs: List<&2, Ctrl>) -> List<&2, X.Spec>:
  match cs:
    case Nil{}:
      Nil{}
    case Con{c, t}:
      Ctrl.spec(c) <> Ctrl.specs(t)

# A watch: what, with which label and field selectors, on which cluster
# (None: the controllers' own), for whom.
type Watch is Data:
  Watch{api: C.Api, label: String, field: String, cluster: Maybe<&2, K.Config>, subs: List<&2, Sub>}

def Watch.at(m: Maybe<&2, K.Config>) -> String:
  match m:
    case None{}:
      ""
    case Some{c}:
      K.Config.ident(c)

# Two watches are one when they ask the same cluster, as the same user, for
# the same objects.
def Watch.key(+api: C.Api, +label: String, +field: String, +cl: Maybe<&2, K.Config>) -> String:
  C.Api.path(api) ++ "?l=" ++ label ++ "&f=" ++ field ++ "&c=" ++ Watch.at(cl)

def Plan.hit(ws: List<&2, Watch>, +key: String) -> Bool:
  match ws:
    case Con{Watch{+a, +l, +fs, +c, s}, t}:
      String.eq(Watch.key(a, l, fs, c), key)
    case _:
      False{}

# Adds a subscription: to the watch of the same key, or as a new watch.
def Plan.add(ws: List<&2, Watch>, +api: C.Api, +label: String, +field: String, +cl: Maybe<&2, K.Config>,
  +sub: Sub, hit: Bool) -> List<&2, Watch>:
  match ws hit:
    case Con{Watch{a, l, fs, c, ss}, t} True{}:
      Watch{a, l, fs, c, List.append(&2, Sub, ss, [sub])} <> t
    case Con{+w, +t} False{}:
      w <> Plan.add(t, api, label, field, cl, sub, Plan.hit(t, Watch.key(api, label, field, cl)))
    case Nil{} _:
      [Watch{api, label, field, cl, [sub]}]

def Plan.sub(+ws: List<&2, Watch>, +api: C.Api, +label: String, +field: String, +cl: Maybe<&2, K.Config>,
  +sub: Sub) -> List<&2, Watch>:
  Plan.add(ws, api, label, field, cl, sub, Plan.hit(ws, Watch.key(api, label, field, cl)))

def Plan.secs(ss: List<&2, X.Sec>, +ch: Chan(Msg), +n: U32, ws: List<&2, Watch>) -> List<&2, Watch>:
  match ss:
    case Nil{}:
      ws
    case Con{X.Sec{a, l, fs, r, d, ps, c}, t}:
      Plan.secs(t, ch, (n + 1 : U32), Plan.sub(ws, a, l, fs, c, Sub{ch, n}))

# Every watch the controllers need, each once, with all its subscribers.
def Plan.build(cs: List<&2, X.Spec>, chs: List<&2, Chan(Msg)>, ws: List<&2, Watch>) -> List<&2, Watch>:
  match cs chs:
    case Con{X.Spec{p, l, fs, ps, ss, m, to, c}, t} Con{+ch, ct}:
      Plan.build(t, ct, Plan.secs(ss, ch, 1, Plan.sub(ws, p, l, fs, c, Sub{ch, 0})))
    case _ _:
      ws

def Manager.inboxes(+n: Nat) -> IO(List<&2, Chan(Msg)>):
  match n:
    case 0n:
      IO.pure(List<&2, Chan(Msg)>, Nil{})
    case 1n+k:
      IO.bind(Chan(Msg), List<&2, Chan(Msg)>, Controller.inbox(),
        ch => IO.bind(List<&2, Chan(Msg)>, List<&2, Chan(Msg)>, Manager.inboxes(k),
          rest => IO.pure(List<&2, Chan(Msg)>, ch <> rest)))

def Manager.watch(+cfg: K.Config, ws: List<&2, Watch>) -> IO(Unit):
  match ws:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{Watch{a, l, fs, c, ss}, t}:
      IO.bind(Unit, Unit, Ctl.watch.subs(X.Cluster.of(cfg, c), a, l, fs, ss), u => Manager.watch(cfg, t))

def Manager.loops(~rec: J.Json -> X.Ctx -> IO(Q.Action), +cfg: K.Config, cs: List<&2, X.Spec>,
  chs: List<&2, Chan(Msg)>, +status: Chan(SMsg), +meter: Chan(X.Meter), +i: U32) -> IO(Unit):
  match cs chs:
    case Con{s, t} Con{ch, ct}:
      IO.bind(Unit, Unit, IO.spawn(Unit, Ctl.loop(~rec, cfg, s, ch, status, meter, i)),
        u => Manager.loops(~rec, cfg, t, ct, status, meter, (i + 1 : U32)))
    case _ _:
      IO.pure(Unit, Unit{})

# Runs every controller on its inbox (Manager.inboxes), sharing their
# watches. rec(obj, ctx) reconciles obj; X.Ctx.idx(ctx) names the
# controller.
def Manager.start.go(~rec: J.Json -> X.Ctx -> IO(Q.Action), +cfg: K.Config, +cs: List<&2, X.Spec>,
  +chs: List<&2, Chan(Msg)>, +status: Chan(SMsg), +meter: Chan(X.Meter),
  p: Poll<&1, &1, Maybe<&1, Unit>, Unit>) -> IO(Unit):
  match p:
    case Ready{Some{u}}:
      IO.bind(Unit, Unit, Manager.watch(cfg, Plan.build(cs, chs, Nil{})),
        u2 => Manager.loops(~rec, cfg, cs, chs, status, meter, 0))
    case _:
      L.Log.info("shutting down; controllers not started", Nil{})

# Runs every controller on its inbox (Manager.inboxes), sharing their
# watches, once it takes the start gate's token (Manager.gate): shutdown
# takes it first when it comes first, and then nothing starts. rec(obj,
# ctx) reconciles obj; X.Ctx.idx(ctx) names the controller.
def Manager.start(~rec: J.Json -> X.Ctx -> IO(Q.Action), +cfg: K.Config, +cs: List<&2, X.Spec>,
  +chs: List<&2, Chan(Msg)>, +status: Chan(SMsg), +meter: Chan(X.Meter), +gate: Chan(Unit)) ->
  IO(Unit):
  IO.bind(Poll<&1, &1, Maybe<&1, Unit>, Unit>, Unit, Chan.try_recv(Unit, gate, 0),
    p => Manager.start.go(~rec, cfg, cs, chs, status, meter, p))

# The start gate: one token, taken by whichever comes first, the
# controllers starting (Manager.start) or shutdown (Manager.stop). So
# shutdown either knows they run and drains them, or keeps them from ever
# starting.
def Manager.gate() -> IO(Chan(Unit)):
  IO.bind(Chan(Unit), Chan(Unit), Chan.new(Unit, 1),
    +c => IO.bind(Poll<&1, &1, Result<&1, &1, Unit, Unit>, Unit>, Chan(Unit),
      Chan.try_send(Unit, c, Unit{}, 0), u => IO.pure(Chan(Unit), c)))

# Stopping
# --------

# The stop requests delivered, and whether every controller took one.
type Asked is Data:
  Asked{rs: List<&2, Chan(Unit)>, all: Bool}

def Stop.ask.put(p: Poll<&1, &1, Result<&1, &1, Msg, Unit>, Msg>, +r: Chan(Unit), a: Asked) -> Asked:
  match p a:
    case Ready{Done{u}} Asked{rs, all}:
      Asked{r <> rs, all}
    case _ Asked{rs, all}:
      Asked{rs, False{}}

# Asks each controller to stop; one whose inbox does not take the request
# within a second makes the drain unclean (its reconciles may go on).
def Stop.ask(chs: List<&2, Chan(Msg)>) -> IO(Asked):
  match chs:
    case Nil{}:
      IO.pure(Asked, Asked{Nil{}, True{}})
    case Con{ch, t}:
      IO.bind(Chan(Unit), Asked, Chan.new(Unit, 1),
        +r => IO.bind(Poll<&1, &1, Result<&1, &1, Msg, Unit>, Msg>, Asked,
          Chan.try_send(Msg, ch, MStop{r}, 1000),
          p => IO.bind(Asked, Asked, Stop.ask(t), rest => IO.pure(Asked, Stop.ask.put(p, r, rest)))))

def Stop.wait(rs: List<&2, Chan(Unit)>) -> IO(Unit):
  match rs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{r, t}:
      IO.bind(Maybe<&1, Unit>, Unit, Chan.recv(Unit, r), u => Stop.wait(t))

# Whether every controller took the stop request and finished in time.
def Stop.said(m: Maybe<&1, Bool>) -> IO(Bool):
  match m:
    case Some{True{}}:
      IO.bind(Unit, Bool, L.Log.info("reconciles drained", Nil{}), x => IO.pure(Bool, True{}))
    case Some{False{}}:
      IO.bind(Unit, Bool,
        L.Log.warn("a controller did not take the stop request; exiting without releasing the lease", Nil{}),
        x => IO.pure(Bool, False{}))
    case None{}:
      IO.bind(Unit, Bool,
        L.Log.warn("reconciles still running at the grace deadline; exiting without releasing the lease", Nil{}),
        x => IO.pure(Bool, False{}))

def Stop.all.of(a: Asked) -> IO(Bool):
  match a:
    case Asked{rs, all}:
      IO.bind(Unit, Bool, Stop.wait(rs), u => IO.pure(Bool, all))

def Stop.all(chs: List<&2, Chan(Msg)>) -> IO(Bool):
  IO.bind(Asked, Bool, Stop.ask(chs), Stop.all.of)

# p: shutdown's attempt to take the start gate's token. Taking it means no
# controller started, nor ever will: nothing to drain. Otherwise they run.
def Stop.drain(chs: List<&2, Chan(Msg)>, +grace: U32, p: Poll<&1, &1, Maybe<&1, Unit>, Unit>) -> IO(Bool):
  match p:
    case Ready{Some{u}}:
      # no controller started (a standby replica), and none will now
      IO.pure(Bool, True{})
    case _:
      IO.bind(Unit, Bool, L.Log.info("draining reconciles", [L.Log.kv("grace_ms", U32.show(grace))]),
        u2 => IO.bind(Maybe<&1, Bool>, Bool, IO.within(Bool, grace, Stop.all(chs)), Stop.said))

# Asks every running controller to stop: no new reconciles start, and this
# returns once the running ones finish, or after grace ms. Nothing to do
# when the controllers never started (a standby replica). Answers whether
# nothing is left running.
def Manager.stop(chs: List<&2, Chan(Msg)>, +gate: Chan(Unit), +grace: U32) -> IO(Bool):
  IO.bind(Poll<&1, &1, Maybe<&1, Unit>, Unit>, Bool, Chan.try_recv(Unit, gate, 0),
    p => Stop.drain(chs, grace, p))
