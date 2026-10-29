import Base

# JSON
# ====
#
# A JSON value is one datatype whose children are direct subterms, so every
# fold over it is structural: an array is a chain of JCons ending in JNil, and
# an object is a chain of JMem ending in JNil. Numbers keep their source text,
# as serde_json's arbitrary_precision does, so int64 and float values
# round-trip exactly.

type Json is Data:
  JNull{}
  JBool{value: Bool}
  JNum{text: String}
  JStr{text: String}
  JArr{items: Json}
  JObj{members: Json}
  JNil{}
  JCons{head: Json, tail: Json}
  JMem{key: String, val: Json, tail: Json}

# Parsing
# -------
#
# A pushdown automaton fed one char at a time: the recursion is on the input
# string, so it terminates by structure, and a watch stream can feed it as
# bytes arrive. Containers under construction sit on the stack, newest first,
# with their members reversed.

# A key and its value, as an object member outside the chain.
type KV is Data:
  KV{key: String, val: Json}

type Frame is Data:
  FArr{items: List<&2, Json>}
  FObj{members: List<&2, KV>, key: String}

# What the automaton expects next.
#   LVal: a value; open says a ']' may close an empty array here
#   LAfter: ',' or a closer, after a value
#   LKey: a member key; open says a '}' may close an empty object
#   LColon: the ':' after a key
#   LStr: inside a string, reversed; esc is 0, 1 after '\', 2..5 in \uXXXX
#   LNum, LLit: inside a number or a literal, reversed
type Lex is Data:
  LVal{open: Bool}
  LAfter{}
  LKey{open: Bool}
  LColon{}
  LStr{buf: String, key: Bool, esc: U32, code: U32}
  LNum{buf: String}
  LLit{buf: String}
  LDone{value: Json}
  LErr{msg: String}

type JState is Data:
  JS{lex: Lex, stack: List<&2, Frame>}

def Json.cons_all(xs: List<&2, Json>) -> Json:
  match xs:
    case Nil{}:
      JNil{}
    case Con{h, t}:
      JCons{h, Json.cons_all(t)}

# Construction
# ------------

def Json.arr(xs: List<&2, Json>) -> Json:
  JArr{Json.cons_all(xs)}

def Json.mem_all(fs: List<&2, KV>) -> Json:
  match fs:
    case Nil{}:
      JNil{}
    case Con{KV{k, v}, t}:
      JMem{k, v, Json.mem_all(t)}

def Json.obj(fs: List<&2, KV>) -> Json:
  JObj{Json.mem_all(fs)}

def Json.str(s: String) -> Json:
  JStr{s}

def Json.u32(n: U32) -> Json:
  JNum{U32.show(n)}

# Access
# ------

# Whether a member chain starts with key.
def Json.head_is(ms: Json, +key: String) -> Bool:
  match ms:
    case JMem{k, v, t}:
      String.eq(k, key)
    case _:
      False{}

# The value under key in an object's member chain; JNull when absent. hit
# says whether the chain's head is key.
def Json.lookup.go(ms: Json, +key: String, hit: Bool) -> Json:
  match ms hit:
    case JMem{k, v, t} True{}:
      v
    case JMem{k, v, +t} False{}:
      Json.lookup.go(t, key, Json.head_is(t, key))
    case _ _:
      JNull{}

def Json.lookup(+ms: Json, +key: String) -> Json:
  Json.lookup.go(ms, key, Json.head_is(ms, key))

# Sets key in a member chain, replacing the first match or appending.
def Json.put_mem.go(ms: Json, +key: String, v: Json, hit: Bool) -> Json:
  match ms hit:
    case JMem{k, x, t} True{}:
      JMem{k, v, t}
    case JMem{k, x, +t} False{}:
      JMem{k, x, Json.put_mem.go(t, key, v, Json.head_is(t, key))}
    case _ _:
      JMem{key, v, JNil{}}

def Json.put_mem(+ms: Json, +key: String, v: Json) -> Json:
  Json.put_mem.go(ms, key, v, Json.head_is(ms, key))

# The value under key in an object's member chain; JNull when absent.
def Json.get(j: Json, +key: String) -> Json:
  match j:
    case JObj{ms}:
      Json.lookup(ms, key)
    case _:
      JNull{}

# Follows a path of keys; JNull as soon as one is missing.
def Json.at.go(path: List<&2, String>, j: Json) -> Json:
  match path:
    case Nil{}:
      j
    case Con{k, t}:
      Json.at.go(t, Json.get(j, k))

def Json.at(j: Json, path: List<&2, String>) -> Json:
  Json.at.go(path, j)

