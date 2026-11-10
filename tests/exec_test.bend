import Base
import ../src/config.bend as K
import ../src/client.bend as Cl

# An exec credential plugin runs once per token, not once per request:
# three loads of a token good for an hour run the plugin once; a token
# that has already expired runs it every time. The plugin (sh) counts its
# runs in a file.

def plugin(+file: String, +exp: String) -> K.Src:
  K.FromExec{"sh", ["-c", "echo run >> " ++ file ++ "; printf '{\"apiVersion\":\"client.authentication.k8s.io/v1\",\"kind\":\"ExecCredential\",\"status\":{\"token\":\"tok\"" ++ exp ++ "}}'"]}

def show(r: Result<&1, &1, U32 & String, String>) -> String:
  match r:
    case Done{t}:
      t
    case Fail{(c, m)}:
      "fail: " ++ m

def runs.got(r: Result<&1, &1, U32 & String, U32 & (String & String)>) -> IO(String):
  match r:
    case Done{(c, (out, err))}:
      IO.pure(String, String.trim(out))
    case Fail{e}:
      IO.pure(String, "?")

def runs(+file: String) -> IO(String):
  IO.bind(Result<&1, &1, U32 & String, U32 & (String & String)>, String,
    Process.run("sh", ["-c", "wc -l < " ++ file ++ " | tr -d ' '; rm -f " ++ file], "", 1000, 5000), runs.got)

def main() -> IO(Unit):
  do IO<Unit>:
    a : Result<&1, &1, U32 & String, String> <- Cl.Src.load(plugin("exec_good.tmp", ",\"expirationTimestamp\":\"2099-01-01T00:00:00Z\""))
    b : Result<&1, &1, U32 & String, String> <- Cl.Src.load(plugin("exec_good.tmp", ",\"expirationTimestamp\":\"2099-01-01T00:00:00Z\""))
    c : Result<&1, &1, U32 & String, String> <- Cl.Src.load(plugin("exec_good.tmp", ",\"expirationTimestamp\":\"2099-01-01T00:00:00Z\""))
    n : String <- runs("exec_good.tmp")
    IO.print("good for long: " ++ show(c) ++ ", plugin runs: " ++ n)
    x : Result<&1, &1, U32 & String, String> <- Cl.Src.load(plugin("exec_old.tmp", ",\"expirationTimestamp\":\"2001-01-01T00:00:00Z\""))
    y : Result<&1, &1, U32 & String, String> <- Cl.Src.load(plugin("exec_old.tmp", ",\"expirationTimestamp\":\"2001-01-01T00:00:00Z\""))
    m : String <- runs("exec_old.tmp")
    IO.print("already expired: plugin runs: " ++ m)
