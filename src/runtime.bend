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
# Loops count down a large fuel (4294967295n steps, lazily), so they
# terminate by structure; at a few steps a second that is over a year.

type Msg is Data:
  MOuts{src: U32, outs: List<&2, W.Out>}
  MDone{key: String, act: Q.Action, ms: U32}
  MWake{key: String, gen: U32}
  MStop{reply: Chan(Unit)}

# The controller's state as the health server reports it.
type Snap is Data:
  Snap{name: String, ready: Bool, reconciles: U32, errors: U32, events: U32, running: U32,
    objects: U32, queued: U32, hist: List<&2, U32>, sum_ms: U32}

# The status keeper's inbox: a controller's latest snapshot (by its index),
# or a query for all of them (none until a controller runs: a standby
# replica).
type SMsg is Data:
  SPut{idx: U32, snap: Snap}
  SGet{reply: Chan(List<&2, Snap>)}

# Counters since start; hist counts reconciles by duration (Hist.bounds),
# sum_ms is their total time.
type Stats is Data:
  Stats{reconciles: U32, errors: U32, events: U32, hist: List<&2, U32>, sum_ms: U32}

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

def Drv.digest.end.go(st: W.WState, outs: List<&2, W.Out>, +wait: Bool, r: H.Resp,
  carry: List<&2, U32>, +end: Bool) -> Dig:
  match end:
    case True{}:
      Dig{W.Watcher.merge(W.Step{st, outs, wait}, W.IWatchEnd{}), r, carry, False{}}
    case False{}:
      Dig{W.Step{st, outs, wait}, r, carry, Bool.not(wait)}

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
def Drv.run(fuel: Nat, ev: DEv, +st: W.WState, +resp: H.Resp, +carry: List<&2, U32>,
  +ctx: WCtx) -> IO(Unit):
  match fuel ev:
    case 0n e:
      IO.pure(Unit, Unit{})
    case 1n+f DStart{}:
      match st:
        case W.WState{W.WList{+c}, +fl, +first}:
          IO.bind(Unit, Unit, Drv.note_list(first, WCtx.path(ctx)),
            u => IO.bind(Result<&2, &2, Cl.KErr, J.Json>, Unit,
              Cl.Client.json(WCtx.cfg(ctx), WCtx.list_req(ctx, c)),
              r => Drv.run(f, DListed{r}, W.WState{W.WList{c}, fl, first}, resp, carry, ctx)))
        case W.WState{W.WWatch{+rv}, +fl, +first}:
          IO.bind(Result<&1, &1, U32 & String, N.Tls>, Unit,
            Cl.Conn.open(WCtx.cfg(ctx), WCtx.watch_req(ctx, rv), False{}),
            r => Drv.run(f, DOpened{r}, W.WState{W.WWatch{rv}, fl, first}, resp, carry, ctx))
    case 1n+f DListed{Done{+j}}:
      Drv.run(f, DStepped{W.Watcher.step(st, W.IPage{C.Page.of(j)}), None{}, False{}}, st, resp,
        carry, ctx)
    case 1n+f DListed{Fail{+e}}:
      Drv.run(f, DStepped{W.Watcher.step(st, W.IListErr{Cl.KErr.code(e)}), None{}, False{}}, st,
        resp, carry, ctx)
    case 1n+f DOpened{Done{N.Tls{s}}}:
      IO.bind(Socket & Result<&1, &1, U32 & String, List<&2, U32>>, Unit,
        N.Tls.recv(s, 65536, 350000),
        p => Drv.run(f, DEv.recv(p), st, H.Http.resp.init(), Nil{}, ctx))
    case 1n+f DOpened{Fail{e}}:
      Drv.run(f, DStepped{W.Watcher.step(st, W.IWatchErr{0}), None{}, False{}}, st, resp, carry,
        ctx)
    case 1n+f DRecv{s, Done{+bs}}:
      Drv.run(f, DDig{s, Drv.digest(st, H.Http.feed(bs, resp), carry,
        List.is_empty(&2, U32, bs))}, st, resp, carry, ctx)
    case 1n+f DDig{s, Dig{step, r2, c2, more}}:
      Drv.run(f, DStepped{step, Some{s}, more}, st, r2, c2, ctx)
    case 1n+f DRecv{s, Fail{e}}:
      Drv.run(f, DStepped{W.Watcher.step(st, W.IWatchErr{0}), Some{s}, False{}}, st, resp,
        carry, ctx)
    case 1n+f DStepped{W.Step{st2, outs, wait}, s, more}:
      IO.bind(Unit, Unit, Drv.send_all(WCtx.subs(ctx), outs),
        u => Drv.run(f, DNext{s, wait, more}, st2, resp, carry, ctx))
    case 1n+f DNext{Some{s}, False{}, True{}}:
      IO.bind(Socket & Result<&1, &1, U32 & String, List<&2, U32>>, Unit,
        N.Tls.recv(s, 65536, 350000), p => Drv.run(f, DEv.recv(p), st, resp, carry, ctx))
    case 1n+f DNext{s, wait, more}:
      IO.bind(Unit, Unit, Drv.close(s),
        u => IO.bind(Unit, Unit, Drv.pause(wait, WState.fails(st), WCtx.path(ctx)),
          u2 => Drv.run(f, DStart{}, st, H.Http.resp.init(), Nil{}, ctx)))

