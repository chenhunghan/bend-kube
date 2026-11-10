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
#   deletion and a change of finalizers always pass, so a finalizer is
#   never missed.
# - Relations (Rel): which primaries a change to a related object
#   reconciles. ROwner follows ownerReferences of the primary's kind;
#   RLabel reads the primary's name from a label; RRef finds the primaries
#   whose field (a path into the object) names the related object; RAll
#   reconciles every primary in the object's namespace; RAnnotated reads
#   the primary's namespace and name from two annotations, as a syncer
#   records where a copy in another namespace or cluster came from
#   (vcluster's object-namespace and object-name); RMap hands the object
#   to the controller's own mapper (Kube.control_mapped), which names the
#   primaries. Both the object as
#   it was cached and as it is now are mapped, so a relation that moves
#   reconciles the old primary as well as the new one.
# - Clusters: a watch runs against the controllers' config, or another
#   cluster's (Spec.on, Spec.watch_on), under the same leadership fence.
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

# What the predicates see of an object, its uid, deletion and finalizers
# included: an object deleted and recreated under the same name (a new uid)
# always passes, whatever its generation; a finalizer added or removed (by this controller or another)
# always passes, so a controller that adds its finalizer and waits for
# the change is woken by it.
def Pred.print(ps: List<&2, Pred>, +o: J.Json) -> String:
  "uid:" ++ C.Obj.uid(o) ++ "\n" ++ Pred.print.go(ps, o) ++ Pred.deleting(C.Obj.is_deleting(o))
    ++ "\n" ++ J.Json.show(C.Obj.meta(o, "finalizers"))

def Pred.changed(+ps: List<&2, Pred>, old: Maybe<&2, J.Json>, +new: J.Json) -> Bool:
  match old:
    case None{}:
      True{}
    case Some{o}:
      Bool.not(String.eq(Pred.print(ps, o), Pred.print(ps, new)))

# Whether a change to the primary reconciles it: always without predicates;
# with them, when what they see differs from the cached object. The new
# object is compared as the cache holds it (S.Store.slim: no managedFields
# or last-applied annotation), so a kubectl apply that changes nothing else
# does not pass PAnnotations.
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
  RAnnotated{ns_key: String, name_key: String}
  RMap{}

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

# A primary can relate to the object: one in the object's namespace, or
# any primary when either is cluster-scoped.
def Rel.near(+p: J.Json, +ns: String) -> Bool:
  Bool.or(Bool.or(String.is_empty(ns), String.is_empty(C.Obj.namespace(p))),
    String.eq(C.Obj.namespace(p), ns))

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

# The key of a primary named name, related to an object in namespace ns:
# in that namespace for a namespaced primary, by name alone otherwise.
def Rel.key.go(+ns: String, +name: String, namespaced: Bool) -> String:
  match namespaced:
    case True{}:
      C.Obj.key.of(ns, name)
    case False{}:
      name

def Rel.key(+res: C.Res, +ns: String, +name: String) -> String:
  Rel.key.go(ns, name, C.Res.namespaced(res))

# The primary a label names.
def Rel.label(m: Maybe<&2, String>, +ns: String, +res: C.Res) -> List<&2, String>:
  match m:
    case Some{+v}:
      [Rel.key(res, ns, v)]
    case None{}:
      Nil{}

def Rel.annot(o: J.Json, key: String) -> Maybe<&2, String>:
  J.Json.as_str(J.Json.get(C.Obj.meta(o, "annotations"), key))

def Rel.annotated.go(+res: C.Res, ns: Maybe<&2, String>, name: Maybe<&2, String>, +own: String) ->
  List<&2, String>:
  match ns name:
    case Some{+n} Some{+v}:
      [Rel.key(res, n, v)]
    case None{} Some{+v}:
      [Rel.key(res, own, v)]
    case _ None{}:
      Nil{}

# The primary two annotations name: its namespace (the object's own when
# that annotation is missing) and its name (nothing without it).
def Rel.annotated(+o: J.Json, +nk: String, +vk: String, +res: C.Res) -> List<&2, String>:
  Rel.annotated.go(res, Rel.annot(o, nk), Rel.annot(o, vk), C.Obj.namespace(o))

# An object for the controller's mapper (RMap) rides among a fold's keys
# behind this mark, which no key starts with; the runtime takes it out
# (Mapped.split) and maps it.
def Mapped.mark() -> String:
  "\0map:"

