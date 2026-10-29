import Base
import ./json.bend as J

# YAML
# ====
#
# The block YAML that kubeconfigs are written in, read into JSON, so a
# kubeconfig needs no kubectl to load. Covered: block mappings and
# sequences (a sequence may sit at its parent key's indentation, as
# kubectl writes it), "- key: value" items, plain, 'single' and "double"
# quoted scalars, null/~/true/false, comments, "---", and flow values that
# are JSON ({}, [], ["a", "b"]). Not covered: anchors, tags, block
# scalars (| >), multi-document streams, and non-JSON flow collections.
#
# A pushdown automaton over lines: open containers sit on a stack, each
# with the indentation it was opened at, and a line first closes every
# container deeper than itself.

type Line is Data:
  Line{indent: U32, text: String}

# An open container: a mapping (members reversed, and the key whose
# value is still to come) or a sequence (items reversed, and, after a bare
# "- ", the anchor of the item whose block is still to come).
type YFrame is Data:
  YMap{indent: U32, members: List<&2, J.KV>, pend: Maybe<&2, String>}
  YSeq{indent: U32, items: List<&2, J.Json>, pend: Maybe<&2, String>}
  YRoot{value: J.Json}

# mode: 0 between tokens, 1 in "..", 2 in '..', 3 in a plain scalar;
# buf: the plain scalar so far (reversed); out: JSON text (reversed).
type Flow is Data:
  Flow{mode: U32, buf: String, out: String, esc: Bool}

# A block scalar being read: its key line's indent and text before the
# indicator, literal (|) or folded (>), chomping (0 clip, 1 strip -, 2
# keep +), the content's indent (0 until its first line), and its lines
# so far (reversed, the content indent removed).
type Blk is Data:
  Blk{ki: U32, prefix: String, folded: Bool, chomp: U32, bi: U32, acc: List<&2, String>}

type BH is Data:
  BH{prefix: String, folded: Bool, chomp: U32}

# The line fold: lines out (reversed), and the block scalar, if inside one.
type LS is Data:
  LS{out: List<&2, Line>, blk: Maybe<&2, Blk>}

# A value with its anchor (&name) split off.
type AV is Data:
  AV{anchor: String, rest: String}

type YR is Data:
  YR{json: J.Json, anchors: Map<&2, J.Json>}

# Lines
# -----

def Yaml.indent(s: String, +n: U32) -> U32:
  match s:
    case SCon{' ', t}:
      Yaml.indent(t, (n + 1 : U32))
    case _:
      n

def Yaml.quote.go(+q: U32, +k: U32, none: Bool, same: Bool) -> U32:
  match none same:
    case True{} _:
      k
    case False{} True{}:
      0
    case _ _:
      q

# Entering or leaving a quote of kind k (1 single, 2 double).
def Yaml.quote(+q: U32, +k: U32) -> U32:
  Yaml.quote.go(q, k, U32.is_eq(q, 0), U32.is_eq(q, k))

# The quote state after char c.
def Yaml.nq(+c: Char, +q: U32) -> U32:
  match c:
    case '"':
      Yaml.quote(q, 2)
    case '\'':
      Yaml.quote(q, 1)
    case _:
      q

# Whether a comment starts at the head of s: a '#' after a space, outside
# quotes.
def Yaml.cut_at(s: String, +q: U32, prev: Bool) -> Bool:
  match s:
    case SCon{'#', t}:
      Bool.and(prev, U32.is_eq(q, 0))
    case _:
      False{}

# Drops a comment, to the end of the line.
def Yaml.uncomment(s: String, +q: U32, cut: Bool) -> String:
  match s cut:
    case _ True{}:
      SNil{}
    case SNil{} False{}:
      SNil{}
    case SCon{+c, +t} False{}:
      SCon{c, Yaml.uncomment(t, Yaml.nq(c, q), Yaml.cut_at(t, Yaml.nq(c, q), Char.is_space(c)))}

def Yaml.keep(+t: String) -> Bool:
  Bool.and(Bool.not(String.is_empty(t)), Bool.not(String.eq(t, "---")))

def Yaml.lines.put.go(+i: U32, text: String, rest: List<&2, Line>, keep: Bool) -> List<&2, Line>:
  match keep:
    case True{}:
      Line{i, text} <> rest
    case False{}:
      rest

def Yaml.lines.put(+i: U32, +text: String, rest: List<&2, Line>) -> List<&2, Line>:
  Yaml.lines.put.go(i, text, rest, Yaml.keep(text))

# A block scalar's header ("key: |", "- >-", ...): the text before the
# indicator, its style and chomping.
def Yaml.head.go(r: String) -> Maybe<&2, BH>:
  match r:
    case SCon{'|', SCon{' ', t}}:
      Some{BH{String.reverse(t) ++ " ", False{}, 0}}
    case SCon{'>', SCon{' ', t}}:
      Some{BH{String.reverse(t) ++ " ", True{}, 0}}
    case SCon{'-', SCon{'|', SCon{' ', t}}}:
      Some{BH{String.reverse(t) ++ " ", False{}, 1}}
    case SCon{'-', SCon{'>', SCon{' ', t}}}:
      Some{BH{String.reverse(t) ++ " ", True{}, 1}}
    case SCon{'+', SCon{'|', SCon{' ', t}}}:
      Some{BH{String.reverse(t) ++ " ", False{}, 2}}
    case SCon{'+', SCon{'>', SCon{' ', t}}}:
      Some{BH{String.reverse(t) ++ " ", True{}, 2}}
    case _:
      None{}

def Yaml.head(t: String) -> Maybe<&2, BH>:
  Yaml.head.go(String.reverse(t))

def Yaml.clean(+l: String) -> String:
  String.trim(Yaml.uncomment(l, 0, Yaml.cut_at(l, 0, True{})))

