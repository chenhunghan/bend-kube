import Base
import ../../src/json.bend as J
import ../../src/core.bend as C
import ../../src/config.bend as K
import ../../src/client.bend as Cl

# An e2e probe for Client.replace_retry: the ConfigMap "conflict" in
# bend-e2e is read, changed behind our back (a second write bumps its
# resourceVersion), and then put with the stale version. A plain replace
# must fail with 409; replace_retry must re-read, take the fresh version
# and succeed. With no tries left it fails with the 409 too.

def api() -> C.Api:
  C.Api{C.Res.config_maps(), C.InNs{"bend-e2e"}}

def with_a(+o: J.Json, +v: String) -> J.Json:
  J.Json.set(o, "data", J.Json.obj([J.KV{"a", J.JStr{v}}]))

# A body for a ConfigMap that does not exist: its own name, no version.
def missing() -> J.Json:
  J.Json.obj([J.KV{"apiVersion", J.JStr{"v1"}}, J.KV{"kind", J.JStr{"ConfigMap"}},
    J.KV{"metadata", J.Json.obj([J.KV{"name", J.JStr{"no-such-cm"}}, J.KV{"namespace", J.JStr{"bend-e2e"}}])}])

def show(r: Result<&2, &2, Cl.KErr, J.Json>) -> String:
  match r:
    case Done{+j}:
      "ok a=" ++ J.Json.str_or(J.Json.at(j, ["data", "a"]), "?")
    case Fail{+e}:
      "fail " ++ U32.show(Cl.KErr.code(e))

def run.got(+cfg: K.Config, r: Result<&2, &2, Cl.KErr, J.Json>) -> IO(Unit):
  match r:
    case Done{+stale}:
      do IO<Unit>:
        bump : Result<&2, &2, Cl.KErr, J.Json> <- Cl.Client.replace(cfg, api(), "conflict", with_a(stale, "bumped"))
        IO.print("bump: " ++ show(bump))
        plain : Result<&2, &2, Cl.KErr, J.Json> <- Cl.Client.replace(cfg, api(), "conflict", with_a(stale, "plain"))
        IO.print("stale replace: " ++ show(plain))
        none : Result<&2, &2, Cl.KErr, J.Json> <- Cl.Client.replace_retry(cfg, api(), "conflict", with_a(stale, "none"), 0)
        IO.print("stale replace_retry, 0 tries: " ++ show(none))
        retry : Result<&2, &2, Cl.KErr, J.Json> <- Cl.Client.replace_retry(cfg, api(), "conflict", with_a(stale, "retried"), 3)
        IO.print("stale replace_retry, 3 tries: " ++ show(retry))
        gone : Result<&2, &2, Cl.KErr, J.Json> <- Cl.Client.replace_retry(cfg, api(), "no-such-cm", missing(), 3)
        IO.print("replace_retry of a missing object: " ++ show(gone))
    case Fail{+e}:
      IO.print("read failed: " ++ Cl.KErr.show(e))

def run(c: Result<&2, &2, String, K.Config>) -> IO(Unit):
  match c:
    case Done{+cfg}:
      IO.bind(Result<&2, &2, Cl.KErr, J.Json>, Unit, Cl.Client.get(cfg, api(), "conflict"), r => run.got(cfg, r))
    case Fail{e}:
      IO.print("no config: " ++ e)

def main() -> IO(Unit):
  IO.bind(Result<&2, &2, String, K.Config>, Unit, Cl.Config.infer(), run)
