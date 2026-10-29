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
  MDone{key: String, act: Q.Action}
  MWake{key: String, gen: U32}

# The controller's state as the health server reports it.
type Snap is Data:
  Snap{name: String, ready: Bool, reconciles: U32, errors: U32, events: U32, running: U32,
    objects: U32}

# The status keeper's inbox: a controller's latest snapshot (by its index),
# or a query for all of them (none until a controller runs: a standby
# replica).
type SMsg is Data:
  SPut{idx: U32, snap: Snap}
  SGet{reply: Chan(List<&2, Snap>)}

# Counters since start.
type Stats is Data:
  Stats{reconciles: U32, errors: U32, events: U32}

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

type CState is Data:
  CState{store: S.Store, queue: Q.Queue, stats: Stats}

type CCtx is Data:
  CCtx{cfg: K.Config, kind: String, chan: Chan(Msg), status: Chan(SMsg), idx: U32}

# A reconcile to start: the key and the object the store holds for it.
type Job is Data:
  Job{key: String, obj: J.Json}

# What the controller loop just saw.
type CEv is Type:
  CMsg{m: Maybe<&1, Msg>}
  CHandled{r: CState & List<&2, Q.Timer>}
  CDisp{r: CState & List<&2, Job>}

# The keys a primary watcher's outputs trigger: every object it applies.
# Deletions trigger nothing; finalizers are how a reconciler sees them.
def Ctl.self_keys(outs: List<&2, W.Out>) -> List<&2, String>:
  match outs:
    case Nil{}:
      Nil{}
    case Con{W.OApply{+o}, t}:
      C.Obj.key(o) <> Ctl.self_keys(t)
    case Con{W.OInitApply{+o}, t}:
      C.Obj.key(o) <> Ctl.self_keys(t)
    case Con{o, t}:
      Ctl.self_keys(t)

# The keys of objects a primary watcher saw deleted.
def Ctl.gone_keys(outs: List<&2, W.Out>) -> List<&2, String>:
  match outs:
    case Nil{}:
      Nil{}
    case Con{W.ODelete{+o}, t}:
      C.Obj.key(o) <> Ctl.gone_keys(t)
    case Con{o, t}:
      Ctl.gone_keys(t)

def Ctl.ref_keys(rs: List<&2, C.ObjRef>) -> List<&2, String>:
  match rs:
    case Nil{}:
      Nil{}
    case Con{r, t}:
      C.ObjRef.key(r) <> Ctl.ref_keys(t)

def Ctl.out_obj(o: W.Out) -> Maybe<&2, J.Json>:
  match o:
    case W.OApply{x}:
      Some{x}
    case W.OInitApply{x}:
      Some{x}
    case W.ODelete{x}:
      Some{x}
    case _:
      None{}

def Ctl.owner_keys.put(m: Maybe<&2, J.Json>, +kind: String, rest: List<&2, String>) ->
  List<&2, String>:
  match m:
    case Some{+x}:
      List.append(&2, String, Ctl.ref_keys(C.Obj.owners(x, kind)), rest)
    case None{}:
      rest

# The keys an owned watcher's outputs trigger: the owners of the kind
# every changed object names (kube-runtime's Controller::owns), deletions
# included.
def Ctl.owner_keys(outs: List<&2, W.Out>, +kind: String) -> List<&2, String>:
  match outs:
    case Nil{}:
      Nil{}
    case Con{o, t}:
      Ctl.owner_keys.put(Ctl.out_obj(o), kind, Ctl.owner_keys(t, kind))

def Stats.count(+n: Nat) -> U32:
  U32.from_nat(n)

def Stats.events(x: Stats, +n: U32) -> Stats:
  match x:
    case Stats{r, e, +v}:
      Stats{r, e, (v + n : U32)}

def Stats.done(x: Stats, a: Q.Action) -> Stats:
  match x a:
    case Stats{+r, +e, v} Q.Retry{m}:
      Stats{(r + 1 : U32), (e + 1 : U32), v}
    case Stats{+r, e, v} _:
      Stats{(r + 1 : U32), e, v}

