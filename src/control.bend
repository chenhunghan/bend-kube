import Base
import ./json.bend as J
import ./core.bend as C
import ./config.bend as K
import ./watcher.bend as W
import ./store.bend as S

# Control
# =======
#
# What a controller decides about the events it sees, as pure functions
# (kube-runtime's Controller builder, predicates and trigger mappers;
# controller-runtime's Watches and handlers):
#
# - Filters (kube-runtime's predicate_filter): which changes to the
#   primary object reconcile it. With no predicates, every change does. With
#   predicates, a change does only when what they look at differs from the
#   cached object (or nothing is cached): PGeneration is the spec (an object
#   without metadata.generation, such as a ConfigMap, always passes it),
#   PLabels, PAnnotations and PFinalizers their metadata. The start of a
#   deletion always passes, so a finalizer is never missed.
# - Relations (Rel): which primaries a change to a related object
#   reconciles. ROwner follows ownerReferences of the primary's kind;
#   RLabel reads the primary's name from a label; RRef finds the primaries
#   whose field (a path into the object) names the related object; RAll
#   reconciles every primary in the object's namespace. Both the object as
#   it was cached and as it is now are mapped, so a relation that moves
#   reconciles the old primary as well as the new one.
# - The context a reconcile gets (Ctx): the client config, the
#   controller's index, and read-only snapshots of every cache the
#   controller keeps: the primary's and each related watch's.
#
# Every function here is pure; runtime.bend performs them.

# Filters
# -------

type Pred is Data:
  PGeneration{}
  PLabels{}
  PAnnotations{}
  PFinalizers{}

# The part of an object a predicate looks at.
def Pred.part.gen(+o: J.Json, g: String, none: Bool) -> String:
  match none:
    case True{}:
      "rv:" ++ C.Obj.rv(o)
    case False{}:
      "gen:" ++ g

def Pred.part(p: Pred, +o: J.Json) -> String:
  match p:
    case PGeneration{}:
      Pred.part.gen(o, C.Obj.generation(o), String.is_empty(C.Obj.generation(o)))
    case PLabels{}:
      J.Json.show(C.Obj.meta(o, "labels"))
    case PAnnotations{}:
      J.Json.show(C.Obj.meta(o, "annotations"))
    case PFinalizers{}:
      J.Json.show(C.Obj.meta(o, "finalizers"))

def Pred.print.go(ps: List<&2, Pred>, +o: J.Json) -> String:
  match ps:
    case Nil{}:
      ""
    case Con{p, t}:
      Pred.part(p, o) ++ "\n" ++ Pred.print.go(t, o)

def Pred.deleting(d: Bool) -> String:
  match d:
    case True{}:
      "deleting"
    case False{}:
      "live"

# What the predicates see of an object, deletion included.
def Pred.print(ps: List<&2, Pred>, +o: J.Json) -> String:
  Pred.print.go(ps, o) ++ Pred.deleting(C.Obj.is_deleting(o))

def Pred.changed(+ps: List<&2, Pred>, old: Maybe<&2, J.Json>, +new: J.Json) -> Bool:
  match old:
    case None{}:
      True{}
    case Some{o}:
      Bool.not(String.eq(Pred.print(ps, o), Pred.print(ps, new)))

# Whether a change to the primary reconciles it: always without predicates;
# with them, when what they see differs from the cached object.
def Pred.passes(ps: List<&2, Pred>, old: Maybe<&2, J.Json>, +new: J.Json) -> Bool:
  match ps:
    case Nil{}:
      True{}
    case Con{+p, +t}:
      Pred.changed(p <> t, old, new)

# Relations
# ---------

type Rel is Data:
  ROwner{}
  RLabel{key: String}
  RRef{path: List<&2, String>}
  RAll{}

# A field names the object: the string itself, or a list holding it.
def Ref.names.any(xs: List<&2, J.Json>, +name: String) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case Con{J.JStr{s}, t}:
      Bool.or(String.eq(s, name), Ref.names.any(t, name))
    case Con{x, t}:
      Ref.names.any(t, name)

