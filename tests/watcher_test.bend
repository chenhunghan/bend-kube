import Base
import ../src/json.bend as J
import ../src/core.bend as C
import ../src/watcher.bend as W
import ../src/store.bend as S

# The watcher and the store through a relist: two list pages, a watch
# event, an expired watch, and a relist that drops a deleted object.

def cm(name: String, rv: String) -> J.Json:
  J.Json.obj([J.KV{"metadata", J.Json.obj([J.KV{"name", J.JStr{name}},
    J.KV{"namespace", J.JStr{"ns"}}, J.KV{"resourceVersion", J.JStr{rv}}])}])

type Run is Data:
  Run{st: W.WState, store: S.Store, log: List<&2, String>}

def show_phase(p: W.Phase) -> String:
  match p:
    case W.WList{c}:
      "list(" ++ c ++ ")"
    case W.WWatch{rv}:
      "watch(" ++ rv ++ ")"

def show_out(o: W.Out) -> String:
  match o:
    case W.OInit{}:
      "Init"
    case W.OInitApply{o}:
      "InitApply " ++ C.Obj.name(o)
    case W.OInitDone{}:
      "InitDone"
    case W.OApply{o}:
      "Apply " ++ C.Obj.name(o)
    case W.ODelete{o}:
      "Delete " ++ C.Obj.name(o)

def show_outs(os: List<&2, W.Out>) -> String:
  match os:
    case Nil{}:
      ""
    case Con{o, t}:
      show_out(o) ++ "; " ++ show_outs(t)

def feed.fin(+store: S.Store, log: List<&2, String>, s: W.Step) -> Run:
  match s:
    case W.Step{W.WState{+p, +f, first}, +outs, wait}:
      Run{W.WState{p, f, first}, S.Store.apply_all(outs, store),
        (show_phase(p) ++ " fails=" ++ U32.show(f) ++ " wait=" ++ Bool.show(wait) ++ " | "
          ++ show_outs(outs)) <> log}

def feed(r: Run, i: W.Input) -> Run:
  match r:
    case Run{st, store, log}:
      feed.fin(store, log, W.Watcher.step(st, i))

def feed_all(xs: List<&2, W.Input>, r: Run) -> Run:
  match xs:
    case Nil{}:
      r
    case Con{i, t}:
      feed_all(t, feed(r, i))

def report(r: Run) -> IO(Unit):
  match r:
    case Run{st, store, log}:
      do IO<Unit>:
        IO.print(String.join(List.reverse(&2, String, log), "\n"))
        IO.print("store: " ++ String.join(S.Store.keys(store), ","))

def main() -> IO(Unit):
  report(feed_all([
    W.IPage{C.Page{[cm("a", "1"), cm("b", "2")], "", "tok"}},
    W.IListErr{500},
    W.IPage{C.Page{[cm("c", "3")], "10", ""}},
    W.IEvent{C.WModified{cm("a", "11")}},
    W.IEvent{C.WBookmark{"15"}},
    W.IWatchEnd{},
    W.IEvent{C.WError{C.Status{410, "Expired", "too old"}}},
    W.IPage{C.Page{[cm("a", "20")], "20", ""}}], Run{W.WState.init(), S.Store.new(), Nil{}}))