# The group of an apiVersion: "apps" of "apps/v1", "" of "v1".
def Ref.group.go(ps: List<&2, String>) -> String:
  match ps:
    case Con{g, Con{v, Nil{}}}:
      g
    case _:
      ""

def Ref.group(av: String) -> String:
  Ref.group.go(String.split(av, '/'))

# Whether an owner reference names the primary's kind, in its group.
def Ref.is_owner(+r: J.Json, +res: C.Res) -> Bool:
  Bool.and(String.eq(J.Json.str_or(J.Json.get(r, "kind"), ""), C.Res.kind(res)),
    String.eq(Ref.group(J.Json.str_or(J.Json.get(r, "apiVersion"), "")), C.Res.group(res)))

def Rel.owner.put(+r: J.Json, +res: C.Res, +ns: String, hit: Bool, rest: List<&2, String>) ->
  List<&2, String>:
  match hit:
    case True{}:
      Rel.key(res, ns, J.Json.str_or(J.Json.get(r, "name"), "")) <> rest
    case False{}:
      rest

def Rel.owner.go(rs: List<&2, J.Json>, +res: C.Res, +ns: String) -> List<&2, String>:
  match rs:
    case Nil{}:
      Nil{}
    case Con{+r, t}:
      Rel.owner.put(r, res, ns, Ref.is_owner(r, res), Rel.owner.go(t, res, ns))

# The primaries an object's owner references name (kube-runtime's
# trigger_owners): the primary's kind in its API group.
def Rel.owners(+o: J.Json, +res: C.Res) -> List<&2, String>:
  Rel.owner.go(J.Json.items(C.Obj.meta(o, "ownerReferences")), res, C.Obj.namespace(o))

# The primary keys a related object triggers; res is the primary's
# resource (its kind, group and scope).
def Rel.keys(r: Rel, +res: C.Res, +o: J.Json, +prim: S.Store) -> List<&2, String>:
  match r:
    case ROwner{}:
      Rel.owners(o, res)
    case RLabel{k}:
      Rel.label(C.Obj.label(o, k), C.Obj.namespace(o), res)
    case RRef{path}:
      Rel.refs(S.Store.values(prim), path, C.Obj.namespace(o), C.Obj.name(o))
    case RAll{}:
      Rel.all(S.Store.values(prim), C.Obj.namespace(o))
    case RAnnotated{nk, vk}:
      Rel.annotated(o, nk, vk, res)
    case RMap{}:
      [Mapped.mark() ++ J.Json.show(o)]

# Indexes for a batch
# --------------------
#
# RRef and RAll would scan every cached primary for every related object,
# so a relist of R related objects against P primaries cost P x R (seconds
# at a few thousand of each, on the loop the lease renews on). A batch
# instead builds an index of the primaries once: for RRef, the names each
# primary's field holds; for RAll, the primaries by namespace. Lookups keep
# the scan's order and its rule (Rel.near).

# A primary as an index holds it: its key and namespace.
type Ent is Data:
  Ent{key: String, ns: String}

# refs: name -> the primaries whose field names it; nss: namespace -> the
# primaries in it ("" for cluster-scoped ones); prim: the cache, for the
# other relations.
type Ix is Data:
  Ix{prim: S.Store, refs: Map<&2, List<&2, Ent>>, nss: Map<&2, List<&2, Ent>>}

def Ix.put.got(r: Map<&2, List<&2, Ent>> & List<&2, Ent>, +k: String, +e: Ent) -> Map<&2, List<&2, Ent>>:
  match r:
    case (m, es):
      Map.set(&2, List<&2, Ent>, m, k, e <> es)

def Ix.put(+m: Map<&2, List<&2, Ent>>, +k: String, +e: Ent) -> Map<&2, List<&2, Ent>>:
  Ix.put.got(Map.get(List<&2, Ent>, Nil{}, m, k), k, e)

def Ix.get.got(r: Map<&2, List<&2, Ent>> & List<&2, Ent>) -> List<&2, Ent>:
  match r:
    case (m, es):
      es

def Ix.get(+m: Map<&2, List<&2, Ent>>, +k: String) -> List<&2, Ent>:
  Ix.get.got(Map.get(List<&2, Ent>, Nil{}, m, k))

