import Base
import ../src/json.bend as J
import ../src/yaml.bend as Y

# YAML to JSON, with bend-kube's own reader: `bend tools/y2j.bend -o y2j`,
# then `./y2j file.yaml > file.json`.

def y2j.read(r: Result<&1, &1, U32 & String, String>) -> IO(Unit):
  match r:
    case Done{s}:
      IO.print(J.Json.show(Y.Yaml.parse(s)))
    case Fail{(c, m)}:
      IO.die(Unit, 1, "y2j: " ++ m)

def y2j.got(p: File & Result<&1, &1, U32 & String, String>) -> IO(Unit):
  match p:
    case (f, r):
      IO.bind(Unit, Unit, File.close(f), u => y2j.read(r))

def y2j.opened(r: Result<&1, &1, U32 & String, File>) -> IO(Unit):
  match r:
    case Done{f}:
      IO.bind(File & Result<&1, &1, U32 & String, String>, Unit, File.read(f, 16777216), y2j.got)
    case Fail{(c, m)}:
      IO.die(Unit, 1, "y2j: " ++ m)

def y2j.args(xs: List<String>) -> IO(Unit):
  match xs:
    case Con{a, Con{path, t}}:
      IO.bind(Result<&1, &1, U32 & String, File>, Unit, File.open(path, "r"), y2j.opened)
    case _:
      IO.die(Unit, 2, "usage: y2j FILE.yaml")

def main() -> IO(Unit):
  IO.bind(List<String>, Unit, IO.args(), y2j.args)
