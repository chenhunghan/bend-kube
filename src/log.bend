import Base
import ./json.bend as J
import ./time.bend as T
import ./sys.bend as Y

# Log
# ===
#
# One JSON object per line on stderr, as structured Kubernetes logs are:
# {"ts":"…","level":"info","msg":"…", …fields}.

def Log.line(level: String, msg: String, fields: List<&2, J.KV>, w: T.Wall) -> IO(Unit):
  match w:
    case +x:
      IO.print_err(J.Json.show(J.Json.obj(J.KV{"ts", J.JStr{T.Wall.micro(x)}}
        <> J.KV{"level", J.JStr{level}} <> J.KV{"msg", J.JStr{msg}} <> fields)))

def Log.at(level: String, msg: String, fields: List<&2, J.KV>) -> IO(Unit):
  IO.bind(U32 & (U32 & U32), Unit, Y.Sys.wall(), w => Log.line(level, msg, fields, T.Wall.of(w)))

def Log.info(msg: String, fields: List<&2, J.KV>) -> IO(Unit):
  Log.at("info", msg, fields)

def Log.warn(msg: String, fields: List<&2, J.KV>) -> IO(Unit):
  Log.at("warn", msg, fields)

def Log.error(msg: String, fields: List<&2, J.KV>) -> IO(Unit):
  Log.at("error", msg, fields)

def Log.kv(k: String, v: String) -> J.KV:
  J.KV{k, J.JStr{v}}
