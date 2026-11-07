import Base
import ../../src/json.bend as J
import ../../src/core.bend as C
import ../../src/client.bend as Cl
import ../../src/queue.bend as Q
import ../../src/control.bend as X
import ../../src/kube.bend as Kb
import ../../src/log.bend as L

# An e2e probe for the rate limit and the drain: each ConfigMap labeled
# bend-kube/slow=true in bend-e2e gets a reconcile that makes 12 GETs
# through a 4 qps limit with bursts of 2 (the list takes a token too, so
# about 2.75s), logs "gets done", sleeps 3s, and logs "end". A SIGTERM
# after "gets done" must wait for "end" before the process exits.

def gets(n: Nat, +c: X.Ctx, +name: String) -> IO(Unit):
  match n:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+k:
      IO.bind(Result<&2, &2, Cl.KErr, J.Json>, Unit,
        Cl.Client.get(X.Ctx.cfg(c), C.Api{C.Res.config_maps(), C.InNs{"bend-e2e"}}, name),
        r => gets(k, c, name))

def rec.of(+o: J.Json, +c: X.Ctx) -> IO(Q.Action):
  do IO<Q.Action>:
    L.Log.info("start", [L.Log.kv("name", C.Obj.name(o))])
    gets(12n, c, C.Obj.name(o))
    L.Log.info("gets done", [L.Log.kv("name", C.Obj.name(o))])
    IO.sleep(3000)
    L.Log.info("end", [L.Log.kv("name", C.Obj.name(o))])
    return Q.AwaitChange{}

def rec(o: J.Json, c: X.Ctx) -> IO(Q.Action):
  rec.of(o, c)

def main() -> IO(Unit):
  Kb.Kube.control(~rec,
    X.Spec.label(X.Spec.of(C.Api{C.Res.config_maps(), C.InNs{"bend-e2e"}}), "bend-kube/slow=true"),
    Kb.Opts.with_rate(Kb.Opts.with_port(Kb.Opts.default(), 0), 4, 2))