# Trailing blank lines (of a reversed list): how many, and the rest.
def Yaml.blanks(xs: List<&2, String>, +n: U32) -> U32:
  match xs:
    case Con{SNil{}, t}:
      Yaml.blanks(t, (n + 1 : U32))
    case _:
      n

def Yaml.unblank(xs: List<&2, String>) -> List<&2, String>:
  match xs:
    case Con{SNil{}, t}:
      Yaml.unblank(t)
    case x:
      x

def Yaml.fold.sep(prev: Bool) -> String:
  match prev:
    case True{}:
      " "
    case False{}:
      ""

# Folded lines: a line break between two text lines becomes a space; blank
# lines stay line breaks.
def Yaml.fold(xs: List<&2, String>, prev: Bool) -> String:
  match xs:
    case Nil{}:
      ""
    case Con{SNil{}, t}:
      "\n" ++ Yaml.fold(t, False{})
    case Con{l, t}:
      Yaml.fold.sep(prev) ++ l ++ Yaml.fold(t, True{})

def Yaml.block.body(lines: List<&2, String>, folded: Bool) -> String:
  match folded:
    case True{}:
      Yaml.fold(lines, False{})
    case False{}:
      String.join(lines, "\n")

def Yaml.block.tail.go(+chomp: U32, +n: U32, strip: Bool, keep: Bool) -> String:
  match strip keep:
    case True{} _:
      ""
    case False{} True{}:
      String.repeat("\n", U32.to_nat((n + 1 : U32)))
    case _ _:
      "\n"

def Yaml.block.tail(+chomp: U32, +n: U32, empty: Bool) -> String:
  match empty:
    case True{}:
      ""
    case False{}:
      Yaml.block.tail.go(chomp, n, U32.is_eq(chomp, 1), U32.is_eq(chomp, 2))

# A finished block scalar, as the one line "prefix <JSON string>".
def Yaml.block.line(b: Blk) -> Line:
  match b:
    case Blk{ki, prefix, folded, +chomp, bi, +acc}:
      Line{ki, prefix ++ J.Json.show(J.JStr{
        Yaml.block.body(List.reverse(&2, String, Yaml.unblank(acc)), folded)
          ++ Yaml.block.tail(chomp, Yaml.blanks(acc, 0), List.is_empty(&2, String, Yaml.unblank(acc)))})}

def Yaml.normal.go(out: List<&2, Line>, +i: U32, +t: String, h: Maybe<&2, BH>) -> LS:
  match h:
    case Some{BH{p, f, c}}:
      LS{out, Some{Blk{i, p, f, c, 0, Nil{}}}}
    case None{}:
      LS{Yaml.lines.put(i, t, out), None{}}

# An ordinary line: kept if meaningful, or the start of a block scalar.
def Yaml.normal(out: List<&2, Line>, +raw: String) -> LS:
  Yaml.normal.go(out, Yaml.indent(raw, 0), Yaml.clean(raw), Yaml.head(Yaml.clean(raw)))

def Yaml.in_block.go(out: List<&2, Line>, b: Blk, +raw: String, blank: Bool, deeper: Bool,
  first: Bool) -> LS:
  match b blank deeper first:
    case Blk{ki, p, f, c, bi, acc} True{} _ _:
      LS{out, Some{Blk{ki, p, f, c, bi, SNil{} <> acc}}}
    case Blk{ki, p, f, c, bi, acc} False{} True{} True{}:
      LS{out, Some{Blk{ki, p, f, c, Yaml.indent(raw, 0), String.drop(raw, U32.to_nat(Yaml.indent(raw, 0))) <> acc}}}
    case Blk{ki, p, f, c, +bi, acc} False{} True{} False{}:
      LS{out, Some{Blk{ki, p, f, c, bi, String.drop(raw, U32.to_nat(bi)) <> acc}}}
    case +x False{} False{} _:
      Yaml.normal(Yaml.block.line(x) <> out, raw)

# A raw line inside a block scalar: content while deeper than the key (or
# blank), else the block ends and the line is read as ordinary.
def Yaml.in_block(out: List<&2, Line>, b: Blk, +raw: String) -> LS:
  match b:
    case Blk{+ki, p, f, c, +bi, acc}:
      Yaml.in_block.go(out, Blk{ki, p, f, c, bi, acc}, raw, String.is_empty(String.trim(raw)),
        U32.is_gt(Yaml.indent(raw, 0), ki), U32.is_eq(bi, 0))

def Yaml.step_line(st: LS, +raw: String) -> LS:
  match st:
    case LS{out, None{}}:
      Yaml.normal(out, raw)
    case LS{out, Some{b}}:
      Yaml.in_block(out, b, raw)

def Yaml.lines.fold(ls: List<&2, String>, st: LS) -> LS:
  match ls:
    case Nil{}:
      st
    case Con{l, t}:
      Yaml.lines.fold(t, Yaml.step_line(st, l))

def Yaml.lines.fin(st: LS) -> List<&2, Line>:
  match st:
    case LS{out, None{}}:
      List.reverse(&2, Line, out)
    case LS{out, Some{b}}:
      List.reverse(&2, Line, Yaml.block.line(b) <> out)

# The meaningful lines: indentation and text, comments and blanks gone,
# block scalars (| and >) folded into one line each.
def Yaml.lines(s: String) -> List<&2, Line>:
  Yaml.lines.fin(Yaml.lines.fold(String.lines(s), LS{Nil{}, None{}}))

# Scalars
# -------

def Yaml.unsingle(s: String) -> String:
  match s:
    case SNil{}:
      SNil{}
    case SCon{'\'', SCon{'\'', t}}:
      SCon{'\'', Yaml.unsingle(t)}
    case SCon{c, t}:
      SCon{c, Yaml.unsingle(t)}

