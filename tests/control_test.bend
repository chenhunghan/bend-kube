import Base
import ../src/json.bend as J
import ../src/core.bend as C
import ../src/config.bend as K
import ../src/watcher.bend as W
import ../src/store.bend as S
import ../src/control.bend as X

# Scenarios through a controller's pure decisions: predicates over a batch
# of primary events, related objects mapped to primaries, and what a
# reconcile reads from its context.

def js.of(r: Result<&2, &2, String, J.Json>) -> J.Json:
  match r:
    case Done{j}:
      j
    case Fail{e}:
      J.JStr{"bad json: " ++ e}

def js(s: String) -> J.Json:
  js.of(J.Json.parse(s))

def opt(m: Maybe<&2, J.Json>) -> List<&2, J.Json>:
  match m:
    case Some{x}:
      [x]
    case None{}:
      Nil{}

# A primary Website: name, generation, version, deletion stamp, and the
# secret its spec names.
def site(+name: String, gen: String, rv: String, del: String, +secret: String) -> J.Json:
  js("{\"metadata\": {\"name\": \"" ++ name ++ "\", \"namespace\": \"web\", \"uid\": \"uid-" ++ name
    ++ "\", \"generation\": " ++ gen ++ ", \"resourceVersion\": \"" ++ rv ++ "\"" ++ del
    ++ "}, \"spec\": {\"secretName\": \"" ++ secret ++ "\", \"hosts\": [\"" ++ secret ++ "\", \"b\"]}}")

# A related object: kind, name, namespace, labels, owner.
def thing(name: String, ns: String, labels: String, owner: String) -> J.Json:
  js("{\"metadata\": {\"name\": \"" ++ name ++ "\", \"namespace\": \"" ++ ns ++ "\", \"labels\": {"
    ++ labels ++ "}, \"ownerReferences\": [" ++ owner ++ "]}}")

def owner(+name: String) -> String:
  "{\"kind\": \"Website\", \"name\": \"" ++ name ++ "\", \"uid\": \"uid-" ++ name ++ "\"}"

def keys(ks: List<&2, String>) -> String:
  match ks:
    case Nil{}:
      "-"
    case Con{k, Nil{}}:
      k
    case Con{k, t}:
      k ++ " " ++ keys(t)

def fold_keys(f: X.Fold) -> String:
  match f:
    case X.Fold{s, ks, g}:
      "keys: " ++ keys(List.reverse(&2, String, ks)) ++ "; gone: " ++ keys(g)

def fold_store(f: X.Fold) -> S.Store:
  match f:
    case X.Fold{s, ks, g}:
      s

def names(xs: List<&2, J.Json>) -> String:
  match xs:
    case Nil{}:
      "-"
    case Con{+x, Nil{}}:
      C.Obj.name(x)
    case Con{+x, t}:
      C.Obj.name(x) ++ " " ++ names(t)

def gen() -> List<&2, X.Pred>:
  [X.PGeneration{}]

def ctx(+prim: S.Store, +rel: S.Store) -> X.Ctx:
  X.Ctx{K.Config{"h", 443, "", K.NoSrc{}, K.NoSrc{}, K.NoSrc{}, K.NoSrc{}, "default", None{}, None{}},
    3, prim, [rel]}