def Json.as_str(j: Json) -> Maybe<&2, String>:
  match j:
    case JStr{s}:
      Some{s}
    case _:
      None{}

def Json.as_u32(j: Json) -> Maybe<&2, U32>:
  match j:
    case JNum{s}:
      U32.read(s)
    case _:
      None{}

def Json.str_or(j: Json, d: String) -> String:
  match j:
    case JStr{s}:
      s
    case _:
      d

def Json.is_null(j: Json) -> Bool:
  match j:
    case JNull{}:
      True{}
    case _:
      False{}

def Json.chain(xs: Json) -> List<&2, Json>:
  match xs:
    case JCons{h, t}:
      h <> Json.chain(t)
    case _:
      Nil{}

# The elements of an array, in order; Nil for anything else.
def Json.items(j: Json) -> List<&2, Json>:
  match j:
    case JArr{xs}:
      Json.chain(xs)
    case _:
      Nil{}

# Sets key in an object's member chain, replacing the first match or
# appending at the end.
def Json.set(j: Json, +key: String, v: Json) -> Json:
  match j:
    case JObj{ms}:
      JObj{Json.put_mem(ms, key, v)}
    case _:
      JObj{JMem{key, v, JNil{}}}

def Json.del_mem.if(k: String, x: Json, t: Json, hit: Bool) -> Json:
  match hit:
    case True{}:
      t
    case False{}:
      JMem{k, x, t}

# Removes every member named key.
def Json.del_mem(ms: Json, +key: String) -> Json:
  match ms:
    case JMem{+k, x, t}:
      Json.del_mem.if(k, x, Json.del_mem(t, key), String.eq(k, key))
    case _:
      JNil{}

def Json.del(j: Json, +key: String) -> Json:
  match j:
    case JObj{ms}:
      JObj{Json.del_mem(ms, key)}
    case x:
      x

def Json.hex.if(+n: U32, lt: Bool) -> Char:
  match lt:
    case True{}:
      Chr{(n + 48 : U32)}
    case False{}:
      Chr{(n + 87 : U32)}

# Printing
# --------

def Json.hex(+n: U32) -> Char:
  Json.hex.if(n, U32.is_lt(n, 10))

def Json.esc_ctl(+x: U32, rest: String, ctl: Bool) -> String:
  match ctl:
    case True{}:
      "\\u00" ++ SCon{Json.hex((x >> 4n : U32)), SCon{Json.hex((x .&. 15 : U32)), rest}}
    case False{}:
      SCon{Chr{x}, rest}

# Escapes one char onto the front of the already-escaped rest.
def Json.esc_chr(c: Char, rest: String) -> String:
  match c:
    case '"':
      SCon{'\\', SCon{'"', rest}}
    case '\\':
      SCon{'\\', SCon{'\\', rest}}
    case '\n':
      SCon{'\\', SCon{'n', rest}}
    case '\r':
      SCon{'\\', SCon{'r', rest}}
    case '\t':
      SCon{'\\', SCon{'t', rest}}
    case Chr{+x}:
      Json.esc_ctl(x, rest, U32.is_lt(x, 32))

def Json.esc(s: String) -> String:
  match s:
    case SNil{}:
      SNil{}
    case SCon{c, t}:
      Json.esc_chr(c, Json.esc(t))

def Json.quote(s: String) -> String:
  "\"" ++ Json.esc(s) ++ "\""

# The compact text of a value. Inside a chain, the first element prints
# bare and the rest follow a comma.
def Json.show(j: Json) -> String:
  match j:
    case JNull{}:
      "null"
    case JBool{True{}}:
      "true"
    case JBool{False{}}:
      "false"
    case JNum{s}:
      s
    case JStr{s}:
      Json.quote(s)
    case JArr{xs}:
      "[" ++ Json.show(xs) ++ "]"
    case JObj{ms}:
      "{" ++ Json.show(ms) ++ "}"
    case JNil{}:
      ""
    case JCons{h, JNil{}}:
      Json.show(h)
    case JCons{h, t}:
      Json.show(h) ++ "," ++ Json.show(t)
    case JMem{k, v, JNil{}}:
      Json.quote(k) ++ ":" ++ Json.show(v)
    case JMem{k, v, t}:
      Json.quote(k) ++ ":" ++ Json.show(v) ++ "," ++ Json.show(t)

def Json.parse.init() -> JState:
  JS{LVal{False{}}, Nil{}}

def Json.rev_pairs(xs: List<&2, KV>, acc: Json) -> Json:
  match xs:
    case Nil{}:
      acc
    case Con{KV{k, v}, t}:
      Json.rev_pairs(t, JMem{k, v, acc})