# The names a field holds: the string itself, or each string of a list.
def Ix.names.strs(xs: List<&2, J.Json>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{J.JStr{s}, t}:
      s <> Ix.names.strs(t)
    case Con{x, t}:
      Ix.names.strs(t)

def Ix.names(v: J.Json) -> List<&2, String>:
  match v:
    case J.JStr{s}:
      [s]
    case J.JArr{xs}:
      Ix.names.strs(J.Json.items(J.JArr{xs}))
    case _:
      Nil{}

def Ix.refs.names(ns: List<&2, String>, +e: Ent, +m: Map<&2, List<&2, Ent>>) -> Map<&2, List<&2, Ent>>:
  match ns:
    case Nil{}:
      m
    case Con{n, t}:
      Ix.refs.names(t, e, Ix.put(m, n, e))

# Built from the primaries in reverse, so each list is in cache order.
def Ix.refs.go(ps: List<&2, J.Json>, +path: List<&2, String>, +m: Map<&2, List<&2, Ent>>) ->
  Map<&2, List<&2, Ent>>:
  match ps:
    case Nil{}:
      m
    case Con{+p, t}:
      Ix.refs.go(t, path, Ix.refs.names(Ix.names(J.Json.at(p, path)), Ent{C.Obj.key(p), C.Obj.namespace(p)}, m))

def Ix.nss.go(ps: List<&2, J.Json>, +m: Map<&2, List<&2, Ent>>) -> Map<&2, List<&2, Ent>>:
  match ps:
    case Nil{}:
      m
    case Con{+p, t}:
      Ix.nss.go(t, Ix.put(m, C.Obj.namespace(p), Ent{C.Obj.key(p), C.Obj.namespace(p)}))

# The index a relation needs, over the primaries' cache.
def Ix.of(r: Rel, +prim: S.Store) -> Ix:
  match r:
    case RRef{path}:
      Ix{prim, Ix.refs.go(List.reverse(&2, J.Json, S.Store.values(prim)), path, Map.new(&2, List<&2, Ent>)),
        Map.new(&2, List<&2, Ent>)}
    case RAll{}:
      Ix{prim, Map.new(&2, List<&2, Ent>), Ix.nss.go(List.reverse(&2, J.Json, S.Store.values(prim)), Map.new(&2, List<&2, Ent>))}
    case _:
      Ix{prim, Map.new(&2, List<&2, Ent>), Map.new(&2, List<&2, Ent>)}

def Ix.prim(ix: Ix) -> S.Store:
  match ix:
    case Ix{p, r, n}:
      p

def Ix.near.put(+k: String, hit: Bool, rest: List<&2, String>) -> List<&2, String>:
  match hit:
    case True{}:
      k <> rest
    case False{}:
      rest

# The entries near namespace ns (Rel.near's rule), as keys.
def Ix.near(es: List<&2, Ent>, +ns: String) -> List<&2, String>:
  match es:
    case Nil{}:
      Nil{}
    case Con{Ent{+k, +pns}, t}:
      Ix.near.put(k, Bool.or(Bool.or(String.is_empty(ns), String.is_empty(pns)), String.eq(pns, ns)), Ix.near(t, ns))

def Ix.keys(es: List<&2, Ent>) -> List<&2, String>:
  match es:
    case Nil{}:
      Nil{}
    case Con{Ent{k, n}, t}:
      k <> Ix.keys(t)

# Every primary, in cache order.
def Ix.every.go(ps: List<&2, J.Json>) -> List<&2, String>:
  match ps:
    case Nil{}:
      Nil{}
    case Con{+p, t}:
      C.Obj.key(p) <> Ix.every.go(t)

# RAll through the index: every primary for a cluster-scoped object; else
# those in its namespace, and cluster-scoped ones (the primaries are one
# resource, so only one of the two lists is ever non-empty).
def Ix.every(prim: S.Store) -> List<&2, String>:
  Ix.every.go(S.Store.values(prim))

def Ix.all.go(ix: Ix, +ns: String, cluster: Bool) -> List<&2, String>:
  match ix cluster:
    case Ix{p, r, n} True{}:
      Ix.every(p)
    case Ix{p, r, +n} False{}:
      List.append(&2, String, Ix.keys(Ix.get(n, ns)), Ix.keys(Ix.get(n, "")))

# The primary keys a related object triggers, through the batch's index.
def Rel.keys.ix(r: Rel, +res: C.Res, +o: J.Json, +ix: Ix) -> List<&2, String>:
  match r ix:
    case RRef{path} Ix{p, +refs, n}:
      Ix.near(Ix.get(refs, C.Obj.name(o)), C.Obj.namespace(o))
    case RAll{} x:
      Ix.all.go(x, C.Obj.namespace(o), String.is_empty(C.Obj.namespace(o)))
    case other x:
      Rel.keys(other, res, o, Ix.prim(x))

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
        Fold.put(C.Obj.key(x), Pred.passes(ps, S.Store.get(s, C.Obj.key(x)), S.Store.slim(x)), ks), g}
    case W.OInitApply{+x} Fold{+s, ks, g}:
      Fold{S.Store.apply(s, W.OInitApply{x}),
        Fold.put(C.Obj.key(x), Pred.passes(ps, S.Store.get(s, C.Obj.key(x)), S.Store.slim(x)), ks), g}
    case W.ODelete{+x} Fold{s, ks, g}:
      Fold{S.Store.apply(s, W.ODelete{x}), ks, C.Obj.key(x) <> g}
    case W.OInitDone{} Fold{+s, ks, g}:
      Fold{S.Store.apply(s, W.OInitDone{}), ks, List.append(&2, String, S.Store.dropped(s), g)}
    case +e Fold{s, ks, g}:
      Fold{S.Store.apply(s, e), ks, g}

