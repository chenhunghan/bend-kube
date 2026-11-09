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

def gen() -> List<&2, X.Pred>:
  [X.PGeneration{}]

# A primary Website: name, generation, version, deletion stamp, and the
# secret its spec names.
def site(+name: String, gen: String, rv: String, del: String, +secret: String) -> J.Json:
  js("{\"metadata\": {\"name\": \"" ++ name ++ "\", \"namespace\": \"web\", \"uid\": \"uid-" ++ name
    ++ "\", \"generation\": " ++ gen ++ ", \"resourceVersion\": \"" ++ rv ++ "\"" ++ del
    ++ "}, \"spec\": {\"secretName\": \"" ++ secret ++ "\", \"hosts\": [\"" ++ secret ++ "\", \"b\"]}}")

def owner(+name: String) -> String:
  "{\"apiVersion\": \"bend-kube.dev/v1alpha1\", \"kind\": \"Website\", \"name\": \"" ++ name
    ++ "\", \"uid\": \"uid-" ++ name ++ "\", \"controller\": true}"

# A related object: kind, name, namespace, labels, owner.
def thing(name: String, ns: String, labels: String, owner: String) -> J.Json:
  js("{\"metadata\": {\"name\": \"" ++ name ++ "\", \"namespace\": \"" ++ ns ++ "\", \"labels\": {"
    ++ labels ++ "}, \"ownerReferences\": [" ++ owner ++ "]}}")

# An owner reference that is not the controller.
def plain_owner(+name: String) -> String:
  "{\"apiVersion\": \"bend-kube.dev/v1alpha1\", \"kind\": \"Website\", \"name\": \"" ++ name
    ++ "\", \"uid\": \"uid-" ++ name ++ "\"}"

def res() -> C.Res:
  C.Res{"bend-kube.dev", "v1alpha1", "Website", "websites", True{}}

def tenants() -> C.Res:
  C.Res{"bend-kube.dev", "v1", "Tenant", "tenants", False{}}

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

def fold_obj(f: X.Fold) -> J.Json:
  match f:
    case X.Fold{s, ks, g}:
      Maybe.default(&2, J.Json, S.Store.get(s, "web/s"), J.JNull{})