# Controller
# ----------
#
# A controller's loop owns its caches (the primary's and one per related
# watch) and its queue, all pure values. A batch of watcher outputs is
# folded into its cache by control.bend, which says which keys it
# triggers; reconciles start once every cache has listed, each with a
# snapshot of the caches (X.Ctx). A stop request (MStop) starts no more
# reconciles and is answered once the running ones finish.

type CState is Data:
  CState{store: S.Store, caches: List<&2, S.Store>, queue: Q.Queue, stats: Stats,
    stop: Maybe<&2, Chan(Unit)>}

type CCtx is Data:
  CCtx{cfg: K.Config, spec: X.Spec, chan: Chan(Msg), status: Chan(SMsg), idx: U32}

# A reconcile to start: the key and the object the store holds for it.
type Job is Data:
  Job{key: String, obj: J.Json}

# What the controller loop just saw.
type CEv is Type:
  CMsg{m: Maybe<&1, Msg>}
  CHandled{r: CState & List<&2, Q.Timer>}
  CDisp{r: CState & List<&2, Job>}
  CNext{halt: Maybe<&2, Chan(Unit)>}

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

def Caches.ready(cs: List<&2, S.Store>) -> Bool:
  match cs:
    case Nil{}:
      True{}
    case Con{s, t}:
      Bool.and(S.Store.ready(s), Caches.ready(t))

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
      Stats{(r + 1 : U32), (e + 1 : U32), v, Hist.bump(h, ms), (sm + ms : U32)}
    case Stats{+r, e, v, h, +sm} _:
      Stats{(r + 1 : U32), e, v, Hist.bump(h, ms), (sm + ms : U32)}

def Ctl.prim.put(cs: List<&2, S.Store>, q: Q.Queue, x: Stats, p: Maybe<&2, Chan(Unit)>,
  f: X.Fold) -> CState:
  match f:
    case X.Fold{s, ks, g}:
      CState{s, cs, Q.Queue.forget_all(g, Q.Queue.add_all(ks, q)), x, p}

def Ctl.rel.put(+n: Nat, s: S.Store, cs: List<&2, S.Store>, q: Q.Queue, x: Stats,
  p: Maybe<&2, Chan(Unit)>, f: X.Fold) -> CState:
  match f:
    case X.Fold{c, ks, g}:
      CState{s, Caches.set(cs, n, c), Q.Queue.add_all(ks, q), x, p}

# Outputs of watch src: the primary's (0) through its predicates, a related
# watch's (n) through its relation.
def Ctl.on_outs(st: CState, +src: U32, +outs: List<&2, W.Out>, +spec: X.Spec, own: Bool) -> CState:
  match st own:
    case CState{s, cs, q, x, p} True{}:
      Ctl.prim.put(cs, q, Stats.events(x, U32.from_nat(List.length(&2, W.Out, outs))), p,
        X.Fold.prim(X.Spec.preds(spec), outs, X.Fold{s, Nil{}, Nil{}}))
    case CState{+s, +cs, q, x, p} False{}:
      Ctl.rel.put(U32.to_nat((src - 1 : U32)), s, cs, q,
        Stats.events(x, U32.from_nat(List.length(&2, W.Out, outs))), p,
        X.Fold.rel(Secs.rel(X.Spec.secs(spec), U32.to_nat((src - 1 : U32))), X.Spec.kind(spec),
          outs, s, X.Fold{Caches.nth(cs, U32.to_nat((src - 1 : U32))), Nil{}, Nil{}}))