# The primary's outputs: each applied or initially listed object reconciles
# when it passes the predicates, against the cache as it was before it. A
# deleted object, and one a relist no longer has, is gone: the queue
# forgets it.
def Fold.prim(+ps: List<&2, Pred>, outs: List<&2, W.Out>, f: Fold) -> Fold:
  match outs:
    case Nil{}:
      f
    case Con{o, t}:
      Fold.prim(ps, t, Fold.prim.one(ps, o, f))

def Fold.rel.keys(+r: Rel, +res: C.Res, m: Maybe<&2, J.Json>, +ix: Ix) ->
  List<&2, String>:
  match m:
    case Some{+x}:
      Rel.keys.ix(r, res, x, ix)
    case None{}:
      Nil{}

def Fold.rel.hit(+r: Rel, +res: C.Res, +o: W.Out, +ix: Ix, +s: S.Store,
  ks: List<&2, String>, +x: J.Json, hit: Bool) -> Fold:
  match hit:
    case True{}:
      Fold{S.Store.apply(s, o),
        List.append(&2, String, Rel.keys.ix(r, res, x, ix),
          List.append(&2, String, Fold.rel.keys(r, res, S.Store.get(s, C.Obj.key(x)), ix), ks)),
        Nil{}}
    case False{}:
      Fold{S.Store.apply(s, o), ks, Nil{}}

def Out.is_delete(o: W.Out) -> Bool:
  match o:
    case W.ODelete{x}:
      True{}
    case _:
      False{}

# A change triggers when it is a deletion or passes the watch's predicates.
def Fold.rel.with(+r: Rel, +ps: List<&2, Pred>, +res: C.Res, +o: W.Out, +ix: Ix, +s: S.Store,
  ks: List<&2, String>, m: Maybe<&2, J.Json>) -> Fold:
  match m:
    case Some{+x}:
      Fold.rel.hit(r, res, o, ix, s, ks, x,
        Bool.or(Out.is_delete(o), Pred.passes(ps, S.Store.get(s, C.Obj.key(x)), S.Store.slim(x))))
    case None{}:
      Fold{S.Store.apply(s, o), ks, Nil{}}

# The primaries of related objects a relist drops (deleted while the
# watch was down), by their cached versions.
def Fold.rel.dropped(+r: Rel, +res: C.Res, ds: List<&2, String>, +s: S.Store, +ix: Ix) ->
  List<&2, String>:
  match ds:
    case Nil{}:
      Nil{}
    case Con{k, t}:
      List.append(&2, String, Fold.rel.keys(r, res, S.Store.get(s, k), ix),
        Fold.rel.dropped(r, res, t, s, ix))

def Fold.rel.one.go(+r: Rel, +ps: List<&2, Pred>, +res: C.Res, +o: W.Out, +ix: Ix, +s: S.Store,
  ks: List<&2, String>, done: Bool) -> Fold:
  match done:
    case True{}:
      Fold{S.Store.apply(s, o),
        List.append(&2, String, Fold.rel.dropped(r, res, S.Store.dropped(s), s, ix), ks), Nil{}}
    case False{}:
      Fold.rel.with(r, ps, res, o, ix, s, ks, Out.obj(o))