def Ctl.on_outs(st: CState, +src: U32, +outs: List<&2, W.Out>, +kind: String, own: Bool) -> CState:
  match st own:
    case CState{s, q, x} True{}:
      CState{S.Store.apply_all(outs, s),
        Q.Queue.forget_all(Ctl.gone_keys(outs), Q.Queue.add_all(Ctl.self_keys(outs), q)),
        Stats.events(x, U32.from_nat(List.length(&2, W.Out, outs)))}
    case CState{s, q, x} False{}:
      CState{s, Q.Queue.add_all(Ctl.owner_keys(outs, kind), q),
        Stats.events(x, U32.from_nat(List.length(&2, W.Out, outs)))}

def Ctl.on_done(s: S.Store, x: Stats, r: Q.Queue & List<&2, Q.Timer>) ->
  CState & List<&2, Q.Timer>:
  match r:
    case (q, ts):
      (CState{s, q, x}, ts)

def Ctl.on_done.st(st: CState, key: String, +a: Q.Action) -> CState & List<&2, Q.Timer>:
  match st:
    case CState{s, q, x}:
      Ctl.on_done(s, Stats.done(x, a), Q.Queue.done(q, key, a))

def Ctl.on_wake(st: CState, key: String, g: U32) -> CState & List<&2, Q.Timer>:
  match st:
    case CState{s, q, x}:
      (CState{s, Q.Queue.wake(q, key, g), x}, Nil{})

# A message's effect on the state, and the timers it arms.
def Ctl.on_msg(st: CState, m: Msg, +kind: String) -> CState & List<&2, Q.Timer>:
  match m:
    case MOuts{+src, outs}:
      (Ctl.on_outs(st, src, outs, kind, U32.is_eq(src, 0)), Nil{})
    case MDone{key, a}:
      Ctl.on_done.st(st, key, a)
    case MWake{key, g}:
      Ctl.on_wake(st, key, g)

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

def Ctl.dispatch.wrap(s: S.Store, x: Stats, r: Q.Queue & List<&2, Job>) -> CState & List<&2, Job>:
  match r:
    case (q, jobs):
      (CState{s, q, x}, jobs)

def Ctl.dispatch.fin(+s: S.Store, x: Stats, r: Q.Queue & List<&2, String>) ->
  CState & List<&2, Job>:
  match r:
    case (q, ks):
      Ctl.dispatch.wrap(s, x, Ctl.dispatch.go(ks, s, (q, Nil{})))

def Ctl.dispatch.ready(+s: S.Store, q: Q.Queue, x: Stats, ready: Bool) -> CState & List<&2, Job>:
  match ready:
    case True{}:
      Ctl.dispatch.fin(s, x, Q.Queue.pop_all(64n, q, Nil{}))
    case False{}:
      (CState{s, q, x}, Nil{})

# The reconciles to start now: none until the store has its first list.
def Ctl.dispatch(st: CState) -> CState & List<&2, Job>:
  match st:
    case CState{+s, q, x}:
      Ctl.dispatch.ready(s, q, x, S.Store.ready(s))

def Ctl.snap(st: CState, name: String) -> Snap:
  match st:
    case CState{+s, +q, Stats{r, e, v}}:
      Snap{name, S.Store.ready(s), r, e, v, Q.Queue.nrun(q), U32.from_nat(S.Store.size(s))}

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
    case CCtx{cfg, k, ch, st, ix}:
      ch

def CCtx.cfg(c: CCtx) -> K.Config:
  match c:
    case CCtx{cfg, k, ch, st, ix}:
      cfg

def CCtx.status(c: CCtx) -> Chan(SMsg):
  match c:
    case CCtx{cfg, k, ch, st, ix}:
      st

def CCtx.idx(c: CCtx) -> U32:
  match c:
    case CCtx{cfg, k, ch, st, ix}:
      ix

def CCtx.kind(c: CCtx) -> String:
  match c:
    case CCtx{cfg, k, ch, st, ix}:
      k

# Starts a reconcile per job; each answers MDone on the channel.
def Ctl.spawn(~rec: U32 -> J.Json -> K.Config -> IO(Q.Action), jobs: List<&2, Job>, +chan: Chan(Msg),
  +cfg: K.Config, +idx: U32) -> IO(Unit):
  match jobs:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{Job{key, o}, t}:
      IO.bind(Unit, Unit,
        IO.spawn(Result<&1, &1, Msg, Unit>,
          IO.bind(Q.Action, Result<&1, &1, Msg, Unit>, rec(idx, o, cfg),
            a => Chan.send(Msg, chan, MDone{key, a}))),
        u => Ctl.spawn(~rec, t, chan, cfg, idx))

