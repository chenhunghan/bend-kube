import Base
import ./json.bend as J
import ./http.bend as H

# Core
# ====
#
# kube-core in Bend: what a resource is, the requests every verb makes, and
# the shapes the API answers with. Pure: nothing here touches the network.
# Objects are dynamic JSON (kube-core's DynamicObject); typed views read
# their fields with Obj.*.

# A resource kind, as discovery would describe it (kube-core ApiResource).
type Res is Data:
  Res{group: String, version: String, kind: String, plural: String, namespaced: Bool}

# Where an Api points: every namespace, one namespace, or cluster scope.
type Scope is Data:
  AllNs{}
  InNs{ns: String}
  Cluster{}

type Api is Data:
  Api{res: Res, scope: Scope}

type ListParams is Data:
  ListParams{label: String, field: String, limit: U32, cont: String, rv: String}

type WatchParams is Data:
  WatchParams{label: String, field: String, timeout: U32, bookmarks: Bool}

# How a patch body merges (kube-core Patch).
type PatchKind is Data:
  PMerge{}
  PJson{}
  PStrategic{}
  PApply{manager: String, force: Bool}

# Well-known resources
# --------------------

def Res.core(kind: String, plural: String, ns: Bool) -> Res:
  Res{"", "v1", kind, plural, ns}

def Res.pods() -> Res:
  Res.core("Pod", "pods", True{})

def Res.config_maps() -> Res:
  Res.core("ConfigMap", "configmaps", True{})

def Res.secrets() -> Res:
  Res.core("Secret", "secrets", True{})

def Res.services() -> Res:
  Res.core("Service", "services", True{})

def Res.namespaces() -> Res:
  Res.core("Namespace", "namespaces", False{})

def Res.events() -> Res:
  Res{"events.k8s.io", "v1", "Event", "events", True{}}

def Res.deployments() -> Res:
  Res{"apps", "v1", "Deployment", "deployments", True{}}

def Res.leases() -> Res:
  Res{"coordination.k8s.io", "v1", "Lease", "leases", True{}}

def Res.crds() -> Res:
  Res{"apiextensions.k8s.io", "v1", "CustomResourceDefinition", "customresourcedefinitions", False{}}

def Res.api_version.go(g: String, v: String, core: Bool) -> String:
  match core:
    case True{}:
      v
    case False{}:
      g ++ "/" ++ v

def Res.api_version(r: Res) -> String:
  match r:
    case Res{+g, v, k, p, n}:
      Res.api_version.go(g, v, String.is_empty(g))

# Paths
# -----

def Api.prefix(g: String, v: String, core: Bool) -> String:
  match core:
    case True{}:
      "/api/" ++ v
    case False{}:
      "/apis/" ++ g ++ "/" ++ v

def Api.ns_part(s: Scope, namespaced: Bool) -> String:
  match s namespaced:
    case InNs{ns} True{}:
      "/namespaces/" ++ H.Http.encode(ns)
    case _ _:
      ""

# The collection's path, as kube-core's url_path: /api/v1/namespaces/x/pods.
def Api.path(a: Api) -> String:
  match a:
    case Api{Res{+g, v, k, p, n}, s}:
      Api.prefix(g, v, String.is_empty(g)) ++ Api.ns_part(s, n) ++ "/" ++ p

def Api.item(a: Api, name: String) -> String:
  Api.path(a) ++ "/" ++ H.Http.encode(name)

# Queries
# -------

type Q is Data:
  Q{key: String, val: String}

def Query.go.put(k: String, v: String, rest: List<&2, String>, empty: Bool) -> List<&2, String>:
  match empty:
    case True{}:
      rest
    case False{}:
      (H.Http.encode(k) ++ "=" ++ H.Http.encode(v)) <> rest

# Drops pairs with an empty value, then joins "?k=v&k=v".
def Query.go(qs: List<&2, Q>) -> List<&2, String>:
  match qs:
    case Nil{}:
      Nil{}
    case Con{Q{k, +v}, t}:
      Query.go.put(k, v, Query.go(t), String.is_empty(v))

def Query.render.go(ps: List<&2, String>) -> String:
  match ps:
    case Nil{}:
      ""
    case +xs:
      "?" ++ String.join(xs, "&")

def Query.render(qs: List<&2, Q>) -> String:
  Query.render.go(Query.go(qs))

def Query.u32.go(+n: U32, zero: Bool) -> String:
  match zero:
    case True{}:
      ""
    case False{}:
      U32.show(n)

def Query.u32(+n: U32) -> String:
  Query.u32.go(n, U32.is_eq(n, 0))

def Query.bool(b: Bool) -> String:
  match b:
    case True{}:
      "true"
    case False{}:
      ""

def ListParams.default() -> ListParams:
  ListParams{"", "", 500, "", ""}

def WatchParams.default() -> WatchParams:
  WatchParams{"", "", 290, True{}}

