import Base
import ./json.bend as J
import ./core.bend as C

# Watcher
# =======
#
# kube-runtime's watcher as a pure state machine, with client-go's
# reflector deciding how the API behaves:
#
# - A watcher starts by listing in pages (limit + continue) and then watches
#   from the list's resourceVersion, with bookmarks, resuming from the last
#   version it saw whenever a watch ends (the server's timeoutSeconds).
# - A 410 Gone (an expired version, on a watch or a continue token) relists
#   from scratch at once, as the reflector does; the store swaps in the new
#   list whole, so objects deleted meanwhile disappear.
# - Other failures retry the same step after an exponential backoff
#   (800ms doubling to 30s, as both kube-rs and client-go default to);
#   success resets it.
# - resourceVersion is opaque: it is only ever copied, never compared.
#
# The IO driver (runtime.bend) performs the action a state asks for, feeds
# the outcome back as an input, and hands the outputs to the store.

# What to do next: list (from a continue token, "" for the first page) or
# watch from a version.
type Phase is Data:
  WList{cont: String}
  WWatch{rv: String}

# fails counts failures since the last success; first says the next page
# starts a fresh list.
type WState is Data:
  WState{phase: Phase, fails: U32, first: Bool}

type Input is Data:
  IPage{page: C.Page}
  IListErr{code: U32}
  IEvent{ev: C.WEvent}
  IWatchEnd{}
  IWatchErr{code: U32}

# What the store and controller see (kube-runtime's watcher::Event).
type Out is Data:
  OInit{}
  OInitApply{obj: J.Json}
  OInitDone{}
  OApply{obj: J.Json}
  ODelete{obj: J.Json}

# A step's result: the next state, its outputs in order, and whether the
# driver must back off before the next action.
type Step is Data:
  Step{state: WState, outs: List<&2, Out>, wait: Bool}

def WState.init() -> WState:
  WState{WList{""}, 0, True{}}

def Backoff.delay.go(+fails: U32, capped: Bool) -> U32:
  match capped:
    case True{}:
      30000
    case False{}:
      U32.min((800 << U32.to_nat((fails - 1 : U32)) : U32), 30000)

# Backoff
# -------

# The delay before the next try after fails failures: 800ms doubling, at
# most 30s. The driver adds jitter.
def Backoff.delay(+fails: U32) -> U32:
  Backoff.delay.go(fails, U32.is_ge(fails, 6))

# Steps
# -----

def Watcher.page_outs(xs: List<&2, J.Json>, tail: List<&2, Out>) -> List<&2, Out>:
  match xs:
    case Nil{}:
      tail
    case Con{x, t}:
      OInitApply{x} <> Watcher.page_outs(t, tail)

def Watcher.init_out(first: Bool, rest: List<&2, Out>) -> List<&2, Out>:
  match first:
    case True{}:
      OInit{} <> rest
    case False{}:
      rest

def Watcher.done_out(last: Bool) -> List<&2, Out>:
  match last:
    case True{}:
      [OInitDone{}]
    case False{}:
      Nil{}

def Watcher.page_phase(rv: String, +cont: String, last: Bool) -> Phase:
  match last:
    case True{}:
      WWatch{rv}
    case False{}:
      WList{cont}

def Watcher.page.go(first: Bool, items: List<&2, J.Json>, rv: String, +cont: String,
  +last: Bool) -> Step:
  Step{WState{Watcher.page_phase(rv, cont, last), 0, last},
    Watcher.init_out(first, Watcher.page_outs(items, Watcher.done_out(last))), False{}}

# A page of the list: the first page opens a relist (Init), the last one
# (no continue token) closes it (InitDone) and starts the watch.
def Watcher.page(first: Bool, p: C.Page) -> Step:
  match p:
    case C.Page{items, rv, +cont}:
      Watcher.page.go(first, items, rv, cont, String.is_empty(cont))

def Watcher.is_gone(+code: U32) -> Bool:
  U32.is_eq(code, 410)

def Watcher.relist(+fails: U32) -> Step:
  Step{WState{WList{""}, fails, True{}}, Nil{}, False{}}

def Watcher.retry(p: Phase, +fails: U32, first: Bool) -> Step:
  Step{WState{p, (fails + 1 : U32), first}, Nil{}, True{}}

# A failed list: an expired continue token relists; else the same page is
# retried after a backoff.
def Watcher.list_err(cont: String, +fails: U32, first: Bool, gone: Bool) -> Step:
  match gone:
    case True{}:
      Watcher.relist(fails)
    case False{}:
      Watcher.retry(WList{cont}, fails, first)

def Watcher.watch_err(rv: String, +fails: U32, gone: Bool) -> Step:
  match gone:
    case True{}:
      Watcher.relist(fails)
    case False{}:
      Watcher.retry(WWatch{rv}, fails, False{})

# One watch event while watching from rv.
def Watcher.event(rv: String, +fails: U32, ev: C.WEvent) -> Step:
  match ev:
    case C.WAdded{+o}:
      Step{WState{WWatch{C.Obj.rv(o)}, 0, False{}}, [OApply{o}], False{}}
    case C.WModified{+o}:
      Step{WState{WWatch{C.Obj.rv(o)}, 0, False{}}, [OApply{o}], False{}}
    case C.WDeleted{+o}:
      Step{WState{WWatch{C.Obj.rv(o)}, 0, False{}}, [ODelete{o}], False{}}
    case C.WBookmark{v}:
      Step{WState{WWatch{v}, 0, False{}}, Nil{}, False{}}
    case C.WError{C.Status{+code, r, m}}:
      Watcher.watch_err(rv, fails, Watcher.is_gone(code))
    case C.WBad{m}:
      Watcher.retry(WWatch{rv}, fails, False{})

# The state machine.
def Watcher.step(st: WState, i: Input) -> Step:
  match st i:
    case WState{WList{c}, f, first} IPage{p}:
      Watcher.page(first, p)
    case WState{WList{c}, +f, first} IListErr{+code}:
      Watcher.list_err(c, f, first, Watcher.is_gone(code))
    case WState{WWatch{rv}, +f, first} IEvent{ev}:
      Watcher.event(rv, f, ev)
    case WState{WWatch{rv}, f, first} IWatchEnd{}:
      Step{WState{WWatch{rv}, 0, False{}}, Nil{}, False{}}
    case WState{WWatch{rv}, +f, first} IWatchErr{+code}:
      Watcher.watch_err(rv, f, Watcher.is_gone(code))
    case s _:
      # an input the phase did not ask for changes nothing
      Step{s, Nil{}, False{}}

def Watcher.merge.go(outs: List<&2, Out>, w: Bool, s: Step) -> Step:
  match s:
    case Step{st, more, w2}:
      Step{st, List.append(&2, Out, outs, more), Bool.or(w, w2)}

# Feeds a run of inputs (the events of one recv), joining the outputs. A
# step that asks to back off ends the run's effect on the stream: the
# driver reconnects.
def Watcher.merge(acc: Step, x: Input) -> Step:
  match acc:
    case Step{st, outs, w}:
      Watcher.merge.go(outs, w, Watcher.step(st, x))

def Watcher.steps(xs: List<&2, Input>, acc: Step) -> Step:
  match xs:
    case Nil{}:
      acc
    case Con{x, t}:
      Watcher.steps(t, Watcher.merge(acc, x))
