import Base
import ./json.bend as J
import ./utf8.bend as U
import ./base64.bend as B
import ./http.bend as H
import ./net.bend as N
import ./core.bend as C
import ./config.bend as K
import ./client.bend as Cl
import ./ws.bend as W

# Exec
# ====
#
# Runs a command in a pod's container, as `kubectl exec` does: a WebSocket
# upgrade of GET .../pods/NAME/exec speaking v5.channel.k8s.io. Every
# message carries its channel in its first byte: 0 stdin, 1 stdout,
# 2 stderr, 3 the final Status; a client closes stdin with the message
# 255 0, which v5 added (v4 cannot close stdin, so it is not offered).
# The command's whole output is collected: exec suits short commands.

type Out is Data:
  Out{status: J.Json, stdout: String, stderr: String}

# Output
# ------

# Whether the command exited 0.
def Exec.ok(o: Out) -> Bool:
  match o:
    case Out{st, a, b}:
      String.eq(J.Json.str_or(J.Json.at(st, ["status"]), ""), "Success")

# Why it did not: the Status message (the exit code, or why it could not
# run).
def Exec.why(o: Out) -> String:
  match o:
    case Out{st, a, b}:
      J.Json.str_or(J.Json.at(st, ["message"]), "")

def Exec.stdout(o: Out) -> String:
  match o:
    case Out{st, a, b}:
      a

def Exec.stderr(o: Out) -> String:
  match o:
    case Out{st, a, b}:
      b

# Request
# -------

def Exec.args(cmd: List<&2, String>) -> String:
  match cmd:
    case Nil{}:
      ""
    case Con{c, t}:
      "&command=" ++ H.Http.encode(c) ++ Exec.args(t)

def Exec.flag(on: Bool) -> String:
  match on:
    case True{}:
      "&stdin=true"
    case False{}:
      ""

def Exec.path(ns: String, pod: String, container: String, cmd: List<&2, String>, stdin: Bool) ->
  String:
  "/api/v1/namespaces/" ++ H.Http.encode(ns) ++ "/pods/" ++ H.Http.encode(pod) ++
    "/exec?container=" ++ H.Http.encode(container) ++ "&stdout=true&stderr=true" ++
    Exec.flag(stdin) ++ Exec.args(cmd)

def Exec.key(+k: U32) -> String:
  B.B64.encode([W.Ws.byte(k, 0n), W.Ws.byte(k, 1n), W.Ws.byte(k, 2n), W.Ws.byte(k, 3n),
    W.Ws.byte(k, 3n), W.Ws.byte(k, 2n), W.Ws.byte(k, 1n), W.Ws.byte(k, 0n),
    W.Ws.byte(k, 1n), W.Ws.byte(k, 3n), W.Ws.byte(k, 0n), W.Ws.byte(k, 2n),
    W.Ws.byte(k, 2n), W.Ws.byte(k, 0n), W.Ws.byte(k, 3n), W.Ws.byte(k, 1n)])

def Exec.req(path: String, +k: U32) -> H.Req:
  H.Req{"GET", path, [H.Header{"Upgrade", "websocket"}, H.Header{"Connection", "Upgrade"},
    H.Header{"Sec-WebSocket-Version", "13"}, H.Header{"Sec-WebSocket-Key", Exec.key(k)},
    H.Header{"Sec-WebSocket-Protocol", "v5.channel.k8s.io"}], ""}

# The upgrade's head
# ------------------

# Bytes up to the blank line that ends the head (reversed), how much of
# CR LF CR LF matched so far, and the bytes after it.
type Scan is Data:
  Scan{head: List<&2, U32>, matched: U32, rest: List<&2, U32>, found: Bool}

def Scan.next.go(+m: U32, hit: Bool, cr: Bool) -> U32:
  match hit cr:
    case True{} c:
      (m + 1 : U32)
    case False{} True{}:
      1
    case False{} False{}:
      0

# The next count of CR LF CR LF matched, after byte b.
def Scan.next(+m: U32, +b: U32) -> U32:
  Scan.next.go(m,
    U32.is_eq(b, U32.mod(U32.shrn(168626701, Nat.mul(8n, U32.to_nat(m))), 256)), U32.is_eq(b, 13))