def ListParams.query(lp: ListParams) -> List<&2, Q>:
  match lp:
    case ListParams{l, f, n, c, rv}:
      [Q{"labelSelector", l}, Q{"fieldSelector", f}, Q{"limit", Query.u32(n)},
        Q{"continue", c}, Q{"resourceVersion", rv}]

def WatchParams.query(wp: WatchParams, rv: String) -> List<&2, Q>:
  match wp:
    case WatchParams{l, f, t, b}:
      [Q{"watch", "true"}, Q{"labelSelector", l}, Q{"fieldSelector", f},
        Q{"timeoutSeconds", Query.u32(t)}, Q{"allowWatchBookmarks", Query.bool(b)},
        Q{"resourceVersion", rv}]

# Requests
# --------

def Req.json_headers() -> List<&2, H.Header>:
  [H.Header{"Accept", "application/json"}]

def Req.body_headers(ct: String) -> List<&2, H.Header>:
  [H.Header{"Accept", "application/json"}, H.Header{"Content-Type", ct}]

def Req.get(path: String) -> H.Req:
  H.Req{"GET", path, Req.json_headers(), ""}

def Req.list(a: Api, lp: ListParams) -> H.Req:
  Req.get(Api.path(a) ++ Query.render(ListParams.query(lp)))

def Req.watch(a: Api, wp: WatchParams, rv: String) -> H.Req:
  Req.get(Api.path(a) ++ Query.render(WatchParams.query(wp, rv)))

def Req.read(a: Api, name: String) -> H.Req:
  Req.get(Api.item(a, name))

def Req.create(a: Api, obj: J.Json) -> H.Req:
  H.Req{"POST", Api.path(a), Req.body_headers("application/json"), J.Json.show(obj)}

def Req.replace(a: Api, name: String, obj: J.Json) -> H.Req:
  H.Req{"PUT", Api.item(a, name), Req.body_headers("application/json"), J.Json.show(obj)}

def Req.delete(a: Api, name: String) -> H.Req:
  H.Req{"DELETE", Api.item(a, name), Req.json_headers(), ""}

def PatchKind.content_type(p: PatchKind) -> String:
  match p:
    case PMerge{}:
      "application/merge-patch+json"
    case PJson{}:
      "application/json-patch+json"
    case PStrategic{}:
      "application/strategic-merge-patch+json"
    case PApply{m, f}:
      "application/apply-patch+yaml"

def PatchKind.query(p: PatchKind) -> List<&2, Q>:
  match p:
    case PApply{m, f}:
      [Q{"fieldManager", m}, Q{"force", Query.bool(f)}]
    case _:
      Nil{}

def Req.sub.go(s: String, empty: Bool) -> String:
  match empty:
    case True{}:
      ""
    case False{}:
      "/" ++ s

def Req.sub(+s: String) -> String:
  Req.sub.go(s, String.is_empty(s))

# A patch of the object, or of a subresource ("status", "scale") when sub
# is not empty. Server-side apply (PApply) sends JSON, which is YAML.
def Req.patch(a: Api, name: String, +sub: String, +p: PatchKind, body: J.Json) -> H.Req:
  H.Req{"PATCH", Api.item(a, name) ++ Req.sub(sub) ++ Query.render(PatchKind.query(p)),
    Req.body_headers(PatchKind.content_type(p)), J.Json.show(body)}

def Req.replace_status(a: Api, name: String, obj: J.Json) -> H.Req:
  H.Req{"PUT", Api.item(a, name) ++ "/status", Req.body_headers("application/json"),
    J.Json.show(obj)}

# Objects
# -------

def Obj.meta(o: J.Json, field: String) -> J.Json:
  J.Json.get(J.Json.get(o, "metadata"), field)

def Obj.name(o: J.Json) -> String:
  J.Json.str_or(Obj.meta(o, "name"), "")

def Obj.namespace(o: J.Json) -> String:
  J.Json.str_or(Obj.meta(o, "namespace"), "")

def Obj.uid(o: J.Json) -> String:
  J.Json.str_or(Obj.meta(o, "uid"), "")

def Obj.rv(o: J.Json) -> String:
  J.Json.str_or(Obj.meta(o, "resourceVersion"), "")

def Obj.num_text(j: J.Json) -> String:
  match j:
    case J.JNum{s}:
      s
    case _:
      ""

def Obj.generation(o: J.Json) -> String:
  Obj.num_text(Obj.meta(o, "generation"))

def Obj.is_deleting(o: J.Json) -> Bool:
  Bool.not(J.Json.is_null(Obj.meta(o, "deletionTimestamp")))