def Out.is_done(o: W.Out) -> Bool:
  match o:
    case W.OInitDone{}:
      True{}
    case _:
      False{}

def Fold.rel.one(+r: Rel, +ps: List<&2, Pred>, +res: C.Res, +o: W.Out, +ix: Ix, f: Fold) -> Fold:
  match f:
    case Fold{+s, ks, g}:
      Fold.rel.one.go(r, ps, res, o, ix, s, ks, Out.is_done(o))

# A related watch's outputs: every change that passes the watch's
# predicates (ps; Nil passes all) triggers the primaries its relation maps
# the object to, as cached before and as it is now.
def Fold.rel.go(+r: Rel, +ps: List<&2, Pred>, +res: C.Res, outs: List<&2, W.Out>, +ix: Ix,
  f: Fold) -> Fold:
  match outs:
    case Nil{}:
      f
    case Con{+o, t}:
      Fold.rel.go(r, ps, res, t, ix, Fold.rel.one(r, ps, res, o, ix, f))

def Fold.rel_where(+r: Rel, +ps: List<&2, Pred>, +res: C.Res, outs: List<&2, W.Out>, +prim: S.Store,
  f: Fold) -> Fold:
  Fold.rel.go(r, ps, res, outs, Ix.of(r, prim), f)

# Fold.rel_where without predicates: every change triggers.
def Fold.rel(+r: Rel, +res: C.Res, outs: List<&2, W.Out>, +prim: S.Store, f: Fold) -> Fold:
  Fold.rel_where(r, Nil{}, res, outs, prim, f)

# Controller specs
# ----------------

# A related watch: what to watch (and its label selector), and how its
# objects map to primaries.
type Sec is Data:
  Sec{api: C.Api, label: String, field: String, rel: Rel, drop: List<&2, String>, preds: List<&2, Pred>,
    cluster: Maybe<&2, K.Config>}

# A controller (kube-runtime's Controller::new(..).owns(..).watches(..)):
# the primary with its label and field selectors, the predicates its
# changes pass, the related watches, how many reconciles run at once, and
# how long one may run (timeout ms, 0 for no limit).
type Spec is Data:
  Spec{primary: C.Api, label: String, field: String, preds: List<&2, Pred>, secs: List<&2, Sec>,
    max: U32, timeout: U32, cluster: Maybe<&2, K.Config>}

# A controller for primary: every change, no related watches, 8 at once,
# no timeout.
def Spec.of(primary: C.Api) -> Spec:
  Spec{primary, "", "", Nil{}, Nil{}, 8, 0, None{}}

def Spec.label(s: Spec, l: String) -> Spec:
  match s:
    case Spec{p, x, fs, ps, ss, m, to, cl}:
      Spec{p, l, fs, ps, ss, m, to, cl}

# The primary's field selector (for example "metadata.name=x").
def Spec.field(s: Spec, f: String) -> Spec:
  match s:
    case Spec{p, l, x, ps, ss, m, to, cl}:
      Spec{p, l, f, ps, ss, m, to, cl}

def Spec.filter(s: Spec, ps: List<&2, Pred>) -> Spec:
  match s:
    case Spec{p, l, fs, x, ss, m, to, cl}:
      Spec{p, l, fs, ps, ss, m, to, cl}

# At least 1.
def Spec.max(s: Spec, n: U32) -> Spec:
  match s:
    case Spec{p, l, fs, ps, ss, x, to, cl}:
      Spec{p, l, fs, ps, ss, U32.max(n, 1), to, cl}

# A reconcile still running after ms is hung: the process logs it and
# exits (status 1), so the pod restarts, as a crash would. A reconcile in
# Bend cannot be cancelled, and freeing its key while it still runs would
# let the same key run twice.
def Spec.timeout(s: Spec, ms: U32) -> Spec:
  match s:
    case Spec{p, l, fs, ps, ss, m, x, cl}:
      Spec{p, l, fs, ps, ss, m, ms, cl}

# Adds a related watch with label and field selectors ("" for none); the
# n-th one added is cache n (Ctx.cache).
def Spec.watches_where(s: Spec, a: C.Api, label: String, field: String, r: Rel) -> Spec:
  match s:
    case Spec{p, l, fs, ps, ss, m, to, cl}:
      Spec{p, l, fs, ps, List.append(&2, Sec, ss, [Sec{a, label, field, r, Nil{}, Nil{}, None{}}]), m, to, cl}