def Json.rev_items(xs: List<&2, Json>, acc: Json) -> Json:
  match xs:
    case Nil{}:
      acc
    case Con{h, t}:
      Json.rev_items(t, JCons{h, acc})

# Hands a finished value to the innermost open container, or ends the
# document when there is none.
def Json.parse.give(v: Json, stack: List<&2, Frame>) -> JState:
  match stack:
    case Nil{}:
      JS{LDone{v}, Nil{}}
    case Con{FArr{xs}, t}:
      JS{LAfter{}, FArr{v <> xs} <> t}
    case Con{FObj{ms, k}, t}:
      JS{LAfter{}, FObj{KV{k, v} <> ms, ""} <> t}

def Json.parse.err(msg: String) -> JState:
  JS{LErr{msg}, Nil{}}

# The value a literal's reversed chars spell.
def Json.parse.lit(buf: String, stack: List<&2, Frame>) -> JState:
  match buf:
    case "eurt":
      Json.parse.give(JBool{True{}}, stack)
    case "eslaf":
      Json.parse.give(JBool{False{}}, stack)
    case "llun":
      Json.parse.give(JNull{}, stack)
    case _:
      Json.parse.err("bad literal")

def Json.is_num_chr(c: Char) -> Bool:
  match c:
    case '-':
      True{}
    case '+':
      True{}
    case '.':
      True{}
    case 'e':
      True{}
    case 'E':
      True{}
    case Chr{+x}:
      Bool.and(U32.is_ge(x, 48), U32.is_le(x, 57))

def Json.is_alpha_chr(c: Char) -> Bool:
  match c:
    case Chr{+x}:
      Bool.and(U32.is_ge(x, 97), U32.is_le(x, 122))

def Json.is_ws(c: Char) -> Bool:
  match c:
    case ' ':
      True{}
    case '\n':
      True{}
    case '\r':
      True{}
    case '\t':
      True{}
    case _:
      False{}

# Closes the innermost container on ']' or '}'.
def Json.parse.close(c: Char, stack: List<&2, Frame>) -> JState:
  match c stack:
    case ']' Con{FArr{xs}, t}:
      Json.parse.give(JArr{Json.rev_items(xs, JNil{})}, t)
    case '}' Con{FObj{ms, k}, t}:
      Json.parse.give(JObj{Json.rev_pairs(ms, JNil{})}, t)
    case _ _:
      Json.parse.err("mismatched closer")

def Json.parse.after.ws(ws: Bool, stack: List<&2, Frame>) -> JState:
  match ws:
    case True{}:
      JS{LAfter{}, stack}
    case False{}:
      Json.parse.err("expected , or a closer")

def Json.parse.comma(stack: List<&2, Frame>) -> JState:
  match stack:
    case Con{FArr{xs}, t}:
      JS{LVal{False{}}, FArr{xs} <> t}
    case Con{FObj{ms, k}, t}:
      JS{LKey{False{}}, FObj{ms, k} <> t}
    case Nil{}:
      Json.parse.err("comma at top level")

# After a value: a comma reopens the container, a closer ends it.
def Json.parse.after(c: Char, stack: List<&2, Frame>) -> JState:
  match c:
    case ',':
      Json.parse.comma(stack)
    case ']':
      Json.parse.close(']', stack)
    case '}':
      Json.parse.close('}', stack)
    case x:
      Json.parse.after.ws(Json.is_ws(x), stack)

def Json.parse.value.close(open: Bool, stack: List<&2, Frame>) -> JState:
  match open:
    case True{}:
      Json.parse.close(']', stack)
    case False{}:
      Json.parse.err("unexpected ]")

def Json.parse.value.other(x: Char, ws: Bool, num: Bool, alpha: Bool, open: Bool,
  stack: List<&2, Frame>) -> JState:
  match ws num alpha:
    case True{} _ _:
      JS{LVal{open}, stack}
    case False{} True{} _:
      JS{LNum{SCon{x, SNil{}}}, stack}
    case False{} False{} True{}:
      JS{LLit{SCon{x, SNil{}}}, stack}
    case _ _ _:
      Json.parse.err("unexpected char")

# Starts a value with its first char.
def Json.parse.value(c: Char, open: Bool, stack: List<&2, Frame>) -> JState:
  match c:
    case '{':
      JS{LKey{True{}}, FObj{Nil{}, ""} <> stack}
    case '[':
      JS{LVal{True{}}, FArr{Nil{}} <> stack}
    case '"':
      JS{LStr{"", False{}, 0, 0}, stack}
    case ']':
      Json.parse.value.close(open, stack)
    case +x:
      Json.parse.value.other(x, Json.is_ws(x), Json.is_num_chr(x), Json.is_alpha_chr(x), open, stack)