def Ref.names(v: J.Json, +name: String) -> Bool:
  match v:
    case J.JStr{s}:
      String.eq(s, name)
    case J.JArr{xs}:
      Ref.names.any(J.Json.items(J.JArr{xs}), name)
    case _:
      False{}

# A primary shares the object's namespace (any primary, for a
# cluster-scoped object).
def Rel.near(+p: J.Json, +ns: String) -> Bool:
  Bool.or(String.is_empty(ns), String.eq(C.Obj.namespace(p), ns))

def Rel.ref.put(+p: J.Json, hit: Bool, rest: List<&2, String>) -> List<&2, String>:
  match hit:
    case True{}:
      C.Obj.key(p) <> rest
    case False{}:
      rest

def Rel.refs(ps: List<&2, J.Json>, +path: List<&2, String>, +ns: String, +name: String) ->
  List<&2, String>:
  match ps:
    case Nil{}:
      Nil{}
    case Con{+p, t}:
      Rel.ref.put(p, Bool.and(Rel.near(p, ns), Ref.names(J.Json.at(p, path), name)),
        Rel.refs(t, path, ns, name))

def Rel.all(ps: List<&2, J.Json>, +ns: String) -> List<&2, String>:
  match ps:
    case Nil{}:
      Nil{}
    case Con{+p, t}:
      Rel.ref.put(p, Rel.near(p, ns), Rel.all(t, ns))

def Rel.label.key(+ns: String, +v: String, cached: Bool) -> String:
  match cached:
    case True{}:
      C.Obj.key.of(ns, v)
    case False{}:
      v

def Rel.label.found(m: Maybe<&2, J.Json>) -> Bool:
  match m:
    case Some{x}:
      True{}
    case None{}:
      False{}

# The primary a label names: in the object's namespace if the cache has it
# there, else cluster-scoped.
def Rel.label(m: Maybe<&2, String>, +ns: String, +prim: S.Store) -> List<&2, String>:
  match m:
    case Some{+v}:
      [Rel.label.key(ns, v, Rel.label.found(S.Store.get(prim, C.Obj.key.of(ns, v))))]
    case None{}:
      Nil{}

def Rel.owners(rs: List<&2, C.ObjRef>) -> List<&2, String>:
  match rs:
    case Nil{}:
      Nil{}
    case Con{r, t}:
      C.ObjRef.key(r) <> Rel.owners(t)

# The primary keys a related object triggers.
def Rel.keys(r: Rel, +kind: String, +o: J.Json, +prim: S.Store) -> List<&2, String>:
  match r:
    case ROwner{}:
      Rel.owners(C.Obj.owners(o, kind))
    case RLabel{k}:
      Rel.label(C.Obj.label(o, k), C.Obj.namespace(o), prim)
    case RRef{path}:
      Rel.refs(S.Store.values(prim), path, C.Obj.namespace(o), C.Obj.name(o))
    case RAll{}:
      Rel.all(S.Store.values(prim), C.Obj.namespace(o))

# Folding a watcher's outputs
# ---------------------------

# A batch of outputs folded into a cache: the cache after them, the keys
# they trigger, and the keys deleted.
type Fold is Data:
  Fold{store: S.Store, keys: List<&2, String>, gone: List<&2, String>}

def Fold.put(+key: String, hit: Bool, ks: List<&2, String>) -> List<&2, String>:
  match hit:
    case True{}:
      key <> ks
    case False{}:
      ks

def Out.obj(o: W.Out) -> Maybe<&2, J.Json>:
  match o:
    case W.OApply{x}:
      Some{x}
    case W.OInitApply{x}:
      Some{x}
    case W.ODelete{x}:
      Some{x}
    case _:
      None{}

def Fold.prim.one(+ps: List<&2, Pred>, o: W.Out, f: Fold) -> Fold:
  match o f:
    case W.OApply{+x} Fold{+s, ks, g}:
      Fold{S.Store.apply(s, W.OApply{x}),
        Fold.put(C.Obj.key(x), Pred.passes(ps, S.Store.get(s, C.Obj.key(x)), x), ks), g}
    case W.OInitApply{+x} Fold{+s, ks, g}:
      Fold{S.Store.apply(s, W.OInitApply{x}),
        Fold.put(C.Obj.key(x), Pred.passes(ps, S.Store.get(s, C.Obj.key(x)), x), ks), g}
    case W.ODelete{+x} Fold{s, ks, g}:
      Fold{S.Store.apply(s, W.ODelete{x}), ks, C.Obj.key(x) <> g}
    case +e Fold{s, ks, g}:
      Fold{S.Store.apply(s, e), ks, g}