def Scan.feed.go(bs: List<&2, U32>, +head: List<&2, U32>, +m: U32, +rest: List<&2, U32>,
  found: Bool) -> Scan:
  match bs found:
    case Nil{} f:
      Scan{head, m, rest, f}
    case Con{b, t} True{}:
      Scan{head, m, List.append(&2, U32, rest, Con{b, t}), True{}}
    case Con{+b, t} False{}:
      Scan.feed.go(t, Con{b, head}, Scan.next(m, b), rest, U32.is_eq(Scan.next(m, b), 4))

def Scan.feed(s: Scan, bs: List<&2, U32>) -> Scan:
  match s:
    case Scan{head, m, rest, f}:
      Scan.feed.go(bs, head, m, rest, f)

def Scan.found(s: Scan) -> Bool:
  match s:
    case Scan{h, m, r, f}:
      f

type HEv is Type:
  HGot{sock: Socket, r: Result<&1, &1, U32 & String, List<&2, U32>>}
  HChk{sock: Socket, found: Bool, eof: Bool}

def HEv.got(p: Socket & Result<&1, &1, U32 & String, List<&2, U32>>) -> HEv:
  match p:
    case (s, r):
      HGot{s, r}

# Reads until the head is whole.
def Exec.head(fuel: Nat, ev: HEv, +sc: Scan, +ms: U32) ->
  IO(Socket & Result<&2, &2, Cl.KErr, Scan>):
  match fuel ev:
    case 0n HGot{s, r}:
      IO.pure(Socket & Result<&2, &2, Cl.KErr, Scan>, (s, Fail{Cl.KNet{0, "exec: head too long"}}))
    case 0n HChk{s, f, e}:
      IO.pure(Socket & Result<&2, &2, Cl.KErr, Scan>, (s, Fail{Cl.KNet{0, "exec: head too long"}}))
    case 1n+f HGot{s, Done{+bs}}:
      +next = Scan.feed(sc, bs)
      Exec.head(f, HChk{s, Scan.found(next), List.is_empty(&2, U32, bs)}, next, ms)
    case 1n+f HGot{s, Fail{(c, m)}}:
      IO.pure(Socket & Result<&2, &2, Cl.KErr, Scan>, (s, Fail{Cl.KNet{c, "exec: recv: " ++ m}}))
    case 1n+f HChk{s, True{}, e}:
      IO.pure(Socket & Result<&2, &2, Cl.KErr, Scan>, (s, Done{sc}))
    case 1n+f HChk{s, False{}, True{}}:
      IO.pure(Socket & Result<&2, &2, Cl.KErr, Scan>,
        (s, Fail{Cl.KNet{0, "exec: connection closed before the upgrade"}}))
    case 1n+f HChk{s, False{}, False{}}:
      IO.bind(Socket & Result<&1, &1, U32 & String, List<&2, U32>>,
        Socket & Result<&2, &2, Cl.KErr, Scan>, N.Tls.recv(s, 65536, ms),
        p => Exec.head(f, HEv.got(p), sc, ms))

# The messages
# ------------

# Output so far (each reversed), the channel of the message a continuation
# frame extends, whether the server closed, and the decoder.
type Acc is Data:
  Acc{st: W.WSt, out: List<&2, U32>, err: List<&2, U32>, status: List<&2, U32>, chan: U32,
    closed: Bool}

def Acc.put.go(st: W.WSt, +chan: U32, bs: List<&2, U32>, +o: List<&2, U32>, +e: List<&2, U32>,
  +s: List<&2, U32>, closed: Bool, one: Bool, two: Bool, three: Bool) -> Acc:
  match one two three:
    case True{} _ _:
      Acc{st, List.append(&2, U32, List.reverse(&2, U32, bs), o), e, s, chan, closed}
    case False{} True{} _:
      Acc{st, o, List.append(&2, U32, List.reverse(&2, U32, bs), e), s, chan, closed}
    case False{} False{} True{}:
      Acc{st, o, e, List.append(&2, U32, List.reverse(&2, U32, bs), s), chan, closed}
    case False{} False{} False{}:
      Acc{st, o, e, s, chan, closed}