def Spec.watches(s: Spec, a: C.Api, r: Rel) -> Spec:
  Spec.watches_where(s, a, "", "", r)

# Objects of a's kind that the primary owns (ownerReferences to the
# primary's kind and group).
def Spec.owns(s: Spec, a: C.Api) -> Spec:
  Spec.watches_where(s, a, "", "", ROwner{})

def Spec.primary(s: Spec) -> C.Api:
  match s:
    case Spec{p, l, fs, ps, ss, m, to, cl}:
      p

def Spec.res(s: Spec) -> C.Res:
  match s:
    case Spec{C.Api{r, sc}, l, fs, ps, ss, m, to, cl}:
      r

def Spec.kind(s: Spec) -> String:
  C.Res.kind(Spec.res(s))

def Spec.preds(s: Spec) -> List<&2, Pred>:
  match s:
    case Spec{p, l, fs, ps, ss, m, to, cl}:
      ps

def Spec.secs(s: Spec) -> List<&2, Sec>:
  match s:
    case Spec{p, l, fs, ps, ss, m, to, cl}:
      ss

def Spec.max_of(s: Spec) -> U32:
  match s:
    case Spec{p, l, fs, ps, ss, m, to, cl}:
      m

def Spec.label_of(s: Spec) -> String:
  match s:
    case Spec{p, l, fs, ps, ss, m, to, cl}:
      l

def Spec.field_of(s: Spec) -> String:
  match s:
    case Spec{p, l, fs, ps, ss, m, to, cl}:
      fs

def Spec.timeout_of(s: Spec) -> U32:
  match s:
    case Spec{p, l, fs, ps, ss, m, to, cl}:
      to

def Sec.rel(s: Sec) -> Rel:
  match s:
    case Sec{a, l, f, r, d, ps, c}:
      r

def Sec.drop(s: Sec) -> List<&2, String>:
  match s:
    case Sec{a, l, f, r, d, ps, c}:
      d

def Secs.set_last(ss: List<&2, Sec>, +d: List<&2, String>) -> List<&2, Sec>:
  match ss:
    case Nil{}:
      Nil{}
    case Con{Sec{a, l, f, r, x, ps, c}, Nil{}}:
      [Sec{a, l, f, r, d, ps, c}]
    case Con{x, t}:
      x <> Secs.set_last(t, d)

# Drops top-level fields (for example "data" and "stringData" of Secrets)
# from the objects of the related watch added last, before they are
# cached: a controller that only needs to know a referenced Secret changed
# then holds no Secret's data. Reconcile reads what it needs with
# Client.get.
def Spec.drop(s: Spec, fields: List<&2, String>) -> Spec:
  match s:
    case Spec{p, l, fs, ps, ss, m, to, cl}:
      Spec{p, l, fs, ps, Secs.set_last(ss, fields), m, to, cl}

def Secs.filter_last(ss: List<&2, Sec>, +ps: List<&2, Pred>) -> List<&2, Sec>:
  match ss:
    case Nil{}:
      Nil{}
    case Con{Sec{a, l, f, r, d, x, c}, Nil{}}:
      [Sec{a, l, f, r, d, ps, c}]
    case Con{x, t}:
      x <> Secs.filter_last(t, ps)

def Secs.on_last(ss: List<&2, Sec>, +c: K.Config) -> List<&2, Sec>:
  match ss:
    case Nil{}:
      Nil{}
    case Con{Sec{a, l, f, r, d, ps, x}, Nil{}}:
      [Sec{a, l, f, r, d, ps, Some{K.Config.without_pool(c)}}]
    case Con{x, t}:
      x <> Secs.on_last(t, c)

# Filters the related watch added last (kube-runtime's predicate_filter on
# a watches() stream): a change to one of its objects triggers its
# primaries only when what the predicates see differs from the cached
# object (or nothing is cached). Deletions, relists that drop an object,
# a new uid, the start of a deletion and a change of finalizers always
# pass, as for the primary. With no predicates (the default), every change
# triggers.
def Spec.watch_filter(s: Spec, ps: List<&2, Pred>) -> Spec:
  match s:
    case Spec{p, l, fs, x, ss, m, to, cl}:
      Spec{p, l, fs, x, Secs.filter_last(ss, ps), m, to, cl}