# The primary's outputs: each applied or initially listed object reconciles
# when it passes the predicates, against the cache as it was before it.
def Fold.prim(+ps: List<&2, Pred>, outs: List<&2, W.Out>, f: Fold) -> Fold:
  match outs:
    case Nil{}:
      f
    case Con{o, t}:
      Fold.prim(ps, t, Fold.prim.one(ps, o, f))

def Fold.rel.keys(+r: Rel, +kind: String, m: Maybe<&2, J.Json>, +prim: S.Store) ->
  List<&2, String>:
  match m:
    case Some{+x}:
      Rel.keys(r, kind, x, prim)
    case None{}:
      Nil{}

def Fold.rel.with(+r: Rel, +kind: String, +o: W.Out, +prim: S.Store, +s: S.Store,
  ks: List<&2, String>, m: Maybe<&2, J.Json>) -> Fold:
  match m:
    case Some{+x}:
      Fold{S.Store.apply(s, o),
        List.append(&2, String, Rel.keys(r, kind, x, prim),
          List.append(&2, String, Fold.rel.keys(r, kind, S.Store.get(s, C.Obj.key(x)), prim), ks)),
        Nil{}}
    case None{}:
      Fold{S.Store.apply(s, o), ks, Nil{}}

def Fold.rel.one(+r: Rel, +kind: String, +o: W.Out, +prim: S.Store, f: Fold) -> Fold:
  match f:
    case Fold{+s, ks, g}:
      Fold.rel.with(r, kind, o, prim, s, ks, Out.obj(o))

# A related watch's outputs: every change triggers the primaries its
# relation maps the object to, as cached before and as it is now.
def Fold.rel(+r: Rel, +kind: String, outs: List<&2, W.Out>, +prim: S.Store, f: Fold) -> Fold:
  match outs:
    case Nil{}:
      f
    case Con{+o, t}:
      Fold.rel(r, kind, t, prim, Fold.rel.one(r, kind, o, prim, f))

# Controller specs
# ----------------

# A related watch: what to watch (and its label selector), and how its
# objects map to primaries.
type Sec is Data:
  Sec{api: C.Api, label: String, rel: Rel}

# A controller (kube-runtime's Controller::new(..).owns(..).watches(..)):
# the primary and its label selector, the predicates its changes pass, the
# related watches, and how many reconciles run at once.
type Spec is Data:
  Spec{primary: C.Api, label: String, preds: List<&2, Pred>, secs: List<&2, Sec>, max: U32}

# A controller for primary: every change, no related watches, 8 at once.
def Spec.of(primary: C.Api) -> Spec:
  Spec{primary, "", Nil{}, Nil{}, 8}

def Spec.label(s: Spec, l: String) -> Spec:
  match s:
    case Spec{p, x, ps, ss, m}:
      Spec{p, l, ps, ss, m}

def Spec.filter(s: Spec, ps: List<&2, Pred>) -> Spec:
  match s:
    case Spec{p, l, x, ss, m}:
      Spec{p, l, ps, ss, m}

def Spec.max(s: Spec, n: U32) -> Spec:
  match s:
    case Spec{p, l, ps, ss, x}:
      Spec{p, l, ps, ss, n}

# Adds a related watch; the n-th one added is cache n (Ctx.cache).
def Spec.watches_where(s: Spec, a: C.Api, label: String, r: Rel) -> Spec:
  match s:
    case Spec{p, l, ps, ss, m}:
      Spec{p, l, ps, List.append(&2, Sec, ss, [Sec{a, label, r}]), m}

def Spec.watches(s: Spec, a: C.Api, r: Rel) -> Spec:
  Spec.watches_where(s, a, "", r)

# Objects of a's kind that the primary owns (controller ownerReferences).
def Spec.owns(s: Spec, a: C.Api) -> Spec:
  Spec.watches_where(s, a, "", ROwner{})