def Acc.put(st: W.WSt, +chan: U32, bs: List<&2, U32>, +o: List<&2, U32>, +e: List<&2, U32>,
  +s: List<&2, U32>, closed: Bool) -> Acc:
  Acc.put.go(st, chan, bs, o, e, s, closed, U32.is_eq(chan, 1), U32.is_eq(chan, 2),
    U32.is_eq(chan, 3))

def Acc.frame.kind(st: W.WSt, +o: List<&2, U32>, +e: List<&2, U32>, +s: List<&2, U32>, +ch: U32,
  cl: Bool, data: List<&2, U32>, cont: Bool, msg: Bool, close: Bool) -> Acc:
  match data cont msg close:
    case d True{} m c:
      Acc.put(st, ch, d, o, e, s, cl)
    case Con{+c, t} False{} True{} x:
      Acc.put(st, c, t, o, e, s, cl)
    case d False{} False{} True{}:
      Acc{st, o, e, s, ch, True{}}
    case d False{} m c:
      Acc{st, o, e, s, ch, cl}

def Acc.frame.go(st: W.WSt, +o: List<&2, U32>, +e: List<&2, U32>, +s: List<&2, U32>, +ch: U32,
  cl: Bool, +op: U32, data: List<&2, U32>) -> Acc:
  Acc.frame.kind(st, o, e, s, ch, cl, data, U32.is_zero(op), Bool.or(U32.is_eq(op, 1),
    U32.is_eq(op, 2)), U32.is_eq(op, 8))

# One frame: a data frame starts with its channel; a continuation extends
# the last one; close ends the stream; pings and pongs are dropped.
def Acc.frame(a: Acc, f: W.Frame) -> Acc:
  match a f:
    case Acc{st, +o, +e, +s, +ch, cl} W.Frame{fin, +op, data}:
      Acc.frame.go(st, o, e, s, ch, cl, op, data)

def Acc.frames(fs: List<&2, W.Frame>, a: Acc) -> Acc:
  match fs:
    case Nil{}:
      a
    case Con{f, t}:
      Acc.frames(t, Acc.frame(a, f))

def Acc.with(a: Acc, st: W.WSt) -> Acc:
  match a:
    case Acc{s0, o, e, s, ch, cl}:
      Acc{st, o, e, s, ch, cl}

def Acc.fed(a: Acc, f: W.Fed) -> Acc:
  match f:
    case W.Fed{st, fs}:
      Acc.frames(fs, Acc.with(a, st))

def Acc.feed(a: Acc, bs: List<&2, U32>) -> Acc:
  match a:
    case Acc{+st, o, e, s, ch, cl}:
      Acc.fed(Acc{st, o, e, s, ch, cl}, W.Ws.feed(st, bs))

def Acc.closed(a: Acc) -> Bool:
  match a:
    case Acc{st, o, e, s, ch, cl}:
      cl

def Acc.error(a: Acc) -> Maybe<&2, String>:
  match a:
    case Acc{st, o, e, s, ch, cl}:
      W.Ws.error(st)

def Acc.status(s: Result<&2, &2, String, J.Json>) -> J.Json:
  match s:
    case Done{j}:
      j
    case Fail{m}:
      J.Json.obj([J.KV{"status", J.JStr{"Failure"}},
        J.KV{"message", J.JStr{"exec ended without a status"}}])

def Acc.out(a: Acc) -> Out:
  match a:
    case Acc{st, o, e, s, ch, cl}:
      Out{Acc.status(J.Json.parse(U.Utf8.decode_all(List.reverse(&2, U32, s)))),
        U.Utf8.decode_all(List.reverse(&2, U32, o)), U.Utf8.decode_all(List.reverse(&2, U32, e))}

type XEv is Type:
  XGot{sock: Socket, r: Result<&1, &1, U32 & String, List<&2, U32>>}
  XChk{sock: Socket, eof: Bool, closed: Bool, bad: Maybe<&2, String>}

def XEv.got(p: Socket & Result<&1, &1, U32 & String, List<&2, U32>>) -> XEv:
  match p:
    case (s, r):
      XGot{s, r}

