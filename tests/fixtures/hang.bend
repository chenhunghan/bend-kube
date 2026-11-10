import Base
import ../../src/json.bend as J
import ../../src/core.bend as C
import ../../src/queue.bend as Q
import ../../src/control.bend as X
import ../../src/kube.bend as Kb
import ../../src/log.bend as L

# An e2e probe for the reconcile timeout (Opts.with_timeout, 2s, kept by
# the controller's watchdog): each ConfigMap labeled bend-kube/hang=true in
# bend-e2e reconciles by sleeping its data.ms, then logs "slept". One under
# the timeout finishes and the process lives on; one past it makes the
# process log "reconcile hung" and exit with status 1.

def rec.of(+o: J.Json, +ms: U32) -> IO(Q.Action):
  do IO<Q.Action>:
    L.Log.info("sleeping", [L.Log.kv("key", C.Obj.key(o)), L.Log.kv("ms", U32.show(ms))])
    IO.sleep(ms)
    L.Log.info("slept", [L.Log.kv("key", C.Obj.key(o))])
    return Q.AwaitChange{}

def rec.go(+o: J.Json) -> IO(Q.Action):
  rec.of(o, Maybe.default(&2, U32, U32.read(J.Json.str_or(J.Json.at(o, ["data", "ms"]), "0")), 0))

def rec(o: J.Json, c: X.Ctx) -> IO(Q.Action):
  rec.go(o)

def main() -> IO(Unit):
  Kb.Kube.control(~rec, X.Spec.label(X.Spec.of(C.Api{C.Res.config_maps(), C.InNs{"bend-e2e"}}), "bend-kube/hang=true"),
    Kb.Opts.with_timeout(Kb.Opts.with_port(Kb.Opts.default(), 0), 2000))