# Runs the related watch added last against another cluster: c, not the
# controller's config. Its objects map to primaries as any related
# watch's do, and Ctx.cluster(ctx, n) hands the reconcile the same config.
# c keeps its rate limit (Kube.connect adds one) but not its connection
# pool: a pool holds connections to one server, so Kube.control gives each
# such config a pool of its own. Under leader election c also takes the
# controllers' leadership fence, so no request to any cluster outlives
# the lease.
def Spec.watch_on(s: Spec, c: K.Config) -> Spec:
  match s:
    case Spec{p, l, fs, ps, ss, m, to, cl}:
      Spec{p, l, fs, ps, Secs.on_last(ss, c), m, to, cl}

# Watches the primary on another cluster: c, not the controller's config
# (which still holds the lease and serves Ctx.cfg). Ctx.cluster(ctx, 0) is
# c, fenced as Spec.watch_on says.
def Spec.on(s: Spec, c: K.Config) -> Spec:
  match s:
    case Spec{p, l, fs, ps, ss, m, to, x}:
      Spec{p, l, fs, ps, ss, m, to, Some{K.Config.without_pool(c)}}

# The reconcile timeout, ms (0 for none) a spec without its own takes
# (Opts.with_timeout): a spec's own timeout wins.
def Spec.timeout_or(s: Spec, +ms: U32) -> Spec:
  match s:
    case Spec{p, l, fs, ps, ss, m, 0, cl}:
      Spec{p, l, fs, ps, ss, m, ms, cl}
    case x:
      x

def Spec.cluster_of(s: Spec) -> Maybe<&2, K.Config>:
  match s:
    case Spec{p, l, fs, ps, ss, m, to, cl}:
      cl

def Sec.preds(s: Sec) -> List<&2, Pred>:
  match s:
    case Sec{a, l, f, r, d, ps, c}:
      ps

def Sec.cluster(s: Sec) -> Maybe<&2, K.Config>:
  match s:
    case Sec{a, l, f, r, d, ps, c}:
      c

# The config a watch runs against: the controllers' own (main), or
# another cluster's, under main's leadership fence.
def Cluster.of(+main: K.Config, m: Maybe<&2, K.Config>) -> K.Config:
  match m:
    case None{}:
      main
    case Some{c}:
      K.Config.fence_as(c, K.Config.fence(main))

def Cluster.secs(ss: List<&2, Sec>, +main: K.Config) -> List<&2, K.Config>:
  match ss:
    case Nil{}:
      Nil{}
    case Con{s, t}:
      Cluster.of(main, Sec.cluster(s)) <> Cluster.secs(t, main)

# Every watch's config, the primary's first, then each related watch's in
# the order they were added.
def Spec.clusters(s: Spec, +main: K.Config) -> List<&2, K.Config>:
  match s:
    case Spec{p, l, fs, ps, ss, m, to, cl}:
      Cluster.of(main, cl) <> Cluster.secs(ss, main)

def Out.trim.obj(fs: List<&2, String>, +x: J.Json) -> J.Json:
  match fs:
    case Nil{}:
      x
    case Con{+f, t}:
      Out.trim.obj(t, J.Json.del(x, f))

def Out.trim(+fs: List<&2, String>, o: W.Out) -> W.Out:
  match o:
    case W.OApply{+x}:
      W.OApply{Out.trim.obj(fs, x)}
    case W.OInitApply{+x}:
      W.OInitApply{Out.trim.obj(fs, x)}
    case W.ODelete{+x}:
      W.ODelete{Out.trim.obj(fs, x)}
    case e:
      e

# A related watch's outputs with its dropped fields removed.
def Out.trim_all(+fs: List<&2, String>, os: List<&2, W.Out>) -> List<&2, W.Out>:
  match os:
    case Nil{}:
      Nil{}
    case Con{o, t}:
      Out.trim(fs, o) <> Out.trim_all(fs, t)

# Objects for the mapper
# ----------------------

# A related object the controller's mapper (RMap) is to map: the related
# watch it came from (from 1) and the object, as JSON text.
type Mapped is Data:
  Mapped{n: U32, obj: String}

# A fold's keys, split: plain keys, and objects for the mapper.
type Split is Data:
  Split{keys: List<&2, String>, objs: List<&2, Mapped>}

def Split.put(+n: U32, +k: String, marked: Bool, r: Split) -> Split:
  match marked r:
    case True{} Split{ks, os}:
      Split{ks, Mapped{n, String.drop(k, String.length(Mapped.mark()))} <> os}
    case False{} Split{ks, os}:
      Split{k <> ks, os}

