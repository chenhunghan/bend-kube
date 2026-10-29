import Base
import ./json.bend as J
import ./core.bend as C

# Finalizer
# =========
#
# kube-runtime's finalizer helper, decided purely. An object a controller
# cleans up after carries the controller's finalizer:
#
# - live, without it: add it (and reconcile on the change that follows);
# - live, with it: apply;
# - deleting, with it: clean up, then remove it so deletion proceeds;
# - deleting, without it: nothing left to do.
#
# Every patch is a JSON patch that first tests what it read, so it fails
# (and the reconcile retries) instead of clobbering another controller's
# finalizer, as kube-runtime's does.

type FState is Data:
  FApply{}
  FAdd{patch: J.Json}
  FCleanup{patch: J.Json}
  FDone{}

def Fin.op(op: String, path: String, v: J.Json) -> J.Json:
  J.Json.obj([J.KV{"op", J.JStr{op}}, J.KV{"path", J.JStr{path}}, J.KV{"value", v}])

def Fin.strs(xs: List<&2, String>) -> List<&2, J.Json>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{x, t}:
      J.JStr{x} <> Fin.strs(t)

def Fin.add_patch.go(fs: List<&2, String>, name: String, empty: Bool) -> J.Json:
  match empty:
    case True{}:
      J.Json.arr([Fin.op("test", "/metadata/finalizers", J.JNull{}),
        Fin.op("add", "/metadata/finalizers", J.Json.arr([J.JStr{name}]))])
    case False{}:
      J.Json.arr([Fin.op("test", "/metadata/finalizers", J.Json.arr(Fin.strs(fs))),
        Fin.op("add", "/metadata/finalizers/-", J.JStr{name})])

# The patch that adds name to finalizers fs.
def Fin.add_patch(+fs: List<&2, String>, name: String) -> J.Json:
  Fin.add_patch.go(fs, name, List.is_empty(&2, String, fs))

# The patch that removes the finalizer at index i, if it is still name.
def Fin.remove_patch(+i: U32, name: String) -> J.Json:
  J.Json.arr([Fin.op("test", "/metadata/finalizers/" ++ U32.show(i), J.JStr{name}),
    J.Json.obj([J.KV{"op", J.JStr{"remove"}}, J.KV{"path", J.JStr{"/metadata/finalizers/" ++ U32.show(i)}}])])

def Fin.index.if(+i: U32, rest: Maybe<&2, U32>, hit: Bool) -> Maybe<&2, U32>:
  match hit:
    case True{}:
      Some{i}
    case False{}:
      rest

# Where name sits among the finalizers, counting from i.
def Fin.index(fs: List<&2, String>, +name: String, +i: U32) -> Maybe<&2, U32>:
  match fs:
    case Nil{}:
      None{}
    case Con{f, t}:
      Fin.index.if(i, Fin.index(t, name, (i + 1 : U32)), String.eq(f, name))

def Fin.state.go(+fs: List<&2, String>, +name: String, at: Maybe<&2, U32>, deleting: Bool) ->
  FState:
  match at deleting:
    case Some{i} False{}:
      FApply{}
    case Some{i} True{}:
      FCleanup{Fin.remove_patch(i, name)}
    case None{} False{}:
      FAdd{Fin.add_patch(fs, name)}
    case None{} True{}:
      FDone{}

# What the object needs, for the finalizer called name.
def Fin.state(+o: J.Json, +name: String) -> FState:
  Fin.state.go(C.Obj.finalizers(o), name, Fin.index(C.Obj.finalizers(o), name, 0),
    C.Obj.is_deleting(o))