def Ctl.on_done(s: S.Store, cs: List<&2, S.Store>, x: Stats, p: Maybe<&2, Chan(Unit)>,
  r: Q.Queue & List<&2, Q.Timer>) -> CState & List<&2, Q.Timer>:
  match r:
    case (q, ts):
      (CState{s, cs, q, x, p}, ts)

def Ctl.on_done.st(st: CState, key: String, +a: Q.Action, +ms: U32) ->
  CState & List<&2, Q.Timer>:
  match st:
    case CState{s, cs, q, x, p}:
      Ctl.on_done(s, cs, Stats.done(x, a, ms), p, Q.Queue.done(q, key, a))

def Ctl.on_wake(st: CState, key: String, g: U32) -> CState & List<&2, Q.Timer>:
  match st:
    case CState{s, cs, q, x, p}:
      (CState{s, cs, Q.Queue.wake(q, key, g), x, p}, Nil{})

def Ctl.on_stop(st: CState, r: Chan(Unit)) -> CState & List<&2, Q.Timer>:
  match st:
    case CState{s, cs, q, x, p}:
      (CState{s, cs, q, x, Some{r}}, Nil{})

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

def Ctl.dispatch.drop(r: Q.Queue & List<&2, Q.Timer>, jobs: List<&2, Job>) ->
  Q.Queue & List<&2, Job>:
  match r:
    case (q, ts):
      (q, jobs)

def Ctl.dispatch.put(+key: String, m: Maybe<&2, J.Json>, q: Q.Queue, jobs: List<&2, Job>) ->
  Q.Queue & List<&2, Job>:
  match m:
    case Some{o}:
      (q, Job{key, o} <> jobs)
    case None{}:
      # gone from the store: nothing to reconcile
      Ctl.dispatch.drop(Q.Queue.done(q, key, Q.AwaitChange{}), jobs)

def Ctl.dispatch.acc(+k: String, m: Maybe<&2, J.Json>, acc: Q.Queue & List<&2, Job>) ->
  Q.Queue & List<&2, Job>:
  match acc:
    case (q, jobs):
      Ctl.dispatch.put(k, m, q, jobs)

def Ctl.dispatch.go(ks: List<&2, String>, +s: S.Store, acc: Q.Queue & List<&2, Job>) ->
  Q.Queue & List<&2, Job>:
  match ks:
    case Nil{}:
      acc
    case Con{+k, t}:
      Ctl.dispatch.go(t, s, Ctl.dispatch.acc(k, S.Store.get(s, k), acc))

def Ctl.dispatch.wrap(s: S.Store, cs: List<&2, S.Store>, x: Stats, p: Maybe<&2, Chan(Unit)>,
  r: Q.Queue & List<&2, Job>) -> CState & List<&2, Job>:
  match r:
    case (q, jobs):
      (CState{s, cs, q, x, p}, jobs)

def Ctl.dispatch.fin(+s: S.Store, cs: List<&2, S.Store>, x: Stats, p: Maybe<&2, Chan(Unit)>,
  r: Q.Queue & List<&2, String>) -> CState & List<&2, Job>:
  match r:
    case (q, ks):
      Ctl.dispatch.wrap(s, cs, x, p, Ctl.dispatch.go(ks, s, (q, Nil{})))

def Ctl.dispatch.ready(+s: S.Store, cs: List<&2, S.Store>, q: Q.Queue, x: Stats,
  p: Maybe<&2, Chan(Unit)>, ready: Bool) -> CState & List<&2, Job>:
  match ready:
    case True{}:
      Ctl.dispatch.fin(s, cs, x, p, Q.Queue.pop_all(64n, q, Nil{}))
    case False{}:
      (CState{s, cs, q, x, p}, Nil{})

def Ctl.stopping(p: Maybe<&2, Chan(Unit)>) -> Bool:
  match p:
    case Some{r}:
      True{}
    case None{}:
      False{}

# The reconciles to start now: none until every cache has its first list,
# and none once stopping.
def Ctl.dispatch(st: CState) -> CState & List<&2, Job>:
  match st:
    case CState{+s, +cs, q, x, +p}:
      Ctl.dispatch.ready(s, cs, q, x, p,
        Bool.and(Bool.and(S.Store.ready(s), Caches.ready(cs)), Bool.not(Ctl.stopping(p))))

