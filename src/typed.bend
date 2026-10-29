import Base
import ./json.bend as J

# Typed
# =====
#
# What generated types (tools/gen.py) decode and encode with: typed views
# of JSON objects, as k8s-openapi and kube-derive give kube-rs. A decoder
# answers the value or an error naming the field's path ("spec.ports[2]
# .port: expected an integer"); an encoder builds the JSON back, leaving
# out absent optional fields and empty lists, as omitempty does.

def Ty.Res(-A: Data) -> Type:
  Result<&2, &2, String, A>

def Ty.at.go(path: String, key: String, root: Bool) -> String:
  match root:
    case True{}:
      key
    case False{}:
      path ++ "." ++ key

def Ty.at(+path: String, key: String) -> String:
  Ty.at.go(path, key, String.is_empty(path))

# Scalars
# -------

def Ty.str(j: J.Json, path: String) -> Result<&2, &2, String, String>:
  match j:
    case J.JStr{s}:
      Done{s}
    case _:
      Fail{path ++ ": expected a string"}

def Ty.bool(j: J.Json, path: String) -> Result<&2, &2, String, Bool>:
  match j:
    case J.JBool{b}:
      Done{b}
    case _:
      Fail{path ++ ": expected a boolean"}

def Ty.u32.read(m: Maybe<&2, U32>, path: String) -> Result<&2, &2, String, U32>:
  match m:
    case Some{n}:
      Done{n}
    case None{}:
      Fail{path ++ ": expected an integer from 0 to 4294967295"}

def Ty.u32(j: J.Json, path: String) -> Result<&2, &2, String, U32>:
  match j:
    case J.JNum{t}:
      Ty.u32.read(U32.read(t), path)
    case _:
      Fail{path ++ ": expected an integer"}

# A number kept as its text (int64, floats): lossless.
def Ty.num(j: J.Json, path: String) -> Result<&2, &2, String, String>:
  match j:
    case J.JNum{t}:
      Done{t}
    case _:
      Fail{path ++ ": expected a number"}

# Anything, untyped (maps, preserved unknown fields).
def Ty.json(j: J.Json, path: String) -> Result<&2, &2, String, J.Json>:
  Done{j}

def Ty.from_str(s: String) -> J.Json:
  J.JStr{s}

def Ty.from_bool(b: Bool) -> J.Json:
  J.JBool{b}

def Ty.from_u32(n: U32) -> J.Json:
  J.JNum{U32.show(n)}

def Ty.from_num(t: String) -> J.Json:
  J.JNum{t}

def Ty.from_json(j: J.Json) -> J.Json:
  j

# Fields
# ------

def Ty.req.go(~A: Data, ~dec: J.Json -> String -> Result<&2, &2, String, A>, +j: J.Json,
  +path: String, missing: Bool) -> Result<&2, &2, String, A>:
  match missing:
    case True{}:
      Fail{path ++ ": required"}
    case False{}:
      dec(j, path)

# A required field.
def Ty.req(~A: Data, ~dec: J.Json -> String -> Result<&2, &2, String, A>, +j: J.Json, +key: String,
  +path: String) -> Result<&2, &2, String, A>:
  Ty.req.go(~A, ~dec, J.Json.get(j, key), Ty.at(path, key), J.Json.is_null(J.Json.get(j, key)))

def Ty.opt.go(~A: Data, ~dec: J.Json -> String -> Result<&2, &2, String, A>, +j: J.Json,
  +path: String, missing: Bool) -> Result<&2, &2, String, Maybe<&2, A>>:
  match missing:
    case True{}:
      Done{None{}}
    case False{}:
      Result.map(&2, &2, String, A, Maybe<&2, A>, x => Some{x}, dec(j, path))

# An optional field: None when absent or null.
def Ty.opt(~A: Data, ~dec: J.Json -> String -> Result<&2, &2, String, A>, +j: J.Json, +key: String,
  +path: String) -> Result<&2, &2, String, Maybe<&2, A>>:
  Ty.opt.go(~A, ~dec, J.Json.get(j, key), Ty.at(path, key), J.Json.is_null(J.Json.get(j, key)))

def Ty.list.go(~A: Data, ~dec: J.Json -> String -> Result<&2, &2, String, A>,
  xs: List<&2, J.Json>, +path: String, +i: U32) -> Result<&2, &2, String, List<&2, A>>:
  match xs:
    case Nil{}:
      Done{Nil{}}
    case Con{x, t}:
      do Result<&2, &2, String, List<&2, A>>:
        h : A <- dec(x, path ++ "[" ++ U32.show(i) ++ "]")
        r : List<&2, A> <- Ty.list.go(~A, ~dec, t, path, (i + 1 : U32))
        return h <> r

def Ty.list.of(~A: Data, ~dec: J.Json -> String -> Result<&2, &2, String, A>, j: J.Json,
  +path: String) -> Result<&2, &2, String, List<&2, A>>:
  match j:
    case J.JNull{}:
      Done{Nil{}}
    case J.JArr{xs}:
      Ty.list.go(~A, ~dec, J.Json.chain(xs), path, 0)
    case _:
      Fail{path ++ ": expected a list"}

# A list field: empty when absent.
def Ty.list(~A: Data, ~dec: J.Json -> String -> Result<&2, &2, String, A>, +j: J.Json, +key: String,
  +path: String) -> Result<&2, &2, String, List<&2, A>>:
  Ty.list.of(~A, ~dec, J.Json.get(j, key), Ty.at(path, key))

# Building
# --------

def Ty.put(~A: Data, ~enc: A -> J.Json, key: String, x: A) -> Maybe<&2, J.KV>:
  Some{J.KV{key, enc(x)}}

def Ty.put_opt(~A: Data, ~enc: A -> J.Json, key: String, m: Maybe<&2, A>) -> Maybe<&2, J.KV>:
  match m:
    case Some{x}:
      Some{J.KV{key, enc(x)}}
    case None{}:
      None{}

def Ty.encs(~A: Data, ~enc: A -> J.Json, xs: List<&2, A>) -> List<&2, J.Json>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{x, t}:
      enc(x) <> Ty.encs(~A, ~enc, t)

def Ty.put_list(~A: Data, ~enc: A -> J.Json, key: String, xs: List<&2, A>) -> Maybe<&2, J.KV>:
  match xs:
    case Nil{}:
      None{}
    case +ys:
      Some{J.KV{key, J.Json.arr(Ty.encs(~A, ~enc, ys))}}

def Ty.fields(ms: List<&2, Maybe<&2, J.KV>>) -> List<&2, J.KV>:
  match ms:
    case Nil{}:
      Nil{}
    case Con{Some{kv}, t}:
      kv <> Ty.fields(t)
    case Con{None{}, t}:
      Ty.fields(t)

# An object from its present fields.
def Ty.obj(ms: List<&2, Maybe<&2, J.KV>>) -> J.Json:
  J.Json.obj(Ty.fields(ms))