def Yaml.strip_ends(+s: String) -> String:
  String.take(String.drop(s, 1n), Nat.sub(String.length(s), 2n))

def Yaml.json_or(r: Result<&2, &2, String, J.Json>, s: String) -> J.Json:
  match r:
    case Done{j}:
      j
    case Fail{e}:
      J.JStr{s}

# Numbers, as YAML 1.2's core schema reads them:
# [-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?, read a character
# at a time. The digits so far are kept reversed.
type Num is Data:
  NStart{}
  NSign{neg: Bool}
  NInt{neg: Bool, int: List<&2, Char>}
  NDot0{neg: Bool}
  NFrac{neg: Bool, int: List<&2, Char>, frac: List<&2, Char>}
  NExp0{neg: Bool, int: List<&2, Char>, frac: List<&2, Char>, exp: List<&2, Char>}
  NExp1{neg: Bool, int: List<&2, Char>, frac: List<&2, Char>, exp: List<&2, Char>}
  NExpD{neg: Bool, int: List<&2, Char>, frac: List<&2, Char>, exp: List<&2, Char>}
  NBad{}

def Num.step(st: Num, +c: Char, dig: Bool, dot: Bool, ex: Bool, sg: Bool) -> Num:
  match st dig dot ex sg:
    case NStart{} True{} d e s:
      NInt{False{}, [c]}
    case NStart{} False{} True{} e s:
      NDot0{False{}}
    case NStart{} False{} False{} e True{}:
      NSign{Char.is_eq(c, '-')}
    case NStart{} False{} False{} e False{}:
      NBad{}
    case NSign{n} True{} d e s:
      NInt{n, [c]}
    case NSign{n} False{} True{} e s:
      NDot0{n}
    case NSign{n} False{} False{} e s:
      NBad{}
    case NInt{n, i} True{} d e s:
      NInt{n, Con{c, i}}
    case NInt{n, i} False{} True{} e s:
      NFrac{n, i, Nil{}}
    case NInt{n, i} False{} False{} True{} s:
      NExp0{n, i, Nil{}, [c]}
    case NInt{n, i} False{} False{} False{} s:
      NBad{}
    case NDot0{n} True{} d e s:
      NFrac{n, Nil{}, [c]}
    case NDot0{n} False{} d e s:
      NBad{}
    case NFrac{n, i, f} True{} d e s:
      NFrac{n, i, Con{c, f}}
    case NFrac{n, i, f} False{} d True{} s:
      NExp0{n, i, f, [c]}
    case NFrac{n, i, f} False{} d False{} s:
      NBad{}
    case NExp0{n, i, f, x} True{} d e s:
      NExpD{n, i, f, Con{c, x}}
    case NExp0{n, i, f, x} False{} d e True{}:
      NExp1{n, i, f, Con{c, x}}
    case NExp0{n, i, f, x} False{} d e False{}:
      NBad{}
    case NExp1{n, i, f, x} True{} d e s:
      NExpD{n, i, f, Con{c, x}}
    case NExp1{n, i, f, x} False{} d e s:
      NBad{}
    case NExpD{n, i, f, x} True{} d e s:
      NExpD{n, i, f, Con{c, x}}
    case NExpD{n, i, f, x} False{} d e s:
      NBad{}
    case NBad{} g d e s:
      NBad{}

def Num.go(s: String, st: Num) -> Num:
  match s:
    case SNil{}:
      st
    case SCon{+c, t}:
      Num.go(t, Num.step(st, c, Char.is_digit(c), Char.is_eq(c, '.'),
        Bool.or(Char.is_eq(c, 'e'), Char.is_eq(c, 'E')),
        Bool.or(Char.is_eq(c, '-'), Char.is_eq(c, '+'))))

def Num.sign(neg: Bool) -> String:
  match neg:
    case True{}:
      "-"
    case False{}:
      ""

# The integer digits without leading zeros, "0" for none.
def Num.int(cs: List<&2, Char>) -> String:
  match cs:
    case Nil{}:
      "0"
    case Con{'0', t}:
      Num.int(t)
    case Con{c, t}:
      String.from_list(Con{c, t})

def Num.frac(f: List<&2, Char>) -> String:
  match f:
    case Nil{}:
      ""
    case Con{c, t}:
      "." ++ String.from_list(List.reverse(&2, Char, Con{c, t}))

# The number as JSON writes it, or None when s is not one.
def Num.fin(st: Num) -> Maybe<&2, String>:
  match st:
    case NInt{n, i}:
      Some{Num.sign(n) ++ Num.int(List.reverse(&2, Char, i))}
    case NFrac{n, i, f}:
      Some{Num.sign(n) ++ Num.int(List.reverse(&2, Char, i)) ++ Num.frac(f)}
    case NExpD{n, i, f, x}:
      Some{Num.sign(n) ++ Num.int(List.reverse(&2, Char, i)) ++ Num.frac(f) ++
        String.from_list(List.reverse(&2, Char, x))}
    case _:
      None{}

def Num.parse(s: String) -> Maybe<&2, String>:
  Num.fin(Num.go(s, NStart{}))

def Yaml.plain.num(x: String, n: Maybe<&2, String>) -> J.Json:
  match n:
    case Some{t}:
      J.JNum{t}
    case None{}:
      J.JStr{x}

# A plain scalar: null, ~, true, false, or a string.
def Yaml.plain(s: String) -> J.Json:
  match s:
    case "null":
      J.JNull{}
    case "~":
      J.JNull{}
    case "true":
      J.JBool{True{}}
    case "false":
      J.JBool{False{}}
    case +x:
      Yaml.plain.num(x, Num.parse(x))