# Reads messages until the server closes or the stream ends.
def Exec.read(fuel: Nat, ev: XEv, +acc: Acc, +ms: U32) -> IO(Socket & Result<&2, &2, Cl.KErr, Out>):
  match fuel ev:
    case 0n XGot{s, r}:
      IO.pure(Socket & Result<&2, &2, Cl.KErr, Out>, (s, Fail{Cl.KNet{0, "exec: output too long"}}))
    case 0n XChk{s, e, c, b}:
      IO.pure(Socket & Result<&2, &2, Cl.KErr, Out>, (s, Fail{Cl.KNet{0, "exec: output too long"}}))
    case 1n+f XGot{s, Done{+bs}}:
      +next = Acc.feed(acc, bs)
      Exec.read(f, XChk{s, List.is_empty(&2, U32, bs), Acc.closed(next), Acc.error(next)}, next,
        ms)
    case 1n+f XGot{s, Fail{(c, m)}}:
      IO.pure(Socket & Result<&2, &2, Cl.KErr, Out>, (s, Fail{Cl.KNet{c, "exec: recv: " ++ m}}))
    case 1n+f XChk{s, e, c, Some{why}}:
      IO.pure(Socket & Result<&2, &2, Cl.KErr, Out>, (s, Fail{Cl.KNet{0, "exec: " ++ why}}))
    case 1n+f XChk{s, True{}, c, None{}}:
      IO.pure(Socket & Result<&2, &2, Cl.KErr, Out>, (s, Done{Acc.out(acc)}))
    case 1n+f XChk{s, False{}, True{}, None{}}:
      IO.pure(Socket & Result<&2, &2, Cl.KErr, Out>, (s, Done{Acc.out(acc)}))
    case 1n+f XChk{s, False{}, False{}, None{}}:
      IO.bind(Socket & Result<&1, &1, U32 & String, List<&2, U32>>,
        Socket & Result<&2, &2, Cl.KErr, Out>, N.Tls.recv(s, 65536, ms),
        p => Exec.read(f, XEv.got(p), acc, ms))

# Running
# -------

def Exec.Res() -> Type:
  Result<&2, &2, Cl.KErr, Out>

def Exec.close(p: Socket & Result<&2, &2, Cl.KErr, Out>) -> IO(Result<&2, &2, Cl.KErr, Out>):
  match p:
    case (s, r):
      IO.bind(Unit, Result<&2, &2, Cl.KErr, Out>, N.Tls.close(s),
        u => IO.pure(Result<&2, &2, Cl.KErr, Out>, r))

def Exec.listen(s: Socket, rest: List<&2, U32>, +ms: U32) ->
  IO(Result<&2, &2, Cl.KErr, Out>):
  IO.bind(Socket & Result<&2, &2, Cl.KErr, Out>, Result<&2, &2, Cl.KErr, Out>,
    Exec.read(4294967295n, XChk{s, False{}, False{}, None{}},
      Acc.feed(Acc{W.WHead{}, Nil{}, Nil{}, Nil{}, 1, False{}}, rest), ms),
    Exec.close)

def Exec.sent(p: Socket & Result<&1, &1, U32 & String, Unit>, rest: List<&2, U32>, +ms: U32) ->
  IO(Result<&2, &2, Cl.KErr, Out>):
  match p:
    case (s, Done{u}):
      Exec.listen(s, rest, ms)
    case (s, Fail{(c, m)}):
      Exec.close((s, Fail{Cl.KNet{c, "exec: send: " ++ m}}))

# The input, then the close of stdin, in one write.
def Exec.input(+text: String, +k: U32) -> List<&2, U32>:
  List.append(&2, U32, W.Ws.frame(W.Ws.binary(), Con{0, U.Utf8.encode(text)}, k),
    W.Ws.frame(W.Ws.binary(), [255, 0], U32.xor(k, 1515870810)))

def Exec.upgraded(s: Socket, rest: List<&2, U32>, stdin: Maybe<&2, String>, +k: U32, +ms: U32) ->
  IO(Result<&2, &2, Cl.KErr, Out>):
  match stdin:
    case None{}:
      Exec.listen(s, rest, ms)
    case Some{text}:
      IO.bind(Socket & Result<&1, &1, U32 & String, Unit>, Result<&2, &2, Cl.KErr, Out>,
        N.Tls.send_bytes(s, Exec.input(text, k), ms), p => Exec.sent(p, rest, ms))

def Exec.message(+text: String, j: Result<&2, &2, String, J.Json>) -> String:
  match j:
    case Done{s}:
      J.Json.str_or(J.Json.at(s, ["message"]), text)
    case Fail{m}:
      text