def Json.parse.key.close(open: Bool, stack: List<&2, Frame>) -> JState:
  match open:
    case True{}:
      Json.parse.close('}', stack)
    case False{}:
      Json.parse.err("unexpected }")

def Json.parse.key.ws(ws: Bool, open: Bool, stack: List<&2, Frame>) -> JState:
  match ws:
    case True{}:
      JS{LKey{open}, stack}
    case False{}:
      Json.parse.err("expected a key")

def Json.parse.key(c: Char, open: Bool, stack: List<&2, Frame>) -> JState:
  match c:
    case '"':
      JS{LStr{"", True{}, 0, 0}, stack}
    case '}':
      Json.parse.key.close(open, stack)
    case x:
      Json.parse.key.ws(Json.is_ws(x), open, stack)

def Json.parse.colon.ws(ws: Bool, stack: List<&2, Frame>) -> JState:
  match ws:
    case True{}:
      JS{LColon{}, stack}
    case False{}:
      Json.parse.err("expected :")

def Json.parse.colon(c: Char, stack: List<&2, Frame>) -> JState:
  match c:
    case ':':
      JS{LVal{False{}}, stack}
    case x:
      Json.parse.colon.ws(Json.is_ws(x), stack)

# A finished string: a key waits for its ':', a value is given.
def Json.parse.str_end(s: String, key: Bool, stack: List<&2, Frame>) -> JState:
  match key stack:
    case True{} Con{FObj{ms, k}, t}:
      JS{LColon{}, FObj{ms, s} <> t}
    case True{} _:
      Json.parse.err("key outside an object")
    case False{} st:
      Json.parse.give(JStr{s}, st)

def Json.hex_val.go(+x: U32, digit: Bool, lower: Bool, upper: Bool) -> Maybe<&2, U32>:
  match digit lower upper:
    case True{} _ _:
      Some{(x - 48 : U32)}
    case False{} True{} _:
      Some{(x - 87 : U32)}
    case False{} False{} True{}:
      Some{(x - 55 : U32)}
    case _ _ _:
      None{}

def Json.hex_val(c: Char) -> Maybe<&2, U32>:
  match c:
    case Chr{+x}:
      Json.hex_val.go(x, U32.is_le(x, 57), U32.is_ge(x, 97), U32.is_ge(x, 65))

def Json.parse.in_str.plain(c: Char, buf: String, key: Bool, stack: List<&2, Frame>) -> JState:
  match c:
    case '"':
      Json.parse.str_end(String.reverse(buf), key, stack)
    case '\\':
      JS{LStr{buf, key, 1, 0}, stack}
    case x:
      JS{LStr{SCon{x, buf}, key, 0, 0}, stack}

def Json.parse.in_str.esc(c: Char, buf: String, key: Bool, stack: List<&2, Frame>) -> JState:
  match c:
    case 'n':
      JS{LStr{SCon{'\n', buf}, key, 0, 0}, stack}
    case 't':
      JS{LStr{SCon{'\t', buf}, key, 0, 0}, stack}
    case 'r':
      JS{LStr{SCon{'\r', buf}, key, 0, 0}, stack}
    case 'b':
      JS{LStr{SCon{Chr{8}, buf}, key, 0, 0}, stack}
    case 'f':
      JS{LStr{SCon{Chr{12}, buf}, key, 0, 0}, stack}
    case 'u':
      JS{LStr{buf, key, 2, 0}, stack}
    case x:
      JS{LStr{SCon{x, buf}, key, 0, 0}, stack}

def Json.parse.in_str.hex.fin(+code: U32, buf: String, key: Bool, +esc: U32,
  stack: List<&2, Frame>, last: Bool) -> JState:
  match last:
    case True{}:
      JS{LStr{SCon{Chr{code}, buf}, key, 0, 0}, stack}
    case False{}:
      JS{LStr{buf, key, (esc + 1 : U32), code}, stack}

def Json.parse.in_str.hex.put(+code: U32, buf: String, key: Bool, +esc: U32,
  stack: List<&2, Frame>) -> JState:
  Json.parse.in_str.hex.fin(code, buf, key, esc, stack, U32.is_eq(esc, 5))