def Spec.primary(s: Spec) -> C.Api:
  match s:
    case Spec{p, l, ps, ss, m}:
      p

def Spec.kind(s: Spec) -> String:
  match s:
    case Spec{C.Api{r, sc}, l, ps, ss, m}:
      C.Res.kind(r)

def Spec.preds(s: Spec) -> List<&2, Pred>:
  match s:
    case Spec{p, l, ps, ss, m}:
      ps

def Spec.secs(s: Spec) -> List<&2, Sec>:
  match s:
    case Spec{p, l, ps, ss, m}:
      ss

def Spec.max_of(s: Spec) -> U32:
  match s:
    case Spec{p, l, ps, ss, m}:
      m

def Spec.label_of(s: Spec) -> String:
  match s:
    case Spec{p, l, ps, ss, m}:
      l

def Sec.rel(s: Sec) -> Rel:
  match s:
    case Sec{a, l, r}:
      r

# The reconcile context
# ---------------------

# cfg: the client config; idx: the controller's index (0 for a lone
# controller); store: the primary's cache; caches: each related watch's,
# in the order they were added (Ctx.cache(c, 1) is the first).
type Ctx is Data:
  Ctx{cfg: K.Config, idx: U32, store: S.Store, caches: List<&2, S.Store>}

def Ctx.cfg(c: Ctx) -> K.Config:
  match c:
    case Ctx{cfg, i, s, cs}:
      cfg

def Ctx.idx(c: Ctx) -> U32:
  match c:
    case Ctx{cfg, i, s, cs}:
      i

def Ctx.store(c: Ctx) -> S.Store:
  match c:
    case Ctx{cfg, i, s, cs}:
      s

# The cached primary under a key ("ns/name", or "name").
def Ctx.get(c: Ctx, key: String) -> Maybe<&2, J.Json>:
  S.Store.get(Ctx.store(c), key)

# Every cached primary.
def Ctx.list(c: Ctx) -> List<&2, J.Json>:
  S.Store.values(Ctx.store(c))

def Ctx.nth(cs: List<&2, S.Store>, n: Nat) -> S.Store:
  match cs n:
    case Nil{} k:
      S.Store.new()
    case Con{s, t} 0n:
      s
    case Con{s, t} 1n+k:
      Ctx.nth(t, k)

# The cache of the n-th related watch (from 1); empty if there is none.
def Ctx.cache(c: Ctx, n: U32) -> S.Store:
  match c:
    case Ctx{cfg, i, s, cs}:
      Ctx.nth(cs, U32.to_nat((n - 1 : U32)))

# A cached related object under a key.
def Ctx.find(c: Ctx, n: U32, key: String) -> Maybe<&2, J.Json>:
  S.Store.get(Ctx.cache(c, n), key)

# Every cached object of the n-th related watch.
def Ctx.all(c: Ctx, n: U32) -> List<&2, J.Json>:
  S.Store.values(Ctx.cache(c, n))

def Owned.uid.any(rs: List<&2, J.Json>, +uid: String) -> Bool:
  match rs:
    case Nil{}:
      False{}
    case Con{r, t}:
      Bool.or(String.eq(J.Json.str_or(J.Json.get(r, "uid"), ""), uid), Owned.uid.any(t, uid))

# Whether o names an owner with this uid.
def Owned.by(+o: J.Json, +uid: String) -> Bool:
  Owned.uid.any(J.Json.items(C.Obj.meta(o, "ownerReferences")), uid)

def Owned.keep(+x: J.Json, hit: Bool, rest: List<&2, J.Json>) -> List<&2, J.Json>:
  match hit:
    case True{}:
      x <> rest
    case False{}:
      rest

def Owned.pick(xs: List<&2, J.Json>, +uid: String) -> List<&2, J.Json>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{+x, t}:
      Owned.keep(x, Owned.by(x, uid), Owned.pick(t, uid))

# The cached objects of the n-th related watch that owner owns (by uid).
def Ctx.children(c: Ctx, n: U32, +owner: J.Json) -> List<&2, J.Json>:
  Owned.pick(Ctx.all(c, n), C.Obj.uid(owner))