# A refused upgrade: the status, and the message of the Status body the
# head's recv brought along (or the bytes as they are).
def Exec.refused(+code: U32, reason: String, +rest: List<&2, U32>) -> Cl.KErr:
  Cl.KApi{C.Status{code, reason,
    Exec.message(String.trim(U.Utf8.decode_all(rest)), J.Json.parse(U.Utf8.decode_all(rest)))}}

def Exec.answer.go(s: Socket, +code: U32, reason: String, rest: List<&2, U32>,
  stdin: Maybe<&2, String>, +k: U32, +ms: U32, up: Bool) -> IO(Result<&2, &2, Cl.KErr, Out>):
  match up:
    case True{}:
      Exec.upgraded(s, rest, stdin, k, ms)
    case False{}:
      Exec.close((s, Fail{Exec.refused(code, reason, rest)}))

def Exec.answer(s: Socket, h: Maybe<&2, H.Head>, rest: List<&2, U32>, stdin: Maybe<&2, String>,
  +k: U32, +ms: U32) -> IO(Result<&2, &2, Cl.KErr, Out>):
  match h:
    case Some{H.Head{+code, reason, hs}}:
      Exec.answer.go(s, code, reason, rest, stdin, k, ms, U32.is_eq(code, 101))
    case None{}:
      Exec.close((s, Fail{Cl.KNet{0, "exec: a malformed answer to the upgrade"}}))

def Exec.headed(p: Socket & Result<&2, &2, Cl.KErr, Scan>, stdin: Maybe<&2, String>, +k: U32,
  +ms: U32) -> IO(Result<&2, &2, Cl.KErr, Out>):
  match p:
    case (s, Done{Scan{head, m, rest, f}}):
      Exec.answer(s, H.Http.parse_head(U.Utf8.decode_all(List.reverse(&2, U32, head))), rest,
        stdin, k, ms)
    case (s, Fail{e}):
      Exec.close((s, Fail{e}))

def Exec.opened(t: Result<&1, &1, U32 & String, N.Tls>, stdin: Maybe<&2, String>, +k: U32,
  +ms: U32) -> IO(Result<&2, &2, Cl.KErr, Out>):
  match t:
    case Done{N.Tls{s}}:
      IO.bind(Socket & Result<&2, &2, Cl.KErr, Scan>, Result<&2, &2, Cl.KErr, Out>,
        Exec.head(4096n, HChk{s, False{}, False{}}, Scan{Nil{}, 0, Nil{}, False{}}, ms),
        p => Exec.headed(p, stdin, k, ms))
    case Fail{(c, m)}:
      IO.pure(Result<&2, &2, Cl.KErr, Out>, Fail{Cl.KNet{c, m}})

def Exec.keyed(+cfg: K.Config, path: String, stdin: Maybe<&2, String>, +ms: U32,
  r: Result<&1, &1, U32 & String, U32>) -> IO(Result<&2, &2, Cl.KErr, Out>):
  match r:
    case Done{+k}:
      IO.bind(Result<&1, &1, U32 & String, N.Tls>, Result<&2, &2, Cl.KErr, Out>,
        Cl.Conn.open(cfg, Exec.req(path, k), False{}), t => Exec.opened(t, stdin, k, ms))
    case Fail{(c, m)}:
      IO.pure(Result<&2, &2, Cl.KErr, Out>, Fail{Cl.KNet{c, "exec: no random key: " ++ m}})

# Runs cmd in container of pod ns/name, writing stdin to it (None: no
# stdin), and collects its output; ms bounds each wait for the server
# (0: none). Done means the exec ran: Exec.ok says how the command ended.
def Exec.run(+cfg: K.Config, ns: String, pod: String, container: String, cmd: List<&2, String>,
  +stdin: Maybe<&2, String>, +ms: U32) -> IO(Result<&2, &2, Cl.KErr, Out>):
  IO.bind(Result<&1, &1, U32 & String, U32>, Result<&2, &2, Cl.KErr, Out>, IO.random_u32(),
    r => Exec.keyed(cfg, Exec.path(ns, pod, container, cmd, Maybe.is_some(&2, String, stdin)),
      stdin, ms, r))
