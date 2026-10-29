import Base
import ../src/json.bend as J
import ../src/core.bend as C
import ../src/config.bend as K
import ../src/client.bend as Cl

def names(xs: List<&2, J.Json>) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{x, t}:
      C.Obj.name(x) ++ " " ++ names(t)

def show(r: Result<&2, &2, Cl.KErr, J.Json>) -> String:
  match r:
    case Done{j}:
      "ok " ++ names(J.Json.items(J.Json.get(j, "items")))
    case Fail{e}:
      "error " ++ Cl.KErr.show(e)

def run(c: Result<&2, &2, String, K.Config>) -> IO(Unit):
  match c:
    case Done{+cfg}:
      do IO<Unit>:
        v : Result<&2, &2, Cl.KErr, J.Json> <- Cl.Client.json(cfg, C.Req.get("/version"))
        ns : Result<&2, &2, Cl.KErr, J.Json> <- Cl.Client.list(cfg, C.Api{C.Res.namespaces(), C.Cluster{}}, C.ListParams.default())
        IO.print(show(ns))
        missing : Result<&2, &2, Cl.KErr, J.Json> <- Cl.Client.get(cfg, C.Api{C.Res.config_maps(), C.InNs{"default"}}, "does-not-exist")
        IO.print(show(missing))
    case Fail{e}:
      IO.print("config: " ++ e)

def main() -> IO(Unit):
  do IO<Unit>:
    c : Result<&2, &2, String, K.Config> <- Cl.Config.infer()
    run(c)