def main() -> IO(Unit):
  # The first list fills the cache: everything reconciles, filtered or not.
  +listed = X.Fold.prim(gen(), [W.OInit{}, W.OInitApply{site("a", "1", "10", "", "s1")},
    W.OInitApply{site("b", "1", "11", "", "s2")}, W.OInitDone{}],
    X.Fold{S.Store.new(), Nil{}, Nil{}})
  +prim = fold_store(listed)
  # A status write (same generation, new version) is filtered; a spec change
  # and a deletion starting pass; a relist of unchanged objects is quiet.
  +later = X.Fold.prim(gen(), [W.OApply{site("a", "1", "12", "", "s1")},
    W.OApply{site("b", "2", "13", "", "s2")},
    W.OApply{site("a", "1", "14", ", \"deletionTimestamp\": \"2026-11-07T00:00:00Z\"", "s1")},
    W.ODelete{site("b", "2", "15", "", "s2")}], X.Fold{prim, Nil{}, Nil{}})
  +quiet = X.Fold.prim(gen(), [W.OInit{}, W.OInitApply{site("a", "1", "10", "", "s1")},
    W.OInitDone{}], X.Fold{prim, Nil{}, Nil{}})
  +all = X.Fold.prim(Nil{}, [W.OApply{site("a", "1", "12", "", "s1")}],
    X.Fold{prim, Nil{}, Nil{}})
  # Related objects: owned (old and new owners both reconcile), referenced
  # by a field (a string, or a list holding it), named by a label, and
  # every primary in a namespace.
  +owned0 = X.Fold.rel(X.ROwner{}, "Website", [W.OApply{thing("a-web", "web", "", owner("a"))}], prim,
    X.Fold{S.Store.new(), Nil{}, Nil{}})
  +owned1 = X.Fold.rel(X.ROwner{}, "Website", [W.OApply{thing("a-web", "web", "", owner("b"))},
    W.ODelete{thing("a-web", "web", "", owner("b"))}], prim, X.Fold{fold_store(owned0), Nil{}, Nil{}})
  +refd = X.Fold.rel(X.RRef{["spec", "secretName"]}, "Website", [W.OApply{thing("s2", "web", "", "")},
    W.OApply{thing("s2", "other", "", "")}], prim, X.Fold{S.Store.new(), Nil{}, Nil{}})
  +listed_ref = X.Fold.rel(X.RRef{["spec", "hosts"]}, "Website", [W.OApply{thing("s1", "web", "", "")}],
    prim, X.Fold{S.Store.new(), Nil{}, Nil{}})
  +labeled = X.Fold.rel(X.RLabel{"site"}, "Website", [W.OApply{thing("cm", "web", "\"site\": \"b\"", "")},
    W.OApply{thing("cm2", "web", "\"other\": \"b\"", "")}], prim, X.Fold{S.Store.new(), Nil{}, Nil{}})
  +fan = X.Fold.rel(X.RAll{}, "Website", [W.OApply{thing("cfg", "web", "", "")},
    W.OApply{thing("cfg", "elsewhere", "", "")}, W.OApply{thing("node", "", "", "")}], prim,
    X.Fold{S.Store.new(), Nil{}, Nil{}})
  +rel = fold_store(X.Fold.rel(X.ROwner{}, "Website", [W.OInit{},
    W.OInitApply{thing("a-web", "web", "", owner("a"))}, W.OInitApply{thing("a-db", "web", "", owner("a"))},
    W.OInitApply{thing("b-web", "web", "", owner("b"))}, W.OInitDone{}], prim,
    X.Fold{S.Store.new(), Nil{}, Nil{}}))
  +c = ctx(prim, rel)
  do IO<Unit>:
    IO.print("first list: " ++ fold_keys(listed))
    IO.print("status write, spec change, deletion, delete: " ++ fold_keys(later))
    IO.print("unchanged relist: " ++ fold_keys(quiet))
    IO.print("no predicates: " ++ fold_keys(all))
    IO.print("owned: " ++ fold_keys(owned0))
    IO.print("owner moved, then deleted: " ++ fold_keys(owned1))
    IO.print("referenced by spec.secretName: " ++ fold_keys(refd))
    IO.print("listed in spec.hosts: " ++ fold_keys(listed_ref))
    IO.print("named by label site: " ++ fold_keys(labeled))
    IO.print("every primary nearby: " ++ fold_keys(fan))
    IO.print("ctx idx: " ++ U32.show(X.Ctx.idx(c)))
    IO.print("ctx get web/a: " ++ names(opt(X.Ctx.get(c, "web/a"))))
    IO.print("ctx list: " ++ names(X.Ctx.list(c)))
    IO.print("ctx children of a: " ++ names(X.Ctx.children(c, 1, site("a", "1", "10", "", "s1"))))
    IO.print("ctx children of b: " ++ names(X.Ctx.children(c, 1, site("b", "1", "11", "", "s2"))))
    IO.print("ctx cache 2 (none): " ++ names(X.Ctx.all(c, 2)))
    IO.print("ctx find web/a-db: " ++ names(opt(X.Ctx.find(c, 1, "web/a-db"))))