def Flow.peek(s: String) -> Char:
  match s:
    case SCon{c, t}:
      c
    case SNil{}:
      ' '

# "key: rest" or "key:": the key (unquoted) and the rest, if this is a
# mapping entry.
type KR is Data:
  KR{key: String, rest: String}

def Flow.punct(+c: Char) -> Bool:
  match c:
    case '{':
      True{}
    case '}':
      True{}
    case '[':
      True{}
    case ']':
      True{}
    case ',':
      True{}
    case ':':
      True{}
    case _:
      False{}

def Flow.out0.go(+c: Char, out: String, punct: Bool, space: Bool) -> Flow:
  match punct space:
    case True{} _:
      Flow{0, "", SCon{c, out}, False{}}
    case False{} True{}:
      Flow{0, "", out, False{}}
    case False{} False{}:
      Flow{3, SCon{c, SNil{}}, out, False{}}

def Flow.out0(+c: Char, out: String) -> Flow:
  match c:
    case '"':
      Flow{1, "", SCon{'"', out}, False{}}
    case '\'':
      Flow{2, "", SCon{'"', out}, False{}}
    case x:
      Flow.out0.go(x, out, Flow.punct(x), Char.is_space(x))

def Flow.dq(esc: Bool, +c: Char, out: String) -> Flow:
  match esc c:
    case True{} x:
      Flow{1, "", SCon{x, out}, False{}}
    case False{} '\\':
      Flow{1, "", SCon{'\\', out}, True{}}
    case False{} '"':
      Flow{0, "", SCon{'"', out}, False{}}
    case False{} x:
      Flow{1, "", SCon{x, out}, False{}}

def Flow.sq.quote(out: String, doubled: Bool) -> Flow:
  match doubled:
    case True{}:
      Flow{2, "", out, True{}}
    case False{}:
      Flow{0, "", SCon{'"', out}, False{}}

def Flow.sq(esc: Bool, +c: Char, +nxt: Char, out: String) -> Flow:
  match esc c:
    case True{} _:
      Flow{2, "", SCon{'\'', out}, False{}}
    case False{} '\'':
      Flow.sq.quote(out, Char.is_eq(nxt, '\''))
    case False{} '"':
      Flow{2, "", SCon{'"', SCon{'\\', out}}, False{}}
    case False{} '\\':
      Flow{2, "", SCon{'\\', SCon{'\\', out}}, False{}}
    case False{} x:
      Flow{2, "", SCon{x, out}, False{}}

def Flow.closer(+c: Char) -> Bool:
  match c:
    case '}':
      True{}
    case ']':
      True{}
    case ',':
      True{}
    case _:
      False{}

# A plain scalar ends at a closer, or at ':' before a space or a closer.
def Flow.ends(+c: Char, +nxt: Char) -> Bool:
  Bool.or(Flow.closer(c), Bool.and(Char.is_eq(c, ':'), Bool.or(Char.is_space(nxt), Flow.closer(nxt))))

def Flow.emit(buf: String, out: String) -> String:
  String.reverse(J.Json.show(Yaml.plain(String.trim(String.reverse(buf))))) ++ out

def Flow.plain.go(+c: Char, buf: String, out: String, ends: Bool) -> Flow:
  match ends:
    case True{}:
      Flow{0, "", SCon{c, Flow.emit(buf, out)}, False{}}
    case False{}:
      Flow{3, SCon{c, buf}, out, False{}}

def Flow.plain(+c: Char, +nxt: Char, buf: String, out: String) -> Flow:
  Flow.plain.go(c, buf, out, Flow.ends(c, nxt))

def Flow.step.go(+m: U32, b: String, o: String, e: Bool, +c: Char, +nxt: Char, m0: Bool, m1: Bool,
  m2: Bool) -> Flow:
  match m0 m1 m2:
    case True{} _ _:
      Flow.out0(c, o)
    case False{} True{} _:
      Flow.dq(e, c, o)
    case False{} False{} True{}:
      Flow.sq(e, c, nxt, o)
    case _ _ _:
      Flow.plain(c, nxt, b, o)

def Flow.step(st: Flow, +c: Char, +nxt: Char) -> Flow:
  match st:
    case Flow{+m, b, o, e}:
      Flow.step.go(m, b, o, e, c, nxt, U32.is_eq(m, 0), U32.is_eq(m, 1), U32.is_eq(m, 2))

def Flow.go(s: String, st: Flow) -> Flow:
  match s:
    case SNil{}:
      st
    case SCon{+c, +t}:
      Flow.go(t, Flow.step(st, c, Flow.peek(t)))

def Flow.fin.go(b: String, o: String, plain: Bool) -> String:
  match plain:
    case True{}:
      Flow.emit(b, o)
    case False{}:
      o

def Flow.fin(st: Flow) -> String:
  match st:
    case Flow{+m, b, o, e}:
      String.reverse(Flow.fin.go(b, o, U32.is_eq(m, 3)))

# A flow value's JSON text.
def Yaml.flow(s: String) -> String:
  Flow.fin(Flow.go(s, Flow{0, "", "", False{}}))

# Anchors, aliases, tags
# ----------------------
#
# The line parser leaves markers: an anchored value is the object
# {"\u0000&name": value}, an alias the string "\u0000*name", and a key
# whose anchored value is still to come is "\u0001name\u0001key". After
# parsing, Yaml.resolve walks the document in order, recording anchors and
# replacing aliases (an alias names an earlier anchor), and applies merge
# keys (<<: *base), whose members fill in keys the mapping lacks.

def Yaml.split_word.go(s: String, acc: String) -> AV:
  match s:
    case SNil{}:
      AV{String.reverse(acc), ""}
    case SCon{' ', t}:
      AV{String.reverse(acc), String.trim(t)}
    case SCon{c, t}:
      Yaml.split_word.go(t, SCon{c, acc})