def Ctl.halt.go(p: Maybe<&2, Chan(Unit)>, idle: Bool) -> Maybe<&2, Chan(Unit)>:
  match idle:
    case True{}:
      p
    case False{}:
      None{}

# Whose stop request to answer: a stopping controller with nothing running.
def Ctl.halt(st: CState) -> Maybe<&2, Chan(Unit)>:
  match st:
    case CState{s, cs, +q, x, p}:
      Ctl.halt.go(p, U32.is_eq(Q.Queue.nrun(q), 0))

def Ctl.snap(st: CState, name: String) -> Snap:
  match st:
    case CState{+s, +cs, +q, Stats{r, e, v, h, sm}, p}:
      Snap{name, Bool.and(S.Store.ready(s), Caches.ready(cs)), r, e, v, Q.Queue.nrun(q),
        U32.from_nat(S.Store.size(s)), Q.Queue.depth(q), h, sm}

def Ctl.timers(ts: List<&2, Q.Timer>, +chan: Chan(Msg)) -> IO(Unit):
  match ts:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{Q.Timer{key, g, ms}, t}:
      IO.bind(Unit, Unit,
        IO.spawn(Result<&1, &1, Msg, Unit>,
          IO.bind(Unit, Result<&1, &1, Msg, Unit>, IO.sleep(ms),
            u => Chan.send(Msg, chan, MWake{key, g}))),
        u => Ctl.timers(t, chan))

def CCtx.chan(c: CCtx) -> Chan(Msg):
  match c:
    case CCtx{cfg, sp, ch, st, ix}:
      ch

def CCtx.cfg(c: CCtx) -> K.Config:
  match c:
    case CCtx{cfg, sp, ch, st, ix}:
      cfg

def CCtx.spec(c: CCtx) -> X.Spec:
  match c:
    case CCtx{cfg, sp, ch, st, ix}:
      sp

def CCtx.status(c: CCtx) -> Chan(SMsg):
  match c:
    case CCtx{cfg, sp, ch, st, ix}:
      st

def CCtx.idx(c: CCtx) -> U32:
  match c:
    case CCtx{cfg, sp, ch, st, ix}:
      ix

def CCtx.kind(c: CCtx) -> String:
  X.Spec.kind(CCtx.spec(c))

# What a reconcile sees: the config, the controller's index and the caches.
def Ctl.ctx(st: CState, +c: CCtx) -> X.Ctx:
  match st:
    case CState{s, cs, q, x, p}:
      X.Ctx{CCtx.cfg(c), CCtx.idx(c), s, cs}

def Ctl.report(+key: String, +kind: String, a: Q.Action) -> IO(Unit):
  match a:
    case Q.Retry{m}:
      L.Log.warn("reconcile failed; retrying with backoff",
        [L.Log.kv("kind", kind), L.Log.kv("key", key), L.Log.kv("error", m)])
    case _:
      IO.pure(Unit, Unit{})

def Ctl.now(w: U32 & (U32 & U32)) -> U32:
  T.Wall.ms(T.Wall.of(w))

def Ctl.job.end(+key: String, +a: Q.Action, +t0: U32, +kind: String, +chan: Chan(Msg)) ->
  IO(Result<&1, &1, Msg, Unit>):
  IO.bind(U32 & (U32 & U32), Result<&1, &1, Msg, Unit>, Y.Sys.wall(),
    w1 => IO.bind(Unit, Result<&1, &1, Msg, Unit>, Ctl.report(key, kind, a),
      u => Chan.send(Msg, chan, MDone{key, a, (Ctl.now(w1) - t0 : U32)})))

def Ctl.job.go(~rec: J.Json -> X.Ctx -> IO(Q.Action), +key: String, o: J.Json, +ctx: X.Ctx,
  +kind: String, +chan: Chan(Msg), +t0: U32) -> IO(Result<&1, &1, Msg, Unit>):
  IO.bind(Q.Action, Result<&1, &1, Msg, Unit>, rec(o, ctx), a => Ctl.job.end(key, a, t0, kind, chan))

# A reconcile, timed; a failure is logged; MDone answers on the channel.
def Ctl.job(~rec: J.Json -> X.Ctx -> IO(Q.Action), +key: String, o: J.Json, +ctx: X.Ctx,
  +kind: String, +chan: Chan(Msg)) -> IO(Result<&1, &1, Msg, Unit>):
  IO.bind(U32 & (U32 & U32), Result<&1, &1, Msg, Unit>, Y.Sys.wall(),
    w0 => Ctl.job.go(~rec, key, o, ctx, kind, chan, Ctl.now(w0)))