# \uXXXX: esc counts 2..5 over the four digits. A UTF-16 surrogate pair
# arrives as two escapes; each half is kept as its own code, which the
# Kubernetes API never emits for text it validates.
def Json.parse.in_str.hex(d: Maybe<&2, U32>, buf: String, key: Bool, +esc: U32, code: U32,
  stack: List<&2, Frame>) -> JState:
  match d:
    case None{}:
      Json.parse.err("bad \\u escape")
    case Some{v}:
      Json.parse.in_str.hex.put(((code << 4n) + v : U32), buf, key, esc, stack)

def Json.parse.in_str.go(c: Char, buf: String, key: Bool, +esc: U32, code: U32,
  stack: List<&2, Frame>, e0: Bool, e1: Bool) -> JState:
  match e0 e1:
    case True{} _:
      Json.parse.in_str.plain(c, buf, key, stack)
    case False{} True{}:
      Json.parse.in_str.esc(c, buf, key, stack)
    case False{} False{}:
      Json.parse.in_str.hex(Json.hex_val(c), buf, key, esc, code, stack)

# One char inside a string.
def Json.parse.in_str(c: Char, buf: String, key: Bool, +esc: U32, code: U32,
  stack: List<&2, Frame>) -> JState:
  Json.parse.in_str.go(c, buf, key, esc, code, stack, U32.is_eq(esc, 0), U32.is_eq(esc, 1))

def Json.parse.done.if(v: Json, ws: Bool) -> JState:
  match ws:
    case True{}:
      JS{LDone{v}, Nil{}}
    case False{}:
      Json.parse.err("trailing data")

def Json.parse.done(c: Char, v: Json) -> JState:
  Json.parse.done.if(v, Json.is_ws(c))

def Json.parse.resume(c: Char, st: JState) -> JState:
  match st:
    case JS{LAfter{}, stack}:
      Json.parse.after(c, stack)
    case JS{LDone{v}, stack}:
      Json.parse.done(c, v)
    case other:
      other

def Json.parse.in_num.if(+c: Char, buf: String, stack: List<&2, Frame>, more: Bool) -> JState:
  match more:
    case True{}:
      JS{LNum{SCon{c, buf}}, stack}
    case False{}:
      Json.parse.resume(c, Json.parse.give(JNum{String.reverse(buf)}, stack))

# A number or literal ends at the first char that cannot extend it; that
# char is then read as if after a value.
def Json.parse.in_num(+c: Char, buf: String, stack: List<&2, Frame>) -> JState:
  Json.parse.in_num.if(c, buf, stack, Json.is_num_chr(c))

def Json.parse.in_lit.if(+c: Char, buf: String, stack: List<&2, Frame>, more: Bool) -> JState:
  match more:
    case True{}:
      JS{LLit{SCon{c, buf}}, stack}
    case False{}:
      Json.parse.resume(c, Json.parse.lit(buf, stack))

def Json.parse.in_lit(+c: Char, buf: String, stack: List<&2, Frame>) -> JState:
  Json.parse.in_lit.if(c, buf, stack, Json.is_alpha_chr(c))

# One step of the automaton.
def Json.parse.step(st: JState, c: Char) -> JState:
  match st:
    case JS{LVal{open}, stack}:
      Json.parse.value(c, open, stack)
    case JS{LAfter{}, stack}:
      Json.parse.after(c, stack)
    case JS{LKey{open}, stack}:
      Json.parse.key(c, open, stack)
    case JS{LColon{}, stack}:
      Json.parse.colon(c, stack)
    case JS{LStr{buf, key, esc, code}, stack}:
      Json.parse.in_str(c, buf, key, esc, code, stack)
    case JS{LNum{buf}, stack}:
      Json.parse.in_num(c, buf, stack)
    case JS{LLit{buf}, stack}:
      Json.parse.in_lit(c, buf, stack)
    case JS{LDone{v}, stack}:
      Json.parse.done(c, v)
    case JS{LErr{m}, stack}:
      JS{LErr{m}, Nil{}}

def Json.parse.feed(s: String, st: JState) -> JState:
  match s:
    case SNil{}:
      st
    case SCon{c, t}:
      Json.parse.feed(t, Json.parse.step(st, c))

def Json.parse.result(st: JState) -> Result<&2, &2, String, Json>:
  match st:
    case JS{LDone{v}, stack}:
      Done{v}
    case JS{LErr{m}, stack}:
      Fail{m}
    case _:
      Fail{"unexpected end of input"}

# Ends the input: a pending number or literal completes, then the document
# must be whole.
def Json.parse.finish(st: JState) -> Result<&2, &2, String, Json>:
  Json.parse.result(Json.parse.step(st, ' '))

def Json.parse(s: String) -> Result<&2, &2, String, Json>:
  Json.parse.finish(Json.parse.feed(s, Json.parse.init()))