# The first word and the rest.
def Yaml.split_word(s: String) -> AV:
  Yaml.split_word.go(s, "")

def Yaml.scalar.untagged(+s: String) -> J.Json:
  match s:
    case SCon{'"', t}:
      Yaml.json_or(J.Json.parse(s), s)
    case SCon{'\'', t}:
      J.JStr{Yaml.unsingle(Yaml.strip_ends(s))}
    case x:
      Yaml.plain(x)

# A tagged scalar: !!str keeps the text a string; other tags are dropped.
def Yaml.tagged(av: AV) -> J.Json:
  match av:
    case AV{"!str", r}:
      J.JStr{r}
    case AV{t, +r}:
      Yaml.scalar.untagged(r)

# A scalar or flow value; an alias (*name) or a tag (!!str x) first.
def Yaml.scalar(+s: String) -> J.Json:
  match s:
    case SCon{'*', t}:
      J.JStr{SCon{Chr{0}, SCon{'*', t}}}
    case SCon{'!', t}:
      Yaml.tagged(Yaml.split_word(t))
    case SCon{'"', t}:
      Yaml.json_or(J.Json.parse(s), s)
    case SCon{'\'', t}:
      J.JStr{Yaml.unsingle(Yaml.strip_ends(s))}
    case SCon{'[', t}:
      Yaml.json_or(J.Json.parse(Yaml.flow(s)), s)
    case SCon{'{', t}:
      Yaml.json_or(J.Json.parse(Yaml.flow(s)), s)
    case x:
      Yaml.plain(x)

def Yaml.key.go(s: String, acc: String) -> Maybe<&2, KR>:
  match s:
    case SNil{}:
      None{}
    case SCon{':', SNil{}}:
      Some{KR{String.reverse(acc), ""}}
    case SCon{':', SCon{' ', t}}:
      Some{KR{String.reverse(acc), String.trim(t)}}
    case SCon{c, t}:
      Yaml.key.go(t, SCon{c, acc})

def Yaml.unquote_key(+k: String) -> String:
  match k:
    case SCon{'"', t}:
      Yaml.strip_ends(k)
    case SCon{'\'', t}:
      Yaml.strip_ends(k)
    case x:
      x

def Yaml.key.fin(m: Maybe<&2, KR>) -> Maybe<&2, KR>:
  match m:
    case Some{KR{k, r}}:
      Some{KR{Yaml.unquote_key(String.trim(k)), r}}
    case None{}:
      None{}

def Yaml.key(+s: String) -> Maybe<&2, KR>:
  match s:
    case SCon{'"', t}:
      Yaml.key.fin(Yaml.key.go(s, ""))
    case SCon{'[', t}:
      None{}
    case SCon{'{', t}:
      None{}
    case x:
      Yaml.key.fin(Yaml.key.go(x, ""))

# The stack
# ---------

def Yaml.rev_kv(xs: List<&2, J.KV>, acc: J.Json) -> J.Json:
  match xs:
    case Nil{}:
      acc
    case Con{J.KV{k, v}, t}:
      Yaml.rev_kv(t, J.JMem{k, v, acc})

def Yaml.rev_items(xs: List<&2, J.Json>, acc: J.Json) -> J.Json:
  match xs:
    case Nil{}:
      acc
    case Con{h, t}:
      Yaml.rev_items(t, J.JCons{h, acc})

def Yaml.pend_null(p: Maybe<&2, String>, ms: List<&2, J.KV>) -> List<&2, J.KV>:
  match p:
    case Some{k}:
      J.KV{k, J.JNull{}} <> ms
    case None{}:
      ms

def Yaml.wrap.go(a: String, v: J.Json, none: Bool) -> J.Json:
  match none:
    case True{}:
      v
    case False{}:
      J.JObj{J.JMem{SCon{Chr{0}, SCon{'&', a}}, v, J.JNil{}}}

def Yaml.wrap(+a: String, v: J.Json) -> J.Json:
  Yaml.wrap.go(a, v, String.is_empty(a))

# A finished container's value.
def Yaml.value(f: YFrame) -> J.Json:
  match f:
    case YMap{i, ms, p}:
      J.JObj{Yaml.rev_kv(Yaml.pend_null(p, ms), J.JNil{})}
    case YSeq{i, xs, None{}}:
      J.JArr{Yaml.rev_items(xs, J.JNil{})}
    case YSeq{i, xs, Some{a}}:
      J.JArr{Yaml.rev_items(Yaml.wrap(a, J.JNull{}) <> xs, J.JNil{})}
    case YRoot{v}:
      v

# Whether s starts with the control char of code n.
def Yaml.ctl(s: String, +n: U32) -> Bool:
  match s:
    case SCon{Chr{+c}, t}:
      U32.is_eq(c, n)
    case _:
      False{}

def Yaml.member.split(parts: List<&2, String>, v: J.Json) -> J.KV:
  match parts:
    case Con{a, Con{k, rest}}:
      J.KV{String.join(k <> rest, SCon{Chr{1}, SNil{}}), Yaml.wrap(a, v)}
    case _:
      J.KV{"", v}

def Yaml.member.go(k: String, v: J.Json, marked: Bool) -> J.KV:
  match marked:
    case True{}:
      Yaml.member.split(String.split(String.drop(k, 1n), Chr{1}), v)
    case False{}:
      J.KV{k, v}

# A pending key's member, its anchor (if marked) wrapped around v.
def Yaml.member(+k: String, v: J.Json) -> J.KV:
  Yaml.member.go(k, v, Yaml.ctl(k, 1))