# Starts a reconcile per job; each answers MDone on the channel.
def Ctl.spawn(~rec: J.Json -> X.Ctx -> IO(Q.Action), jobs: List<&2, Job>, +chan: Chan(Msg),
  +ctx: X.Ctx, +kind: String) -> IO(Unit):
  match jobs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{Job{key, o}, t}:
      IO.bind(Unit, Unit,
        IO.spawn(Result<&1, &1, Msg, Unit>, Ctl.job(~rec, key, o, ctx, kind, chan)),
        u => Ctl.spawn(~rec, t, chan, ctx, kind))

def Ctl.name(+c: CCtx) -> String:
  U32.show(CCtx.idx(c)) ++ "/" ++ CCtx.kind(c)

# The controller loop: a message in, the state stepped, timers armed,
# reconciles started, the next message awaited; a stop request is answered
# once nothing runs, and ends the loop.
def Ctl.run(~rec: J.Json -> X.Ctx -> IO(Q.Action), fuel: Nat, ev: CEv, +st: CState,
  +ctx: CCtx) -> IO(Unit):
  match fuel ev:
    case 0n e:
      IO.pure(Unit, Unit{})
    case 1n+f CMsg{None{}}:
      IO.pure(Unit, Unit{})
    case 1n+f CMsg{Some{m}}:
      Ctl.run(~rec, f, CHandled{Ctl.on_msg(st, m, CCtx.spec(ctx))}, st, ctx)
    case 1n+f CHandled{(+st1, ts)}:
      IO.bind(Unit, Unit, Ctl.timers(ts, CCtx.chan(ctx)),
        u => Ctl.run(~rec, f, CDisp{Ctl.dispatch(st1)}, st1, ctx))
    case 1n+f CDisp{(+st2, jobs)}:
      IO.bind(Unit, Unit, Ctl.spawn(~rec, jobs, CCtx.chan(ctx), Ctl.ctx(st2, ctx), CCtx.kind(ctx)),
        u => IO.bind(Result<&1, &1, SMsg, Unit>, Unit,
          Chan.send(SMsg, CCtx.status(ctx), SPut{CCtx.idx(ctx), Ctl.snap(st2, Ctl.name(ctx))}),
          u2 => Ctl.run(~rec, f, CNext{Ctl.halt(st2)}, st2, ctx)))
    case 1n+f CNext{Some{r}}:
      IO.bind(Result<&1, &1, Unit, Unit>, Unit, Chan.send(Unit, r, Unit{}),
        u => L.Log.info("controller stopped", [L.Log.kv("controller", Ctl.name(ctx))]))
    case 1n+f CNext{None{}}:
      IO.bind(Maybe<&1, Msg>, Unit, Chan.recv(Msg, CCtx.chan(ctx)),
        m => Ctl.run(~rec, f, CMsg{m}, st, ctx))

def Ctl.watch.subs(+cfg: K.Config, api: C.Api, label: String, subs: List<&2, Sub>) -> IO(Unit):
  IO.spawn(Unit, Drv.run(4294967295n, DStart{}, W.WState.init(), H.Http.resp.init(), Nil{},
    WCtx{cfg, api, label, "", subs}))

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
      Keeper.all.put(Map.get(Snap, Snap{"", False{}, 0, 0, 0, 0, 0, 0, Hist.zero(), 0}, m, k),
        Keeper.all.go(t, m))

def Keeper.all(+m: Map<&2, Snap>) -> List<&2, Snap>:
  Keeper.all.go(Map.keys(&2, Snap, m), m)

# The status keeper: holds each controller's latest snapshot and answers
# queries at once.
def Keeper.run(fuel: Nat, m: Maybe<&1, SMsg>, +last: Map<&2, Snap>, +inbox: Chan(SMsg)) -> IO(Unit):
  match fuel m:
    case 0n x:
      IO.pure(Unit, Unit{})
    case 1n+f None{}:
      IO.pure(Unit, Unit{})
    case 1n+f Some{SPut{i, s}}:
      IO.bind(Maybe<&1, SMsg>, Unit, Chan.recv(SMsg, inbox),
        x => Keeper.run(f, x, Map.set(&2, Snap, last, U32.show(i), s), inbox))
    case 1n+f Some{SGet{r}}:
      IO.bind(Result<&1, &1, List<&2, Snap>, Unit>, Unit,
        Chan.send(List<&2, Snap>, r, Keeper.all(last)),
        u => IO.bind(Maybe<&1, SMsg>, Unit, Chan.recv(SMsg, inbox), x => Keeper.run(f, x, last, inbox)))