def Mapped.split(ks: List<&2, String>, +n: U32) -> Split:
  match ks:
    case Nil{}:
      Split{Nil{}, Nil{}}
    case Con{+k, t}:
      Split.put(n, k, String.starts_with(k, Mapped.mark()), Mapped.split(t, n))

# Metrics a controller defines
# ----------------------------

# What a reconcile tells the meter: add n to a counter, set a gauge, or (the
# health server) ask for every series in the Prometheus text format.
# labels is the inside of the braces, as `kind="x",phase="y"` ("" for none).
type Meter is Data:
  MAdd{name: String, labels: String, n: U32}
  MSet{name: String, labels: String, v: U32}
  MDrop{name: String, labels: String}
  MRead{reply: Chan(String)}

# The reconcile context
# ---------------------

# cfg: the client config; idx: the controller's index (0 for a lone
# controller); store: the primary's cache; caches: each related watch's,
# in the order they were added (Ctx.cache(c, 1) is the first); fails: how
# many times in a row this key's reconcile has failed (0 after a success),
# so a reconcile can escalate or give up; meter: where the controller's own
# metrics go (Metrics.add, Metrics.set), None outside Kube.control;
# clusters: each watch's config, the primary's first (Ctx.cluster).
type Ctx is Data:
  Ctx{cfg: K.Config, idx: U32, store: S.Store, caches: List<&2, S.Store>, fails: U32,
    meter: Maybe<&2, Chan(Meter)>, clusters: List<&2, K.Config>}

def Ctx.cfg(c: Ctx) -> K.Config:
  match c:
    case Ctx{cfg, i, s, cs, fl, mt, cl}:
      cfg

def Ctx.idx(c: Ctx) -> U32:
  match c:
    case Ctx{cfg, i, s, cs, fl, mt, cl}:
      i

def Ctx.store(c: Ctx) -> S.Store:
  match c:
    case Ctx{cfg, i, s, cs, fl, mt, cl}:
      s

def Ctx.with_fails(c: Ctx, n: U32) -> Ctx:
  match c:
    case Ctx{cfg, i, s, cs, fl, mt, cl}:
      Ctx{cfg, i, s, cs, n, mt, cl}

def Ctx.meter(c: Ctx) -> Maybe<&2, Chan(Meter)>:
  match c:
    case Ctx{cfg, i, s, cs, fl, mt, cl}:
      mt

def Ctx.fails(c: Ctx) -> U32:
  match c:
    case Ctx{cfg, i, s, cs, fl, mt, cl}:
      fl

# The config of watch n: 0 the primary's, n the n-th related watch's (as
# Ctx.cache counts); the controller's own (Ctx.cfg) unless the spec put
# the watch on another cluster (Spec.on, Spec.watch_on).
def Ctx.cluster(c: Ctx, n: U32) -> K.Config:
  match c:
    case Ctx{cfg, i, s, cs, fl, mt, cl}:
      Maybe.default(&2, K.Config, List.get(&2, K.Config, cl, U32.to_nat(n)), cfg)

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
    case Ctx{cfg, i, s, cs, fl, mt, cl}:
      Ctx.nth(cs, U32.to_nat((n - 1 : U32)))

# A cached related object under a key.
def Ctx.find(c: Ctx, n: U32, key: String) -> Maybe<&2, J.Json>:
  S.Store.get(Ctx.cache(c, n), key)

# Every cached object of the n-th related watch.
def Ctx.all(c: Ctx, n: U32) -> List<&2, J.Json>:
  S.Store.values(Ctx.cache(c, n))

def Owned.ctl(j: J.Json) -> Bool:
  match j:
    case J.JBool{b}:
      b
    case _:
      False{}

def Owned.uid.any(rs: List<&2, J.Json>, +uid: String) -> Bool:
  match rs:
    case Nil{}:
      False{}
    case Con{+r, t}:
      Bool.or(Bool.and(String.eq(J.Json.str_or(J.Json.get(r, "uid"), ""), uid),
        Owned.ctl(J.Json.get(r, "controller"))), Owned.uid.any(t, uid))

# Whether o's controller (the owner reference with controller: true) has
# this uid (metav1.IsControlledBy).
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

# The cached objects of the n-th related watch that owner controls (by
# uid, with controller: true).
def Ctx.children(c: Ctx, n: U32, +owner: J.Json) -> List<&2, J.Json>:
  Owned.pick(Ctx.all(c, n), C.Obj.uid(owner))