# Hands v to the container on top: a mapping's pending key, a sequence's
# next item, or the document itself.
def Yaml.give(v: J.Json, st: List<&2, YFrame>) -> List<&2, YFrame>:
  match st:
    case Con{YMap{i, ms, Some{k}}, t}:
      YMap{i, Yaml.member(k, v) <> ms, None{}} <> t
    case Con{YSeq{i, xs, None{}}, t}:
      YSeq{i, v <> xs, None{}} <> t
    case Con{YSeq{i, xs, Some{a}}, t}:
      YSeq{i, Yaml.wrap(a, v) <> xs, None{}} <> t
    case Con{YMap{i, ms, None{}}, t}:
      YMap{i, ms, None{}} <> t
    case Con{YRoot{x}, t}:
      YRoot{v} <> t
    case Nil{}:
      [YRoot{v}]

def Yaml.top_indent(st: List<&2, YFrame>) -> U32:
  match st:
    case Con{YMap{i, ms, p}, t}:
      i
    case Con{YSeq{i, xs, p}, t}:
      i
    case _:
      0

# Whether the top container ends before a line at indent i: it is deeper,
# or it is a sequence at i and the line is no item of it.
def Yaml.ends(+st: List<&2, YFrame>, +i: U32, dash: Bool) -> Bool:
  match st:
    case Con{YMap{+j, ms, p}, t}:
      U32.is_gt(j, i)
    case Con{YSeq{+j, xs, p}, t}:
      Bool.or(U32.is_gt(j, i), Bool.and(U32.is_eq(j, i), Bool.not(dash)))
    case _:
      False{}

def Yaml.pop(st: List<&2, YFrame>) -> List<&2, YFrame>:
  match st:
    case Con{f, t}:
      Yaml.give(Yaml.value(f), t)
    case Nil{}:
      Nil{}

def Yaml.close(fuel: Nat, +st: List<&2, YFrame>, +i: U32, +dash: Bool, ends: Bool) -> List<&2, YFrame>:
  match fuel ends:
    case 1n+f True{}:
      Yaml.close(f, Yaml.pop(st), i, dash, Yaml.ends(Yaml.pop(st), i, dash))
    case _ _:
      st

def Yaml.map_at(+st: List<&2, YFrame>, +i: U32) -> Bool:
  match st:
    case Con{YMap{+j, ms, p}, t}:
      U32.is_eq(j, i)
    case _:
      False{}

def Yaml.mark.go(a: String, k: String, none: Bool) -> String:
  match none:
    case True{}:
      k
    case False{}:
      SCon{Chr{1}, a ++ SCon{Chr{1}, k}}

def Yaml.mark(+a: String, k: String) -> String:
  Yaml.mark.go(a, k, String.is_empty(a))

def Yaml.entry.put.go(st: List<&2, YFrame>, k: String, +a: String, +r: String, empty: Bool) ->
  List<&2, YFrame>:
  match st empty:
    case Con{YMap{i, ms, p}, t} True{}:
      YMap{i, ms, Some{Yaml.mark(a, k)}} <> t
    case Con{YMap{i, ms, p}, t} False{}:
      YMap{i, J.KV{k, Yaml.wrap(a, Yaml.scalar(r))} <> ms, None{}} <> t
    case s _:
      s

def Yaml.entry.put.av(st: List<&2, YFrame>, k: String, av: AV) -> List<&2, YFrame>:
  match av:
    case AV{+a, +r}:
      Yaml.entry.put.go(st, k, a, r, String.is_empty(r))

def Yaml.split_anchor(+s: String) -> AV:
  match s:
    case SCon{'&', t}:
      Yaml.split_word(t)
    case x:
      AV{"", x}

def Yaml.entry.put(st: List<&2, YFrame>, k: String, +r: String, empty: Bool) -> List<&2, YFrame>:
  Yaml.entry.put.av(st, k, Yaml.split_anchor(r))

# Flow collections
# ----------------
#
# A flow value ({a: b, c: [d, 'e']}) becomes JSON text: quoted scalars are
# re-quoted as JSON strings, plain ones read as scalars, punctuation kept.

def Yaml.entry.go(st: List<&2, YFrame>, +i: U32, kr: KR, here: Bool) -> List<&2, YFrame>:
  match kr here:
    case KR{k, +r} True{}:
      Yaml.entry.put(st, k, r, String.is_empty(r))
    case KR{k, +r} False{}:
      Yaml.entry.put(YMap{i, Nil{}, None{}} <> st, k, r, String.is_empty(r))

# A mapping entry at indent i: into the open mapping at i, or a new one.
def Yaml.entry(+st: List<&2, YFrame>, +i: U32, kr: KR) -> List<&2, YFrame>:
  Yaml.entry.go(st, i, kr, Yaml.map_at(st, i))

def Yaml.seq_at(+st: List<&2, YFrame>, +i: U32) -> Bool:
  match st:
    case Con{YSeq{+j, xs, p}, t}:
      U32.is_eq(j, i)
    case _:
      False{}

# A new item: an item still waiting for its block got none, so it is null.
def Yaml.item.seq.go(st: List<&2, YFrame>, +i: U32, here: Bool) -> List<&2, YFrame>:
  match st here:
    case Con{YSeq{j, xs, Some{a}}, t} True{}:
      YSeq{j, Yaml.wrap(a, J.JNull{}) <> xs, None{}} <> t
    case x True{}:
      x
    case x False{}:
      YSeq{i, Nil{}, None{}} <> x

def Yaml.item.seq(+st: List<&2, YFrame>, +i: U32) -> List<&2, YFrame>:
  Yaml.item.seq.go(st, i, Yaml.seq_at(st, i))

def Yaml.item.value.go(st: List<&2, YFrame>, +a: String, +r: String, empty: Bool) -> List<&2, YFrame>:
  match st empty:
    case Con{YSeq{i, xs, p}, t} True{}:
      YSeq{i, xs, Some{a}} <> t
    case x _:
      Yaml.give(Yaml.wrap(a, Yaml.scalar(r)), x)