# Starts a status keeper; answers its inbox.
def Keeper.start() -> IO(Chan(SMsg)):
  IO.bind(Chan(SMsg), Chan(SMsg), Chan.new(SMsg, 4096),
    +c => IO.bind(Unit, Chan(SMsg), IO.spawn(Unit,
      IO.bind(Maybe<&1, SMsg>, Unit, Chan.recv(SMsg, c),
        x => Keeper.run(4294967295n, x, Map.new(&2, Snap), c))), u => IO.pure(Chan(SMsg), c)))

def Keeper.answer(m: Poll<&1, &1, Maybe<&1, List<&2, Snap>>, Unit>) -> List<&2, Snap>:
  match m:
    case Ready{Some{ss}}:
      ss
    case _:
      Nil{}

# Every controller's latest snapshot (none on a standby replica, or if the
# keeper does not answer within 500ms).
def Keeper.query(+status: Chan(SMsg)) -> IO(List<&2, Snap>):
  IO.bind(Chan(List<&2, Snap>), List<&2, Snap>, Chan.new(List<&2, Snap>, 1),
    +c => IO.bind(Result<&1, &1, SMsg, Unit>, List<&2, Snap>,
      Chan.send(SMsg, status, SGet{c}),
      u => IO.bind(Poll<&1, &1, Maybe<&1, List<&2, Snap>>, Unit>, List<&2, Snap>,
        Chan.try_recv(List<&2, Snap>, c, 500),
        m => IO.pure(List<&2, Snap>, Keeper.answer(m)))))

def Ctl.loop(~rec: J.Json -> X.Ctx -> IO(Q.Action), +cfg: K.Config, +spec: X.Spec,
  +chan: Chan(Msg), +status: Chan(SMsg), +idx: U32) -> IO(Unit):
  Ctl.run(~rec, 4294967295n,
    CDisp{(CState{S.Store.new(),
      List.replicate(S.Store, List.length(&2, X.Sec, X.Spec.secs(spec)), S.Store.new()),
      Q.Queue.new(X.Spec.max_of(spec)), Stats{0, 0, 0, Hist.zero(), 0}, None{}}, Nil{})},
    CState{S.Store.new(), Nil{}, Q.Queue.new(X.Spec.max_of(spec)), Stats{0, 0, 0, Hist.zero(), 0},
      None{}},
    CCtx{cfg, spec, chan, status, idx})

def Controller.inbox() -> IO(Chan(Msg)):
  Chan.new(Msg, 4096)

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

type Watch is Data:
  Watch{api: C.Api, label: String, subs: List<&2, Sub>}

def Watch.key(+api: C.Api, +label: String) -> String:
  C.Api.path(api) ++ "?" ++ label

def Plan.hit(ws: List<&2, Watch>, +key: String) -> Bool:
  match ws:
    case Con{Watch{+a, +l, s}, t}:
      String.eq(Watch.key(a, l), key)
    case _:
      False{}

# Adds a subscription: to the watch of the same key, or as a new watch.
def Plan.add(ws: List<&2, Watch>, +api: C.Api, +label: String, +sub: Sub, hit: Bool) -> List<&2, Watch>:
  match ws hit:
    case Con{Watch{a, l, ss}, t} True{}:
      Watch{a, l, List.append(&2, Sub, ss, [sub])} <> t
    case Con{+w, +t} False{}:
      w <> Plan.add(t, api, label, sub, Plan.hit(t, Watch.key(api, label)))
    case Nil{} _:
      [Watch{api, label, [sub]}]

def Plan.sub(+ws: List<&2, Watch>, +api: C.Api, +label: String, +sub: Sub) -> List<&2, Watch>:
  Plan.add(ws, api, label, sub, Plan.hit(ws, Watch.key(api, label)))

def Plan.secs(ss: List<&2, X.Sec>, +ch: Chan(Msg), +n: U32, ws: List<&2, Watch>) -> List<&2, Watch>:
  match ss:
    case Nil{}:
      ws
    case Con{X.Sec{a, l, r}, t}:
      Plan.secs(t, ch, (n + 1 : U32), Plan.sub(ws, a, l, Sub{ch, n}))

