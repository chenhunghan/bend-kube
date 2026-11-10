import Base
import ../../src/json.bend as J
import ../../src/core.bend as C
import ../../src/queue.bend as Q
import ../../src/control.bend as X
import ../../src/kube.bend as Kb
import ../../src/log.bend as L

# An e2e probe for a related watch mapped by code (X.RMap,
# Kube.control_mapped): ConfigMaps labeled bend-kube/mapped=true in
# bend-e2e are the primaries; a Secret there names its primaries in the
# annotation bend-kube/for, as a comma-separated list. Each reconcile logs
# "reconciled" with its key, so a Secret's change shows which primaries it
# woke.

def api() -> C.Api:
  C.Api{C.Res.config_maps(), C.InNs{"bend-e2e"}}

def secrets() -> C.Api:
  C.Api{C.Res{"", "v1", "Secret", "secrets", True{}}, C.InNs{"bend-e2e"}}

def keys(ns: List<&2, String>, +namespace: String) -> List<&2, String>:
  match ns:
    case Nil{}:
      Nil{}
    case Con{n, t}:
      C.Obj.key.of(namespace, n) <> keys(t, namespace)

def map.go(+o: J.Json) -> List<&2, String>:
  keys(String.split(J.Json.str_or(J.Json.get(C.Obj.meta(o, "annotations"), "bend-kube/for"), ""), ','),
    C.Obj.namespace(o))

def map(n: U32, o: J.Json, c: X.Ctx) -> List<&2, String>:
  map.go(o)

def rec.of(+o: J.Json) -> IO(Q.Action):
  IO.bind(Unit, Q.Action, L.Log.info("reconciled", [L.Log.kv("key", C.Obj.key(o))]),
    u => IO.pure(Q.Action, Q.AwaitChange{}))

def rec(o: J.Json, c: X.Ctx) -> IO(Q.Action):
  rec.of(o)

def main() -> IO(Unit):
  Kb.Kube.control_mapped(~rec, ~map,
    X.Spec.drop(X.Spec.watches(X.Spec.label(X.Spec.of(api()), "bend-kube/mapped=true"), secrets(), X.RMap{}),
      ["data", "stringData"]),
    Kb.Opts.with_port(Kb.Opts.default(), 0))
