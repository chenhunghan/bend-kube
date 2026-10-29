import Base
import ./json.bend as J
import ./core.bend as C
import ./watcher.bend as W

# Store
# =====
#
# kube-runtime's reflector Store, keyed as client-go's cache is ("ns/name"
# or "name"). A relist builds a fresh buffer between Init and InitDone and
# swaps it in whole, so an object deleted while the watch was down leaves
# the store with the relist (kube-runtime's buffered reflector).

type Store is Data:
  Store{objs: Map<&2, J.Json>, buf: Map<&2, J.Json>, ready: Bool}

def Store.new() -> Store:
  Store{Map.new(&2, J.Json), Map.new(&2, J.Json), False{}}

def Store.apply(s: Store, o: W.Out) -> Store:
  match s o:
    case Store{objs, buf, r} W.OInit{}:
      Store{objs, Map.new(&2, J.Json), r}
    case Store{objs, buf, r} W.OInitApply{+x}:
      Store{objs, Map.set(&2, J.Json, buf, C.Obj.key(x), x), r}
    case Store{objs, buf, r} W.OInitDone{}:
      Store{buf, Map.new(&2, J.Json), True{}}
    case Store{objs, buf, r} W.OApply{+x}:
      Store{Map.set(&2, J.Json, objs, C.Obj.key(x), x), buf, r}
    case Store{objs, buf, r} W.ODelete{+x}:
      Store{Map.del(&2, J.Json, objs, C.Obj.key(x)), buf, r}

def Store.apply_all(os: List<&2, W.Out>, s: Store) -> Store:
  match os:
    case Nil{}:
      s
    case Con{o, t}:
      Store.apply_all(t, Store.apply(s, o))

def Store.get.fin(r: Map<&2, J.Json> & J.Json) -> Maybe<&2, J.Json>:
  match r:
    case (m, J.JNull{}):
      None{}
    case (m, x):
      Some{x}

# The object under a key, if the store has it.
def Store.get(s: Store, key: String) -> Maybe<&2, J.Json>:
  match s:
    case Store{objs, buf, r}:
      Store.get.fin(Map.get(J.Json, J.JNull{}, objs, key))

def Store.ready(s: Store) -> Bool:
  match s:
    case Store{o, b, r}:
      r

def Store.size(s: Store) -> Nat:
  match s:
    case Store{o, b, r}:
      Map.size(&2, J.Json, o)

def Store.keys(s: Store) -> List<&2, String>:
  match s:
    case Store{o, b, r}:
      Map.keys(&2, J.Json, o)

def Store.values.put(r: Map<&2, J.Json> & J.Json, rest: List<&2, J.Json>) -> List<&2, J.Json>:
  match r:
    case (m, x):
      x <> rest

def Store.values.go(ks: List<&2, String>, +m: Map<&2, J.Json>) -> List<&2, J.Json>:
  match ks:
    case Nil{}:
      Nil{}
    case Con{k, t}:
      Store.values.put(Map.get(J.Json, J.JNull{}, m, k), Store.values.go(t, m))

def Store.values(s: Store) -> List<&2, J.Json>:
  match s:
    case Store{+o, b, r}:
      Store.values.go(Map.keys(&2, J.Json, o), o)