# Every watch the controllers need, each once, with all its subscribers.
def Plan.build(cs: List<&2, X.Spec>, chs: List<&2, Chan(Msg)>, ws: List<&2, Watch>) -> List<&2, Watch>:
  match cs chs:
    case Con{X.Spec{p, l, ps, ss, m}, t} Con{+ch, ct}:
      Plan.build(t, ct, Plan.secs(ss, ch, 1, Plan.sub(ws, p, l, Sub{ch, 0})))
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
    case Con{Watch{a, l, ss}, t}:
      IO.bind(Unit, Unit, Ctl.watch.subs(cfg, a, l, ss), u => Manager.watch(cfg, t))

def Manager.loops(~rec: J.Json -> X.Ctx -> IO(Q.Action), +cfg: K.Config, cs: List<&2, X.Spec>,
  chs: List<&2, Chan(Msg)>, +status: Chan(SMsg), +i: U32) -> IO(Unit):
  match cs chs:
    case Con{s, t} Con{ch, ct}:
      IO.bind(Unit, Unit, IO.spawn(Unit, Ctl.loop(~rec, cfg, s, ch, status, i)),
        u => Manager.loops(~rec, cfg, t, ct, status, (i + 1 : U32)))
    case _ _:
      IO.pure(Unit, Unit{})

# Runs every controller on its inbox (Manager.inboxes), sharing their
# watches. rec(obj, ctx) reconciles obj; X.Ctx.idx(ctx) names the
# controller.
def Manager.start(~rec: J.Json -> X.Ctx -> IO(Q.Action), +cfg: K.Config, +cs: List<&2, X.Spec>,
  +chs: List<&2, Chan(Msg)>, +status: Chan(SMsg)) -> IO(Unit):
  IO.bind(Unit, Unit, Manager.watch(cfg, Plan.build(cs, chs, Nil{})),
    u => Manager.loops(~rec, cfg, cs, chs, status, 0))

# Stopping
# --------

def Stop.ask(chs: List<&2, Chan(Msg)>) -> IO(List<&2, Chan(Unit)>):
  match chs:
    case Nil{}:
      IO.pure(List<&2, Chan(Unit)>, Nil{})
    case Con{ch, t}:
      IO.bind(Chan(Unit), List<&2, Chan(Unit)>, Chan.new(Unit, 1),
        +r => IO.bind(Result<&1, &1, Msg, Unit>, List<&2, Chan(Unit)>, Chan.send(Msg, ch, MStop{r}),
          u => IO.bind(List<&2, Chan(Unit)>, List<&2, Chan(Unit)>, Stop.ask(t),
            rest => IO.pure(List<&2, Chan(Unit)>, r <> rest))))

def Stop.wait(rs: List<&2, Chan(Unit)>) -> IO(Unit):
  match rs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{r, t}:
      IO.bind(Maybe<&1, Unit>, Unit, Chan.recv(Unit, r), u => Stop.wait(t))

def Stop.said(m: Maybe<&1, Unit>) -> IO(Unit):
  match m:
    case Some{u}:
      L.Log.info("reconciles drained", Nil{})
    case None{}:
      L.Log.warn("reconciles still running at the grace deadline; stopping anyway", Nil{})

def Stop.drain(chs: List<&2, Chan(Msg)>, +grace: U32, ss: List<&2, Snap>) -> IO(Unit):
  match ss:
    case Nil{}:
      # a standby replica runs no controller
      IO.pure(Unit, Unit{})
    case xs:
      IO.bind(Unit, Unit, L.Log.info("draining reconciles", [L.Log.kv("grace_ms", U32.show(grace))]),
        u => IO.bind(List<&2, Chan(Unit)>, Unit, Stop.ask(chs),
          rs => IO.bind(Maybe<&1, Unit>, Unit, IO.within(Unit, grace, Stop.wait(rs)), Stop.said)))

# Asks every running controller to stop: no new reconciles start, and this
# returns once the running ones finish, or after grace ms.
def Manager.stop(chs: List<&2, Chan(Msg)>, +status: Chan(SMsg), +grace: U32) -> IO(Unit):
  IO.bind(List<&2, Snap>, Unit, Keeper.query(status), ss => Stop.drain(chs, grace, ss))