def ctx(+prim: S.Store, +rel: S.Store) -> X.Ctx:
  X.Ctx{K.Config{"h", 443, "", K.NoSrc{}, K.NoSrc{}, K.NoSrc{}, K.NoSrc{}, "default", None{}, None{}, "", None{}},
    3, prim, [rel], 0, None{}}

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
    W.OInitApply{site("b", "1", "11", "", "s2")}, W.OInitDone{}], X.Fold{prim, Nil{}, Nil{}})
  +dropped = X.Fold.prim(gen(), [W.OInit{}, W.OInitApply{site("a", "1", "10", "", "s1")},
    W.OInitDone{}], X.Fold{prim, Nil{}, Nil{}})
  +all = X.Fold.prim(Nil{}, [W.OApply{site("a", "1", "12", "", "s1")}],
    X.Fold{prim, Nil{}, Nil{}})
  # Related objects: owned (old and new owners both reconcile), referenced
  # by a field (a string, or a list holding it), named by a label, and
  # every primary in a namespace.
  +owned0 = X.Fold.rel(X.ROwner{}, res(), [W.OApply{thing("a-web", "web", "", owner("a"))}], prim,
    X.Fold{S.Store.new(), Nil{}, Nil{}})
  +owned1 = X.Fold.rel(X.ROwner{}, res(), [W.OApply{thing("a-web", "web", "", owner("b"))},
    W.ODelete{thing("a-web", "web", "", owner("b"))}], prim, X.Fold{fold_store(owned0), Nil{}, Nil{}})
  +refd = X.Fold.rel(X.RRef{["spec", "secretName"]}, res(), [W.OApply{thing("s2", "web", "", "")},
    W.OApply{thing("s2", "other", "", "")}], prim, X.Fold{S.Store.new(), Nil{}, Nil{}})
  +listed_ref = X.Fold.rel(X.RRef{["spec", "hosts"]}, res(), [W.OApply{thing("s1", "web", "", "")}],
    prim, X.Fold{S.Store.new(), Nil{}, Nil{}})
  +labeled = X.Fold.rel(X.RLabel{"site"}, res(), [W.OApply{thing("cm", "web", "\"site\": \"b\"", "")},
    W.OApply{thing("cm2", "web", "\"other\": \"b\"", "")}], prim, X.Fold{S.Store.new(), Nil{}, Nil{}})
  +fan = X.Fold.rel(X.RAll{}, res(), [W.OApply{thing("cfg", "web", "", "")},
    W.OApply{thing("cfg", "elsewhere", "", "")}, W.OApply{thing("node", "", "", "")}], prim,
    X.Fold{S.Store.new(), Nil{}, Nil{}})
  +rel = fold_store(X.Fold.rel(X.ROwner{}, res(), [W.OInit{},
    W.OInitApply{thing("a-web", "web", "", owner("a"))}, W.OInitApply{thing("a-db", "web", "", owner("a"))},
    W.OInitApply{thing("b-web", "web", "", owner("b"))}, W.OInitDone{}], prim,
    X.Fold{S.Store.new(), Nil{}, Nil{}}))
  +c = ctx(prim, rel)
  +rel_dropped = X.Fold.rel(X.ROwner{}, res(), [W.OInit{},
    W.OInitApply{thing("a-web", "web", "", owner("a"))}, W.OInitDone{}], prim,
    X.Fold{rel, Nil{}, Nil{}})
  +cluster = X.Fold.rel(X.ROwner{}, tenants(), [W.OApply{thing("quota", "team-a", "",
    "{\"apiVersion\": \"bend-kube.dev/v1\", \"kind\": \"Tenant\", \"name\": \"t1\"}")}],
    S.Store.new(), X.Fold{S.Store.new(), Nil{}, Nil{}})
  +rel2 = fold_store(X.Fold.rel(X.ROwner{}, res(), [W.OInit{},
    W.OInitApply{thing("a-web", "web", "", owner("a"))},
    W.OInitApply{thing("a-extra", "web", "", plain_owner("a"))}, W.OInitDone{}], prim,
    X.Fold{S.Store.new(), Nil{}, Nil{}}))
  +c2 = ctx(prim, rel2)
  do IO<Unit>:
    IO.print("first list: " ++ fold_keys(listed))
    IO.print("status write, spec change, deletion, delete: " ++ fold_keys(later))
    IO.print("unchanged relist: " ++ fold_keys(quiet))
    IO.print("relist without b (deleted while down): " ++ fold_keys(dropped))
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
    IO.print("related relist drops a-db and b-web: " ++ fold_keys(rel_dropped))
    IO.print("owned by a cluster-scoped Tenant: " ++ fold_keys(cluster))
    IO.print("children of a, controller owners only: " ++ names(X.Ctx.children(c2, 1, site("a", "1", "10", "", "s1"))))
    IO.print("a Secret with its data dropped: " ++ J.Json.show(fold_obj(X.Fold.rel(X.RAll{}, res(),
      X.Out.trim_all(["data", "stringData"], [W.OApply{js("{\"metadata\": {\"name\": \"s\", \"namespace\": \"web\", \"annotations\": {\"kubectl.kubernetes.io/last-applied-configuration\": \"{data: v}\", \"team\": \"a\"}}, \"type\": \"Opaque\", \"data\": {\"k\": \"dg==\"}}")}]),
      prim, X.Fold{S.Store.new(), Nil{}, Nil{}}))))
    IO.print("fails in ctx: " ++ U32.show(X.Ctx.fails(X.Ctx.with_fails(c, 4))))