# The controller loop: a message in, the state stepped, timers armed,
# reconciles started, the next message awaited.
def Ctl.run(~rec: U32 -> J.Json -> K.Config -> IO(Q.Action), fuel: Nat, ev: CEv, +st: CState,
  +ctx: CCtx) -> IO(Unit):
  match fuel ev:
    case 0n e:
      IO.pure(Unit, Unit{})
    case 1n+f CMsg{None{}}:
      IO.pure(Unit, Unit{})
    case 1n+f CMsg{Some{m}}:
      Ctl.run(~rec, f, CHandled{Ctl.on_msg(st, m, CCtx.kind(ctx))}, st, ctx)
    case 1n+f CHandled{(+st1, ts)}:
      IO.bind(Unit, Unit, Ctl.timers(ts, CCtx.chan(ctx)),
        u => Ctl.run(~rec, f, CDisp{Ctl.dispatch(st1)}, st1, ctx))
    case 1n+f CDisp{(+st2, jobs)}:
      IO.bind(Unit, Unit, Ctl.spawn(~rec, jobs, CCtx.chan(ctx), CCtx.cfg(ctx), CCtx.idx(ctx)),
        u => IO.bind(Result<&1, &1, SMsg, Unit>, Unit,
          Chan.send(SMsg, CCtx.status(ctx), SPut{CCtx.idx(ctx), Ctl.snap(st2, U32.show(CCtx.idx(ctx)) ++ "/" ++ CCtx.kind(ctx))}),
          u2 => IO.bind(Maybe<&1, Msg>, Unit, Chan.recv(Msg, CCtx.chan(ctx)),
            m => Ctl.run(~rec, f, CMsg{m}, st2, ctx))))

def Ctl.watch.subs(+cfg: K.Config, api: C.Api, label: String, subs: List<&2, Sub>) -> IO(Unit):
  IO.spawn(Unit, Drv.run(4294967295n, DStart{}, W.WState.init(), H.Http.resp.init(), Nil{},
    WCtx{cfg, api, label, "", subs}))

def Ctl.watch(+cfg: K.Config, api: C.Api, label: String, +src: U32, +chan: Chan(Msg)) -> IO(Unit):
  IO.spawn(Unit, Drv.run(4294967295n, DStart{}, W.WState.init(), H.Http.resp.init(), Nil{},
    WCtx{cfg, api, label, "", [Sub{chan, src}]}))

def Ctl.watch_all(apis: List<&2, C.Api>, +n: U32, +cfg: K.Config, +chan: Chan(Msg)) -> IO(Unit):
  match apis:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{a, t}:
      IO.bind(Unit, Unit, Ctl.watch(cfg, a, "", n, chan),
        u => Ctl.watch_all(t, (n + 1 : U32), cfg, chan))

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
      Keeper.all.put(Map.get(Snap, Snap{"", False{}, 0, 0, 0, 0, 0}, m, k), Keeper.all.go(t, m))

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

def Ctl.loop(~rec: U32 -> J.Json -> K.Config -> IO(Q.Action), +cfg: K.Config, +primary: C.Api, +max: U32,
  +chan: Chan(Msg), +status: Chan(SMsg), +idx: U32) -> IO(Unit):
  Ctl.run(~rec, 4294967295n,
    CDisp{(CState{S.Store.new(), Q.Queue.new(max), Stats{0, 0, 0}}, Nil{})},
    CState{S.Store.new(), Q.Queue.new(max), Stats{0, 0, 0}},
    CCtx{cfg, Api.kind(primary), chan, status, idx})

# Runs a controller (kube-runtime's Controller::new(..).owns(..).run(..)):
# primary is watched (only objects matching the label selector, "" for
# all) and reconciled, each of owned is watched and mapped to
# its owners of primary's kind; at most max reconciles run at once. rec
# answers what to do next for the object, as kube-runtime's Action. chan
# is the controller's inbox (Controller.inbox); status receives a snapshot
# after every step (Keeper.start).
def Controller.start(~rec: J.Json -> K.Config -> IO(Q.Action), +cfg: K.Config, +primary: C.Api,
  label: String, owned: List<&2, C.Api>, +max: U32, +chan: Chan(Msg), +status: Chan(SMsg)) ->
  IO(Unit):
  do IO<Unit>:
    Ctl.watch(cfg, primary, label, 0, chan)
    Ctl.watch_all(owned, 1, cfg, chan)
    Ctl.loop(~(i => o => c => rec(o, c)), cfg, primary, max, chan, status, 0)