# "- &a value", "- *a", "- " (a block follows), or "- &a" (an anchored
# block follows).
def Yaml.item.value(st: List<&2, YFrame>, av: AV) -> List<&2, YFrame>:
  match av:
    case AV{+a, +r}:
      Yaml.item.value.go(st, a, r, String.is_empty(r))

# The item is a mapping when it reads "key: ..." (its keys then sit at
# i + 2), else a scalar.
def Yaml.item.go(st: List<&2, YFrame>, +i: U32, rest: String, kr: Maybe<&2, KR>) -> List<&2, YFrame>:
  match kr:
    case Some{x}:
      Yaml.entry.go(st, (i + 2 : U32), x, False{})
    case None{}:
      Yaml.item.value(st, Yaml.split_anchor(rest))

# A "- item" line at indent i: into the open sequence at i, or a new one.
def Yaml.item(+st: List<&2, YFrame>, +i: U32, +rest: String) -> List<&2, YFrame>:
  Yaml.item.go(Yaml.item.seq(st, i), i, rest, Yaml.key(rest))

def Yaml.is_dash(t: String) -> Bool:
  match t:
    case SCon{'-', SCon{' ', r}}:
      True{}
    case "-":
      True{}
    case _:
      False{}

def Yaml.after_dash(t: String) -> String:
  String.trim(String.drop(t, 1n))

def Yaml.step.entry(+st: List<&2, YFrame>, +i: U32, +t: String, kr: Maybe<&2, KR>) -> List<&2, YFrame>:
  match kr:
    case Some{x}:
      Yaml.entry(st, i, x)
    case None{}:
      Yaml.give(Yaml.scalar(t), st)

def Yaml.step.go(+st: List<&2, YFrame>, +i: U32, +t: String, dash: Bool) -> List<&2, YFrame>:
  match dash:
    case True{}:
      Yaml.item(st, i, Yaml.after_dash(t))
    case False{}:
      Yaml.step.entry(st, i, t, Yaml.key(t))

# One line.
def Yaml.step(+st: List<&2, YFrame>, l: Line) -> List<&2, YFrame>:
  match l:
    case Line{+i, +t}:
      Yaml.step.go(Yaml.close(64n, st, i, Yaml.is_dash(t), Yaml.ends(st, i, Yaml.is_dash(t))), i, t,
        Yaml.is_dash(t))

def Yaml.feed(ls: List<&2, Line>, +st: List<&2, YFrame>) -> List<&2, YFrame>:
  match ls:
    case Nil{}:
      st
    case Con{l, t}:
      Yaml.feed(t, Yaml.step(st, l))

def Yaml.result(st: List<&2, YFrame>) -> J.Json:
  match st:
    case Con{YRoot{v}, t}:
      v
    case Con{f, t}:
      Yaml.value(f)
    case Nil{}:
      J.JNull{}

def Yaml.is_open(st: List<&2, YFrame>) -> Bool:
  match st:
    case Con{YRoot{v}, t}:
      False{}
    case Con{f, t}:
      True{}
    case Nil{}:
      False{}

def Yaml.close_all.go(fuel: Nat, +st: List<&2, YFrame>, open: Bool) -> List<&2, YFrame>:
  match fuel open:
    case 1n+f True{}:
      Yaml.close_all.go(f, Yaml.pop(st), Yaml.is_open(Yaml.pop(st)))
    case _ _:
      st

# Closes every open container, into the document.
def Yaml.close_all(fuel: Nat, +st: List<&2, YFrame>) -> List<&2, YFrame>:
  Yaml.close_all.go(fuel, st, Yaml.is_open(st))

def YR.json(r: YR) -> J.Json:
  match r:
    case YR{j, a}:
      j

# Resolution
# ----------


def YR.anchors(r: YR) -> Map<&2, J.Json>:
  match r:
    case YR{j, a}:
      a

def Yaml.marker.go(n: String, hit: Bool) -> Maybe<&2, String>:
  match hit:
    case True{}:
      Some{n}
    case False{}:
      None{}

def Yaml.marker(s: String, +kind: Char) -> Maybe<&2, String>:
  match s:
    case SCon{Chr{+c}, SCon{+k, n}}:
      Yaml.marker.go(n, Bool.and(U32.is_eq(c, 0), Char.is_eq(k, kind)))
    case _:
      None{}

def Yaml.anchor_name(k: String) -> Maybe<&2, String>:
  Yaml.marker(k, '&')

def Yaml.res.mem(k: String, h: YR, t: YR) -> YR:
  match h t:
    case YR{v, a} YR{rest, a2}:
      YR{J.JMem{k, v, rest}, a2}

def Yaml.res.cons(h: YR, t: YR) -> YR:
  match h t:
    case YR{v, a} YR{rest, a2}:
      YR{J.JCons{v, rest}, a2}

def Yaml.merge.take(+ms: J.Json) -> J.Json:
  J.Json.lookup(ms, "<<")

def Yaml.merge.missing.put(k: String, v: J.Json, rest: J.Json, h: Bool, has: Bool) -> J.Json:
  match has:
    case True{}:
      rest
    case False{}:
      J.JMem{k, v, rest}

def Yaml.has(ms: J.Json, +k: String) -> Bool:
  Bool.not(J.Json.is_null(J.Json.lookup(ms, k)))

# Members whose keys the chain ms lacks, from the merged object's chain.
def Yaml.merge.missing(src: J.Json, +ms: J.Json) -> J.Json:
  match src:
    case J.JMem{+k, v, t}:
      Yaml.merge.missing.put(k, v, Yaml.merge.missing(t, ms), J.Json.head_is(ms, k), Yaml.has(ms, k))
    case _:
      J.JNil{}