def Obj.strs(xs: List<&2, J.Json>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{J.JStr{s}, t}:
      s <> Obj.strs(t)
    case Con{x, t}:
      Obj.strs(t)

def Obj.finalizers(o: J.Json) -> List<&2, String>:
  Obj.strs(J.Json.items(Obj.meta(o, "finalizers")))

def Obj.label(o: J.Json, key: String) -> Maybe<&2, String>:
  J.Json.as_str(J.Json.get(Obj.meta(o, "labels"), key))

def Obj.key.go(ns: String, name: String, cluster: Bool) -> String:
  match cluster:
    case True{}:
      name
    case False{}:
      ns ++ "/" ++ name

def Obj.key.of(+ns: String, name: String) -> String:
  Obj.key.go(ns, name, String.is_empty(ns))

# The store key, as client-go's MetaNamespaceKeyFunc: "ns/name", or "name"
# for cluster-scoped objects.
def Obj.key(+o: J.Json) -> String:
  Obj.key.of(Obj.namespace(o), Obj.name(o))

# An object reference: what a reconcile is keyed by (kube-runtime ObjectRef).
type ObjRef is Data:
  ObjRef{ns: String, name: String}

def ObjRef.key(r: ObjRef) -> String:
  match r:
    case ObjRef{ns, name}:
      Obj.key.of(ns, name)

def ObjRef.of(+o: J.Json) -> ObjRef:
  ObjRef{Obj.namespace(o), Obj.name(o)}

def Obj.owners.put(ns: String, name: String, hit: Bool, rest: List<&2, ObjRef>) ->
  List<&2, ObjRef>:
  match hit:
    case True{}:
      ObjRef{ns, name} <> rest
    case False{}:
      rest

def Obj.owners.go(xs: List<&2, J.Json>, +ns: String, +kind: String) -> List<&2, ObjRef>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{+r, t}:
      Obj.owners.put(ns, J.Json.str_or(J.Json.get(r, "name"), ""),
        String.eq(J.Json.str_or(J.Json.get(r, "kind"), ""), kind), Obj.owners.go(t, ns, kind))

# The owners an object names of a kind (kube-runtime's trigger_owners): each
# is a reference in the object's namespace.
def Obj.owners(+o: J.Json, +kind: String) -> List<&2, ObjRef>:
  Obj.owners.go(J.Json.items(Obj.meta(o, "ownerReferences")), Obj.namespace(o), kind)

def Res.kind(r: Res) -> String:
  match r:
    case Res{g, v, k, p, n}:
      k

# An owner reference to o, for objects a controller creates.
def Obj.owner_ref(+o: J.Json, +res: Res) -> J.Json:
  J.Json.obj([J.KV{"apiVersion", J.JStr{Res.api_version(res)}}, J.KV{"kind", J.JStr{Res.kind(res)}},
    J.KV{"name", J.JStr{Obj.name(o)}}, J.KV{"uid", J.JStr{Obj.uid(o)}},
    J.KV{"controller", J.JBool{True{}}}, J.KV{"blockOwnerDeletion", J.JBool{True{}}}])

# Lists and watch events
# ----------------------

type Page is Data:
  Page{items: List<&2, J.Json>, rv: String, cont: String}

def Page.of(+j: J.Json) -> Page:
  Page{J.Json.items(J.Json.get(j, "items")),
    J.Json.str_or(J.Json.at(j, ["metadata", "resourceVersion"]), ""),
    J.Json.str_or(J.Json.at(j, ["metadata", "continue"]), "")}

# A metav1.Status: the code, reason and message an error answers with.
type Status is Data:
  Status{code: U32, reason: String, message: String}

def Status.of(+j: J.Json) -> Status:
  Status{Maybe.default(&2, U32, J.Json.as_u32(J.Json.get(j, "code")), 0),
    J.Json.str_or(J.Json.get(j, "reason"), ""), J.Json.str_or(J.Json.get(j, "message"), "")}

def Status.show(s: Status) -> String:
  match s:
    case Status{c, r, m}:
      U32.show(c) ++ " " ++ r ++ ": " ++ m

type WEvent is Data:
  WAdded{obj: J.Json}
  WModified{obj: J.Json}
  WDeleted{obj: J.Json}
  WBookmark{rv: String}
  WError{status: Status}
  WBad{msg: String}

def WEvent.of.go(t: String, +o: J.Json) -> WEvent:
  match t:
    case "ADDED":
      WAdded{o}
    case "MODIFIED":
      WModified{o}
    case "DELETED":
      WDeleted{o}
    case "BOOKMARK":
      WBookmark{Obj.rv(o)}
    case "ERROR":
      WError{Status.of(o)}
    case _:
      WBad{"unknown watch event type"}

def WEvent.of(+j: J.Json) -> WEvent:
  WEvent.of.go(J.Json.str_or(J.Json.get(j, "type"), ""), J.Json.get(j, "object"))

def WEvent.parse.go(r: Result<&2, &2, String, J.Json>) -> WEvent:
  match r:
    case Done{j}:
      WEvent.of(j)
    case Fail{e}:
      WBad{e}

def WEvent.parse(line: String) -> WEvent:
  WEvent.parse.go(J.Json.parse(line))