def Controller.inbox() -> IO(Chan(Msg)):
  Chan.new(Msg, 4096)

# Manager
# -------
#
# Several controllers in one process (controller-runtime's Manager, with
# kube-runtime's shared reflectors): each runs its own loop, store and
# queue, but a watch they share (the same resource, scope and label
# selector) runs once, and its outputs fan out to every controller that
# subscribed, so the API server sees one list and one watch per resource.

# A controller of a manager: its primary watch (with a label selector), the
# kinds it owns, and how many reconciles it runs at once. A manager's
# reconcile gets the controller's index (its place in the list) first.
type Ctrl is Data:
  Ctrl{primary: C.Api, label: String, owned: List<&2, C.Api>, max: U32}

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

def Plan.owned(os: List<&2, C.Api>, +ch: Chan(Msg), +n: U32, ws: List<&2, Watch>) -> List<&2, Watch>:
  match os:
    case Nil{}:
      ws
    case Con{a, t}:
      Plan.owned(t, ch, (n + 1 : U32), Plan.sub(ws, a, "", Sub{ch, n}))

# Every watch the controllers need, each once, with all its subscribers.
def Plan.build(cs: List<&2, Ctrl>, chs: List<&2, Chan(Msg)>, ws: List<&2, Watch>) -> List<&2, Watch>:
  match cs chs:
    case Con{Ctrl{p, l, os, m}, t} Con{+ch, ct}:
      Plan.build(t, ct, Plan.owned(os, ch, 1, Plan.sub(ws, p, l, Sub{ch, 0})))
    case _ _:
      ws

def Manager.inboxes(cs: List<&2, Ctrl>) -> IO(List<&2, Chan(Msg)>):
  match cs:
    case Nil{}:
      IO.pure(List<&2, Chan(Msg)>, Nil{})
    case Con{c, t}:
      IO.bind(Chan(Msg), List<&2, Chan(Msg)>, Controller.inbox(),
        ch => IO.bind(List<&2, Chan(Msg)>, List<&2, Chan(Msg)>, Manager.inboxes(t),
          rest => IO.pure(List<&2, Chan(Msg)>, ch <> rest)))

def Manager.watch(+cfg: K.Config, ws: List<&2, Watch>) -> IO(Unit):
  match ws:
    case Nil{}:
      IO.pure(Unit, Unit{})
    case Con{Watch{a, l, ss}, t}:
      IO.bind(Unit, Unit, Ctl.watch.subs(cfg, a, l, ss), u => Manager.watch(cfg, t))

def Manager.loops(~rec: U32 -> J.Json -> K.Config -> IO(Q.Action), +cfg: K.Config, cs: List<&2, Ctrl>,
  chs: List<&2, Chan(Msg)>, +status: Chan(SMsg), +i: U32) -> IO(Unit):
  match cs chs:
    case Con{Ctrl{p, l, os, m}, t} Con{ch, ct}:
      IO.bind(Unit, Unit, IO.spawn(Unit, Ctl.loop(~rec, cfg, p, m, ch, status, i)),
        u => Manager.loops(~rec, cfg, t, ct, status, (i + 1 : U32)))
    case _ _:
      IO.pure(Unit, Unit{})

# Runs every controller, sharing their watches. rec(i, obj, cfg) reconciles
# obj for controller i.
def Manager.start(~rec: U32 -> J.Json -> K.Config -> IO(Q.Action), +cfg: K.Config, +cs: List<&2, Ctrl>,
  +status: Chan(SMsg)) -> IO(Unit):
  IO.bind(List<&2, Chan(Msg)>, Unit, Manager.inboxes(cs),
    +chs => IO.bind(Unit, Unit, Manager.watch(cfg, Plan.build(cs, chs, Nil{})),
      u => Manager.loops(~rec, cfg, cs, chs, status, 0)))