def Yaml.append_mem(ms: J.Json, extra: J.Json) -> J.Json:
  match ms:
    case J.JMem{k, v, t}:
      J.JMem{k, v, Yaml.append_mem(t, extra)}
    case _:
      extra

def Yaml.merge.go(src: J.Json, +rest: J.Json) -> J.Json:
  match src:
    case J.JObj{m}:
      Yaml.append_mem(rest, Yaml.merge.missing(m, rest))
    case _:
      rest

# Applies a "<<" member: its object's members join where keys are absent.
def Yaml.merge(+ms: J.Json) -> J.Json:
  Yaml.merge.go(Yaml.merge.take(ms), J.Json.del_mem(ms, "<<"))

def Yaml.res.obj(r: YR) -> YR:
  match r:
    case YR{ms, a}:
      YR{J.JObj{Yaml.merge(ms)}, a}

def Yaml.res.arr(r: YR) -> YR:
  match r:
    case YR{xs, a}:
      YR{J.JArr{xs}, a}

def Yaml.is_alias(s: String) -> Maybe<&2, String>:
  Yaml.marker(s, '*')

def Yaml.lookup.fin(r: Map<&2, J.Json> & J.Json) -> J.Json:
  match r:
    case (m, v):
      v

def Yaml.alias(+name: String, +anchors: Map<&2, J.Json>) -> J.Json:
  Yaml.lookup.fin(Map.get(J.Json, J.JNull{}, anchors, name))

def Yaml.res.str(s: String, +a: Map<&2, J.Json>, alias: Maybe<&2, String>) -> YR:
  match alias:
    case Some{n}:
      YR{Yaml.alias(n, a), a}
    case None{}:
      YR{J.JStr{s}, a}

def Yaml.res.anchor(+n: String, r: YR) -> YR:
  match r:
    case YR{+v, a}:
      YR{v, Map.set(&2, J.Json, a, n, v)}

# A one-member object: an anchor marker, or a plain object.
def Yaml.res.single(+k: String, n: Maybe<&2, String>, +rv: YR, tail: J.Json, a: Map<&2, J.Json>) -> YR:
  match n:
    case Some{name}:
      Yaml.res.anchor(name, rv)
    case None{}:
      Yaml.res.obj(Yaml.res.mem(k, rv, YR{tail, YR.anchors(rv)}))

# The document with anchors recorded, aliases replaced and merges applied.
def Yaml.res(j: J.Json, +a: Map<&2, J.Json>) -> YR:
  match j:
    case J.JStr{+s}:
      Yaml.res.str(s, a, Yaml.is_alias(s))
    case J.JObj{J.JMem{+k, v, J.JNil{}}}:
      Yaml.res.single(k, Yaml.anchor_name(k), Yaml.res(v, a), J.JNil{}, a)
    case J.JObj{ms}:
      Yaml.res.obj(Yaml.res(ms, a))
    case J.JArr{xs}:
      Yaml.res.arr(Yaml.res(xs, a))
    case J.JCons{h, t}:
      +rh = Yaml.res(h, a)
      Yaml.res.cons(rh, Yaml.res(t, YR.anchors(rh)))
    case J.JMem{k, v, t}:
      +rv = Yaml.res(v, a)
      Yaml.res.mem(k, rv, Yaml.res(t, YR.anchors(rv)))
    case x:
      YR{x, a}

def Yaml.resolve(j: J.Json) -> J.Json:
  YR.json(Yaml.res(j, Map.new(&2, J.Json)))

# The (first) document as JSON, anchors and aliases resolved.
def Yaml.parse(s: String) -> J.Json:
  Yaml.resolve(Yaml.result(Yaml.close_all(64n, Yaml.feed(Yaml.lines(s), Nil{}))))

# Documents
# ---------

def Yaml.is_sep(+l: String) -> Bool:
  Bool.or(String.starts_with(l, "---"), String.eq(String.trim_end(l), "..."))

def Yaml.docs.cur(+l: String, cur: List<&2, String>, sep: Bool) -> List<&2, String>:
  match sep:
    case True{}:
      Nil{}
    case False{}:
      l <> cur

def Yaml.docs.done(+cur: List<&2, String>, done: List<&2, String>, sep: Bool) -> List<&2, String>:
  match sep:
    case True{}:
      String.join(List.reverse(&2, String, cur), "\n") <> done
    case False{}:
      done

# Splits a stream at "---" and "..." lines; documents come reversed.
def Yaml.docs.go(ls: List<&2, String>, +cur: List<&2, String>, done: List<&2, String>) -> List<&2, String>:
  match ls:
    case Nil{}:
      String.join(List.reverse(&2, String, cur), "\n") <> done
    case Con{+l, t}:
      Yaml.docs.go(t, Yaml.docs.cur(l, cur, Yaml.is_sep(l)), Yaml.docs.done(cur, done, Yaml.is_sep(l)))

def Yaml.docs.keep(d: String, acc: List<&2, J.Json>, empty: Bool) -> List<&2, J.Json>:
  match empty:
    case True{}:
      acc
    case False{}:
      Yaml.parse(d) <> acc

def Yaml.docs.parse(ds: List<&2, String>, acc: List<&2, J.Json>) -> List<&2, J.Json>:
  match ds:
    case Nil{}:
      acc
    case Con{+d, t}:
      Yaml.docs.parse(t, Yaml.docs.keep(d, acc, List.is_empty(&2, Line, Yaml.lines(d))))

# Every document of a stream (kubectl's multi-document files), in order;
# empty documents are skipped.
def Yaml.parse_all(s: String) -> List<&2, J.Json>:
  Yaml.docs.parse(Yaml.docs.go(String.lines(s), Nil{}, Nil{}), Nil{})
