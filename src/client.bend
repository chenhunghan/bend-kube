import Base
import ./json.bend as J
import ./utf8.bend as U
import ./http.bend as H
import ./core.bend as C
import ./config.bend as K
import ./net.bend as N
import ./yaml.bend as Y
import ./queue.bend as Q
import ./lease.bend as E

# Client
# ======
#
# kube-client in Bend: requests go over verified TLS connections from a
# keep-alive pool (Kube.pool), each returned only after a response its
# framing ended, and a stale one retried by Go's transport rule (Pooling,
# below). Watches hold their own connection for the stream's life; see
# watcher.bend.
#
# Loops here take what just happened as a parameter (an event), and match
# it at their head: Bend matches parameters only and forbids mutual
# recursion, so a loop cannot branch inside a bind's continuation.

def Res(-A: Type) -> Type:
  Result<&1, &1, U32 & String, A>

# KRetry: an API error that names a delay: the Status body's
# details.retryAfterSeconds, else the Retry-After header (seconds), as the
# API server sends with 429 and some 5xx answers.
type KErr is Data:
  KNet{code: U32, msg: String}
  KApi{status: C.Status}
  KRetry{status: C.Status, secs: U32}
  KDecode{msg: String}

type Reply is Data:
  Reply{status: U32, body: String, retry: Maybe<&2, U32>}

def KErr.show(e: KErr) -> String:
  match e:
    case KNet{c, m}:
      "network: " ++ m
    case KApi{s}:
      "api: " ++ C.Status.show(s)
    case KRetry{s, +n}:
      "api: " ++ C.Status.show(s) ++ " (retry after " ++ U32.show(n) ++ "s)"
    case KDecode{m}:
      "decode: " ++ m

# Whether a failed call is worth retrying: the network, 429 (API priority
# and fairness), and 5xx. 4xx answers are final.
def KErr.retryable(e: KErr) -> Bool:
  match e:
    case KNet{c, m}:
      True{}
    case KApi{C.Status{+c, r, m}}:
      Bool.or(U32.is_eq(c, 429), U32.is_ge(c, 500))
    case KRetry{s, n}:
      True{}
    case KDecode{m}:
      False{}

def KErr.code(e: KErr) -> U32:
  match e:
    case KApi{C.Status{c, r, m}}:
      c
    case KRetry{C.Status{c, r, m}, n}:
      c
    case _:
      0

def KErr.reason(e: KErr) -> String:
  match e:
    case KApi{C.Status{c, r, m}}:
      r
    case KRetry{C.Status{c, r, m}, n}:
      r
    case _:
      ""

# The delay the server asked for, in seconds, if it named one.
def KErr.retry_after(e: KErr) -> Maybe<&2, U32>:
  match e:
    case KRetry{s, n}:
      Some{n}
    case _:
      None{}

def KErr.action.go(+e: KErr, m: Maybe<&2, U32>) -> Q.Action:
  match m:
    case Some{+n}:
      Q.RetryIn{KErr.show(e), (U32.max(U32.min(n, 1000), 1) * 1000 : U32)}
    case None{}:
      Q.Retry{KErr.show(e)}

# What a reconcile answers after a failed call: retry after the delay the
# server named (a 429's Retry-After), from 1s (so a 0 cannot spin) to at
# most 1000s (the key backoff's own cap, so a bad value cannot park a key
# for weeks), else retry with the key's backoff.
def KErr.action(+e: KErr) -> Q.Action:
  KErr.action.go(e, KErr.retry_after(e))

# A write lost to a newer resourceVersion (409 Conflict): read again and
# retry (client-go's retry.RetryOnConflict case).
def KErr.is_conflict(+e: KErr) -> Bool:
  Bool.and(U32.is_eq(KErr.code(e), 409), Bool.not(String.eq(KErr.reason(e), "AlreadyExists")))

def KErr.is_not_found(+e: KErr) -> Bool:
  U32.is_eq(KErr.code(e), 404)

def KErr.is_already_exists(+e: KErr) -> Bool:
  Bool.and(U32.is_eq(KErr.code(e), 409), String.eq(KErr.reason(e), "AlreadyExists"))

# The server is shedding load (429): back off before retrying.
def KErr.is_throttled(+e: KErr) -> Bool:
  U32.is_eq(KErr.code(e), 429)

# Files
# -----

def Fs.close_with(-A: Type, f: File, r: Res(A)) -> IO(Res(A)):
  IO.bind(Unit, Res(A), File.close(f), u => IO.pure(Res(A), r))

def Fs.read.got(p: File & Res(List<&2, U32>)) -> IO(Res(String)):
  match p:
    case (f, Done{bs}):
      Fs.close_with(String, f, Done{U.Utf8.decode_all(bs)})
    case (f, Fail{e}):
      Fs.close_with(String, f, Fail{e})

def Fs.read.sized.go(f: File, +n: U32, empty: Bool) -> IO(Res(String)):
  match empty:
    case True{}:
      Fs.close_with(String, f, Done{""})
    case False{}:
      IO.bind(File & Res(List<&2, U32>), Res(String), File.read_bytes(f, n), Fs.read.got)

def Fs.read.sized(p: File & Res(U32)) -> IO(Res(String)):
  match p:
    case (f, Done{+n}):
      Fs.read.sized.go(f, n, U32.is_eq(n, 0))
    case (f, Fail{e}):
      Fs.close_with(String, f, Fail{e})

def Fs.read.opened(r: Res(File)) -> IO(Res(String)):
  match r:
    case Done{f}:
      IO.bind(File & Res(U32), Res(String), File.size(f), Fs.read.sized)
    case Fail{e}:
      IO.pure(Res(String), Fail{e})

# A whole file as UTF-8 text.
def Fs.read(path: String) -> IO(Res(String)):
  IO.bind(Res(File), Res(String), File.open(path, "r"), Fs.read.opened)

def Src.load.fin(+path: String, r: Res(String)) -> IO(Res(String)):
  match r:
    case Done{s}:
      IO.pure(Res(String), Done{s})
    case Fail{(c, m)}:
      IO.pure(Res(String), Fail{(c, path ++ ": " ++ m)})

def Strs.own(xs: List<&2, String>) -> List<String>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{x, t}:
      x <> Strs.own(t)

def Exec.token.got(+cmd: String, t: J.Json) -> Res(String):
  match t:
    case J.JStr{tok}:
      Done{tok}
    case _:
      Fail{(5, cmd ++ ": the ExecCredential has no status.token")}

def Exec.token.json(+cmd: String, j: Result<&2, &2, String, J.Json>) -> Res(String):
  match j:
    case Done{+c}:
      Exec.token.got(cmd, J.Json.at(c, ["status", "token"]))
    case Fail{e}:
      Fail{(5, cmd ++ ": bad ExecCredential: " ++ e)}

# A credential plugin's answer (client-go's exec ExecCredential): its
# status.token. The plugin runs on every connection, so it may cache and
# refresh tokens as it sees fit.
def Exec.token(+cmd: String, r: Res(U32 & (String & String))) -> IO(Res(String)):
  match r:
    case Done{(0, (out, err))}:
      IO.pure(Res(String), Exec.token.json(cmd, J.Json.parse(out)))
    case Done{(code, (out, err))}:
      IO.pure(Res(String), Fail{(5, cmd ++ " failed: " ++ String.trim(err))})
    case Fail{(c, m)}:
      IO.pure(Res(String), Fail{(c, cmd ++ ": " ++ m)})

def Src.load(s: K.Src) -> IO(Res(String)):
  match s:
    case K.Inline{t}:
      IO.pure(Res(String), Done{t})
    case K.FromFile{+p}:
      IO.bind(Res(String), Res(String), Fs.read(p), r => Src.load.fin(p, r))
    case K.FromExec{+cmd, args}:
      IO.bind(Res(U32 & (String & String)), Res(String),
        Process.run(cmd, Strs.own(args), "", 1048576, 30000), r => Exec.token(cmd, r))
    case K.NoSrc{}:
      IO.pure(Res(String), Done{""})

# Credentials
# -----------

type Creds is Data:
  Creds{ca: String, cert: String, key: String, token: String}

def Creds.load.k(ca: String, cert: String, key: String, tok: Res(String)) -> IO(Res(Creds)):
  match tok:
    case Done{t}:
      IO.pure(Res(Creds), Done{Creds{ca, cert, key, String.trim(t)}})
    case Fail{e}:
      IO.pure(Res(Creds), Fail{e})

def Creds.load.c(ca: String, cert: String, key: Res(String), tok: K.Src) -> IO(Res(Creds)):
  match key:
    case Done{k}:
      IO.bind(Res(String), Res(Creds), Src.load(tok), t => Creds.load.k(ca, cert, k, t))
    case Fail{e}:
      IO.pure(Res(Creds), Fail{e})

def Creds.load.b(ca: String, cert: Res(String), key: K.Src, tok: K.Src) -> IO(Res(Creds)):
  match cert:
    case Done{c}:
      IO.bind(Res(String), Res(Creds), Src.load(key), k => Creds.load.c(ca, c, k, tok))
    case Fail{e}:
      IO.pure(Res(Creds), Fail{e})

def Creds.load.a(ca: Res(String), cert: K.Src, key: K.Src, tok: K.Src) -> IO(Res(Creds)):
  match ca:
    case Done{a}:
      IO.bind(Res(String), Res(Creds), Src.load(cert), c => Creds.load.b(a, c, key, tok))
    case Fail{e}:
      IO.pure(Res(Creds), Fail{e})

# Reads every secret a Config names; token files are read afresh each time.
def Creds.load(c: K.Config) -> IO(Res(Creds)):
  match c:
    case K.Config{h, p, b, ca, cert, key, tok, ns, pl, lm, sn, fc}:
      IO.bind(Res(String), Res(Creds), Src.load(ca), a => Creds.load.a(a, cert, key, tok))

def Conn.auth.go(token: String, none: Bool) -> List<&2, H.Header>:
  match none:
    case True{}:
      Nil{}
    case False{}:
      [H.Header{"Authorization", "Bearer " ++ token}]

# Connections
# -----------

def Conn.auth(+token: String) -> List<&2, H.Header>:
  Conn.auth.go(token, String.is_empty(token))

def Conn.user_agent() -> String:
  "bend-kube"

def Conn.keep(keep: Bool) -> String:
  match keep:
    case True{}:
      "keep-alive"
    case False{}:
      "close"

def Conn.connection(keep: Bool, own: Bool) -> List<&2, H.Header>:
  match own:
    case True{}:
      Nil{}
    case False{}:
      [H.Header{"Connection", Conn.keep(keep)}]

# The request's text, with the path under the server's base, our headers,
# and Connection: keep-alive (pooled) or close, unless the request names
# its own (an Upgrade).
def Conn.render(req: H.Req, +base: String, +host: String, +token: String, keep: Bool) -> String:
  match req:
    case H.Req{m, path, +hs, body}:
      H.Http.render(H.Req{m, base ++ path,
        List.append(&2, H.Header, hs, List.append(&2, H.Header, Conn.auth(token),
          Con{H.Header{"User-Agent", Conn.user_agent()},
            Conn.connection(keep, Maybe.is_some(&2, String, H.Http.find(hs, "connection")))})),
        body}, host)

def Conn.host_header.go(h: String, +p: U32, v6: Bool) -> String:
  match v6:
    case True{}:
      "[" ++ h ++ "]:" ++ U32.show(p)
    case False{}:
      h ++ ":" ++ U32.show(p)

def Conn.host_header(+h: String, +p: U32) -> String:
  Conn.host_header.go(h, p, String.contains(h, ":"))

# Opens a connection and sends req: the socket, ready to read the answer.
def Conn.open.sent(p: Socket & Res(Unit)) -> IO(Res(N.Tls)):
  match p:
    case (s, Done{u}):
      IO.pure(Res(N.Tls), Done{N.Tls{s}})
    case (s, Fail{e}):
      IO.bind(Unit, Res(N.Tls), N.Tls.close(s), u => IO.pure(Res(N.Tls), Fail{e}))

def Fence.mono() -> IO(U32):
  IO.bind(Nat, U32, IO.now(), n => IO.pure(U32, U32.from_nat(n)))

# The leadership fence: the lease's last renewal, held by a keeper the
# leader updates (Leader.fence). Under leader election every write of
# request bytes (a request's first send, a pooled send, a retry, exec's
# input) asks the keeper first, and a lease past its renew deadline exits
# the process before the bytes leave: whatever delays the leader loop (a
# long computation on the shared event loop), nothing is written after a
# standby may have taken over. The keeper always answers, so a reading is
# never missing.
def Fence.check.late(late: Bool) -> IO(Unit):
  match late:
    case True{}:
      IO.die(Unit, 1, "bend-kube: leader lease past its renew deadline; exiting before the request leaves")
    case False{}:
      IO.pure(Unit, Unit{})

def Fence.check.at(f: Maybe<&2, K.Fence>, +now: U32) -> IO(Unit):
  match f:
    case Some{K.Fence{+last, +deadline}}:
      Fence.check.late(E.Lease.late(now, last, deadline))
    case None{}:
      # no renewal yet: no controller runs before the first one
      IO.pure(Unit, Unit{})

# Reading a reply
# ---------------

# What the read loop just saw: bytes (or a failure) from a recv, or the
# decoder's state after feeding them.
type ReadEv is Type:
  RGot{sock: Socket, r: Result<&1, &1, U32 & String, List<&2, U32>>}
  RChk{sock: Socket, done: Bool, eof: Bool, bad: Bool}

def Fence.check.got(m: Maybe<&1, Maybe<&2, K.Fence>>) -> IO(Unit):
  match m:
    case Some{f}:
      IO.bind(U32, Unit, Fence.mono(), now => Fence.check.at(f, now))
    case None{}:
      IO.die(Unit, 1, "bend-kube: the leadership fence keeper is gone; exiting")

# Asks the keeper for the reading and exits if the lease is past its
# deadline; nothing to check without leader election.
def Fence.check(m: Maybe<&2, Chan(K.FenceMsg)>) -> IO(Unit):
  match m:
    case Some{+ch}:
      IO.bind(Chan(Maybe<&2, K.Fence>), Unit, Chan.new(Maybe<&2, K.Fence>, 1),
        +r => IO.bind(Result<&1, &1, K.FenceMsg, Unit>, Unit, Chan.send(K.FenceMsg, ch, K.FGet{r}),
          u => IO.bind(Maybe<&1, Maybe<&2, K.Fence>>, Unit, Chan.recv(Maybe<&2, K.Fence>, r), Fence.check.got)))
    case None{}:
      IO.pure(Unit, Unit{})

def Conn.open.go(r: Res(Socket), text: String, fc: Maybe<&2, Chan(K.FenceMsg)>) -> IO(Res(N.Tls)):
  match r:
    case Done{s}:
      IO.bind(Unit, Res(N.Tls), Fence.check(fc),
        u => IO.bind(Socket & Res(Unit), Res(N.Tls), N.Tls.send(s, text, 30000), Conn.open.sent))
    case Fail{e}:
      IO.pure(Res(N.Tls), Fail{e})

def Conn.open.creds(+h: String, +p: U32, +sn: String, +base: String, req: H.Req, keep: Bool,
  fc: Maybe<&2, Chan(K.FenceMsg)>, cr: Res(Creds)) -> IO(Res(N.Tls)):
  match cr:
    case Done{Creds{ca, cert, key, +tok}}:
      IO.bind(Res(Socket), Res(N.Tls), N.Tls.open(h, p, sn, ca, cert, key, 15000),
        r => Conn.open.go(r, Conn.render(req, base, Conn.host_header(h, p), tok, keep), fc))
    case Fail{e}:
      IO.pure(Res(N.Tls), Fail{e})

def Conn.open(+cfg: K.Config, req: H.Req, keep: Bool) -> IO(Res(N.Tls)):
  match cfg:
    case K.Config{+h, +p, +b, ca, cert, key, tok, ns, pl, lm, sn, fc}:
      IO.bind(Res(Creds), Res(N.Tls), Creds.load(cfg), cr => Conn.open.creds(h, p, sn, b, req, keep, fc, cr))

def ReadEv.got(p: Socket & Res(List<&2, U32>)) -> ReadEv:
  match p:
    case (s, r):
      RGot{s, r}

def Http.has_err(r: H.Resp) -> Bool:
  Maybe.is_some(&2, String, H.Http.error(r))

def Http.fail(msg: String) -> H.Resp:
  H.Resp{H.PErr{msg}, None{}, Nil{}}

# A failed recv: lost when no byte of a response came, else broken.
def Http.lost(r: H.Resp, msg: String) -> H.Resp:
  match r:
    case H.Resp{H.PHead{Nil{}, t}, h, o}:
      H.Resp{H.PLost{msg}, h, o}
    case _:
      Http.fail(msg)

# Reads until the response is whole, the stream ends, or fuel runs out;
# ms bounds each recv. Answers the socket and the decoder.
def Conn.read(fuel: Nat, ev: ReadEv, +resp: H.Resp, +ms: U32) -> IO(Socket & H.Resp):
  match fuel ev:
    case 0n RGot{s, r}:
      IO.pure(Socket & H.Resp, (s, Http.fail("response too long")))
    case 0n RChk{s, d, e, b}:
      IO.pure(Socket & H.Resp, (s, Http.fail("response too long")))
    case 1n+f RGot{s, Done{+bs}}:
      +next = H.Http.feed(bs, resp)
      Conn.read(f, RChk{s, H.Http.is_done(next), List.is_empty(&2, U32, bs), Http.has_err(next)},
        next, ms)
    case 1n+f RGot{s, Fail{(c, m)}}:
      IO.pure(Socket & H.Resp, (s, Http.lost(resp, "recv: " ++ m)))
    case 1n+f RChk{s, True{}, e, b}:
      IO.pure(Socket & H.Resp, (s, resp))
    case 1n+f RChk{s, False{}, True{}, b}:
      IO.pure(Socket & H.Resp, (s, H.Http.eof(resp)))
    case 1n+f RChk{s, False{}, False{}, True{}}:
      IO.pure(Socket & H.Resp, (s, resp))
    case 1n+f RChk{s, False{}, False{}, False{}}:
      IO.bind(Socket & Res(List<&2, U32>), Socket & H.Resp, N.Tls.recv(s, 65536, ms),
        p => Conn.read(f, ReadEv.got(p), resp, ms))

# Calls
# -----

# A Retry-After header in seconds (the form the API server sends); an
# HTTP-date one is left to the usual backoff.
def Reply.retry_after(m: Maybe<&2, String>) -> Maybe<&2, U32>:
  match m:
    case Some{v}:
      U32.read(String.trim(v))
    case None{}:
      None{}

def Reply.of(r: H.Resp & List<&2, U32>) -> Result<&2, &2, KErr, Reply>:
  match r:
    case (H.Resp{H.PDone{}, Some{H.Head{c, reason, +hs}}, o}, body):
      Done{Reply{c, U.Utf8.decode_all(body), Reply.retry_after(H.Http.find(hs, "retry-after"))}}
    case (H.Resp{H.PErr{m}, h, o}, body):
      Fail{KNet{0, m}}
    case (H.Resp{H.PLost{m}, h, o}, body):
      Fail{KNet{0, m}}
    case _:
      Fail{KNet{0, "incomplete response"}}

def Call.read.fin(p: Socket & H.Resp) -> IO(Result<&2, &2, KErr, Reply>):
  match p:
    case (s, r):
      IO.bind(Unit, Result<&2, &2, KErr, Reply>, N.Tls.close(s),
        u => IO.pure(Result<&2, &2, KErr, Reply>, Reply.of(H.Http.take(r))))

def Call.read(t: Res(N.Tls)) -> IO(Result<&2, &2, KErr, Reply>):
  match t:
    case Done{N.Tls{s}}:
      IO.bind(Socket & H.Resp, Result<&2, &2, KErr, Reply>,
        Conn.read(4294967295n, RChk{s, False{}, False{}, False{}}, H.Http.resp.init(), 60000),
        Call.read.fin)
    case Fail{(c, m)}:
      IO.pure(Result<&2, &2, KErr, Reply>, Fail{KNet{c, m}})

# Pooling
# -------
#
# With a pool, a request first takes an idle connection; a connection goes
# back only after a response whose end its framing marked (Content-Length
# or chunked) and that did not say Connection: close. A taken connection
# may have been closed by the server while idle: as Go's transport does,
# the request is retried once on a fresh connection when it was not
# written, or when nothing came back and its method is idempotent.

# Sends req on an open (pooled) connection.
def Conn.send_on.creds(s: Socket, +h: String, +p: U32, +base: String, req: H.Req,
  fc: Maybe<&2, Chan(K.FenceMsg)>, cr: Res(Creds)) -> IO(Res(N.Tls)):
  match cr:
    case Done{Creds{ca, cert, key, +tok}}:
      IO.bind(Unit, Res(N.Tls), Fence.check(fc),
        u => IO.bind(Socket & Res(Unit), Res(N.Tls),
          N.Tls.send(s, Conn.render(req, base, Conn.host_header(h, p), tok, True{}), 30000),
          Conn.open.sent))
    case Fail{e}:
      IO.bind(Unit, Res(N.Tls), N.Tls.close(s), u => IO.pure(Res(N.Tls), Fail{e}))

def Conn.send_on(+cfg: K.Config, s: Socket, req: H.Req) -> IO(Res(N.Tls)):
  match cfg:
    case K.Config{+h, +p, +b, ca, cert, key, tok, ns, pl, lm, sn, fc}:
      IO.bind(Res(Creds), Res(N.Tls), Creds.load(cfg), cr => Conn.send_on.creds(s, h, p, b, req, fc, cr))

def Http.got_any(r: H.Resp) -> Bool:
  match r:
    case H.Resp{H.PHead{Nil{}, t}, h, o}:
      False{}
    case H.Resp{H.PLost{m}, h, o}:
      False{}
    case _:
      True{}

type PEv is Type:
  PTook{m: Poll<&1, &1, Maybe<&1, Socket>, Unit>}
  PSent{reused: Bool, r: Result<&1, &1, U32 & String, N.Tls>}
  PRead{reused: Bool, r: Socket & H.Resp}
  PFin{sock: Socket, resp: H.Resp, keep: Bool, retry: Bool}

def Http.closes(r: H.Resp) -> Bool:
  match r:
    case H.Resp{p, Some{H.Head{c, reason, hs}}, o}:
      String.contains(String.to_lower(Maybe.default(&2, String, H.Http.find(hs, "connection"), "")),
        "close")
    case _:
      True{}

def Req.idempotent.go(m: String) -> Bool:
  match m:
    case "GET":
      True{}
    case "HEAD":
      True{}
    case "PUT":
      True{}
    case _:
      # DELETE is not replayed: if the first one landed and the name was
      # recreated, a replay would delete the replacement. The caller sees
      # the failure and reconciles (Client.delete_with can add a uid
      # precondition).
      False{}

def Req.idempotent(r: H.Req) -> Bool:
  match r:
    case H.Req{m, p, hs, b}:
      Req.idempotent.go(m)

def Pool.put.done(p: Poll<&1, &1, Result<&1, &1, Socket, Unit>, Socket>) -> IO(Unit):
  match p:
    case Ready{Done{u}}:
      IO.pure(Unit, Unit{})
    case Ready{Fail{s}}:
      N.Tls.close(s)
    case Wait{s}:
      N.Tls.close(s)

# Returns a connection to the pool; a full pool closes it instead.
def Pool.put(+pool: Chan(Socket), s: Socket) -> IO(Unit):
  IO.bind(Poll<&1, &1, Result<&1, &1, Socket, Unit>, Socket>, Unit,
    Chan.try_send(Socket, pool, s, 0), Pool.put.done)

def PEv.read(+reused: Bool, p: Socket & H.Resp) -> PEv:
  PRead{reused, p}

def PEv.fin(+reused: Bool, idem: Bool, p: Socket & H.Resp) -> PEv:
  match p:
    case (s, +r):
      PFin{s, r, Bool.and(H.Http.is_done(r), Bool.not(Http.closes(r))),
        Bool.and(reused, Bool.and(Bool.not(H.Http.is_done(r)), Bool.and(Bool.not(Http.got_any(r)), idem)))}

def Pool.reply(r: H.Resp) -> Result<&2, &2, KErr, Reply>:
  Reply.of(H.Http.take(r))

def Pool.fail(msg: String) -> IO(Result<&2, &2, KErr, Reply>):
  IO.pure(Result<&2, &2, KErr, Reply>, Fail{KNet{0, msg}})

# One request through the pool (fuel bounds the retry).
def Pool.run(fuel: Nat, ev: PEv, +cfg: K.Config, +pool: Chan(Socket), +req: H.Req) ->
  IO(Result<&2, &2, KErr, Reply>):
  match fuel ev:
    case 0n PTook{Ready{Some{s}}}:
      IO.bind(Unit, Result<&2, &2, KErr, Reply>, N.Tls.close(s), u => Pool.fail("pool: out of steps"))
    case 0n PSent{u, Done{N.Tls{s}}}:
      IO.bind(Unit, Result<&2, &2, KErr, Reply>, N.Tls.close(s), u2 => Pool.fail("pool: out of steps"))
    case 0n PRead{u, (s, r)}:
      IO.bind(Unit, Result<&2, &2, KErr, Reply>, N.Tls.close(s), u2 => Pool.fail("pool: out of steps"))
    case 0n PFin{s, r, k, t}:
      IO.bind(Unit, Result<&2, &2, KErr, Reply>, N.Tls.close(s), u2 => Pool.fail("pool: out of steps"))
    case 0n e:
      Pool.fail("pool: out of steps")
    case 1n+f PTook{Ready{Some{s}}}:
      IO.bind(Result<&1, &1, U32 & String, N.Tls>, Result<&2, &2, KErr, Reply>,
        Conn.send_on(cfg, s, req), r => Pool.run(f, PSent{True{}, r}, cfg, pool, req))
    case 1n+f PTook{m}:
      IO.bind(Result<&1, &1, U32 & String, N.Tls>, Result<&2, &2, KErr, Reply>,
        Conn.open(cfg, req, True{}), r => Pool.run(f, PSent{False{}, r}, cfg, pool, req))
    case 1n+f PSent{+reused, Done{N.Tls{s}}}:
      IO.bind(Socket & H.Resp, Result<&2, &2, KErr, Reply>,
        Conn.read(4294967295n, RChk{s, False{}, False{}, False{}}, H.Http.resp.init(), 60000),
        p => Pool.run(f, PEv.read(reused, p), cfg, pool, req))
    case 1n+f PSent{True{}, Fail{e}}:
      # a stale idle connection: the request was not written, so retry
      Pool.run(f, PTook{Wait{Unit{}}}, cfg, pool, req)
    case 1n+f PSent{False{}, Fail{(c, m)}}:
      IO.pure(Result<&2, &2, KErr, Reply>, Fail{KNet{c, m}})
    case 1n+f PRead{+reused, p}:
      Pool.run(f, PEv.fin(reused, Req.idempotent(req), p), cfg, pool, req)
    case 1n+f PFin{s, +r, True{}, t}:
      IO.bind(Unit, Result<&2, &2, KErr, Reply>, Pool.put(pool, s),
        u => IO.pure(Result<&2, &2, KErr, Reply>, Pool.reply(r)))
    case 1n+f PFin{s, r, False{}, True{}}:
      IO.bind(Unit, Result<&2, &2, KErr, Reply>, N.Tls.close(s),
        u => Pool.run(f, PTook{Wait{Unit{}}}, cfg, pool, req))
    case 1n+f PFin{s, +r, False{}, False{}}:
      IO.bind(Unit, Result<&2, &2, KErr, Reply>, N.Tls.close(s),
        u => IO.pure(Result<&2, &2, KErr, Reply>, Pool.reply(r)))

def Client.send.with(+cfg: K.Config, req: H.Req, pool: Maybe<&2, Chan(Socket)>) ->
  IO(Result<&2, &2, KErr, Reply>):
  match pool:
    case Some{+p}:
      IO.bind(Poll<&1, &1, Maybe<&1, Socket>, Unit>, Result<&2, &2, KErr, Reply>,
        Chan.try_recv(Socket, p, 0), m => Pool.run(10n, PTook{m}, cfg, p, req))
    case None{}:
      IO.bind(Res(N.Tls), Result<&2, &2, KErr, Reply>, Conn.open(cfg, req, False{}), Call.read)

# Rate limit
# ----------
#
# client-go's token bucket (flowcontrol.NewTokenBucketRateLimiter): a
# bucket holds up to burst tokens, refilled at qps a second, and every
# request but a watch waits for a token. The bucket is a channel of burst
# slots; a refiller puts tokens in, dropping those that find it full.

def Limit.fill(n: Nat, +ch: Chan(Unit)) -> IO(Unit):
  match n:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+k:
      IO.bind(Poll<&1, &1, Result<&1, &1, Unit, Unit>, Unit>, Unit, Chan.try_send(Unit, ch, Unit{}, 0),
        p => Limit.fill(k, ch))

# A tick of every ms earns qps * every / 1000 tokens; the remainder (in
# thousandths of a token) carries to the next tick, so the rate is exact.
# A tick adds at most burst tokens: the rest would find the bucket full.
def Limit.tick(+qps: U32, +every: U32, +burst: U32, +carry: U32) -> Nat:
  U32.to_nat(U32.min(((carry + qps * every) / 1000 : U32), burst))

def Limit.carry(+qps: U32, +every: U32, +carry: U32) -> U32:
  ((carry + qps * every) % 1000 : U32)

def Limit.refill(outer: Nat, fuel: Nat, +ch: Chan(Unit), +qps: U32, +every: U32, +burst: U32,
  +carry: U32) -> IO(Unit):
  match outer fuel:
    case 0n 0n:
      IO.die(Unit, 1, "bend-kube: rate limiter out of steps")
    case 1n+o 0n:
      Limit.refill(o, 4294967295n, ch, qps, every, burst, carry)
    case o 1n+f:
      IO.bind(Unit, Unit, IO.sleep(every),
        u => IO.bind(Unit, Unit, Limit.fill(Limit.tick(qps, every, burst, carry), ch),
          u2 => Limit.refill(o, f, ch, qps, every, burst, Limit.carry(qps, every, carry))))

# Ticks of 10ms, or longer for slow rates (one token a tick), at most 1s.
def Limit.every(+qps: U32) -> U32:
  U32.min(U32.max((1000 / qps : U32), 10), 1000)

# A full bucket of burst tokens, refilled at qps a second (qps above 0).
def Limit.start(+qps: U32, +burst: U32) -> IO(Chan(Unit)):
  IO.bind(Chan(Unit), Chan(Unit), Chan.new(Unit, U32.max(burst, 1)),
    +ch => IO.bind(Unit, Chan(Unit), Limit.fill(U32.to_nat(U32.max(burst, 1)), ch),
      u => IO.bind(Unit, Chan(Unit),
        IO.spawn(Unit, Limit.refill(4294967295n, 4294967295n, ch, qps, Limit.every(qps),
          U32.max(burst, 1), 0)),
        u2 => IO.pure(Chan(Unit), ch))))

def Fence.serve(outer: Nat, fuel: Nat, m: Maybe<&1, K.FenceMsg>, +cur: Maybe<&2, K.Fence>,
  +inbox: Chan(K.FenceMsg)) -> IO(Unit):
  match outer fuel m:
    case 0n 0n x:
      IO.die(Unit, 1, "bend-kube: fence keeper out of steps")
    case 1n+o 0n x:
      Fence.serve(o, 4294967295n, x, cur, inbox)
    case o 1n+f None{}:
      IO.pure(Unit, Unit{})
    case o 1n+f Some{K.FGet{r}}:
      IO.bind(Result<&1, &1, Maybe<&2, K.Fence>, Unit>, Unit, Chan.send(Maybe<&2, K.Fence>, r, cur),
        u => IO.bind(Maybe<&1, K.FenceMsg>, Unit, Chan.recv(K.FenceMsg, inbox),
          x => Fence.serve(o, f, x, cur, inbox)))
    case o 1n+f Some{K.FSet{fc}}:
      IO.bind(Maybe<&1, K.FenceMsg>, Unit, Chan.recv(K.FenceMsg, inbox),
        x => Fence.serve(o, f, x, Some{fc}, inbox))

# Starts a fence keeper with no reading yet.
def Fence.start() -> IO(Chan(K.FenceMsg)):
  IO.bind(Chan(K.FenceMsg), Chan(K.FenceMsg), Chan.new(K.FenceMsg, 4096),
    +c => IO.bind(Unit, Chan(K.FenceMsg), IO.spawn(Unit,
      IO.bind(Maybe<&1, K.FenceMsg>, Unit, Chan.recv(K.FenceMsg, c),
        x => Fence.serve(4294967295n, 4294967295n, x, None{}, c))), u => IO.pure(Chan(K.FenceMsg), c)))

def Client.send.go(+cfg: K.Config, req: H.Req) -> IO(Result<&2, &2, KErr, Reply>):
  Client.send.with(cfg, req, K.Config.pool(cfg))

def Client.send.gate(+cfg: K.Config, req: H.Req, m: Maybe<&2, Chan(Unit)>) ->
  IO(Result<&2, &2, KErr, Reply>):
  match m:
    case Some{ch}:
      IO.bind(Maybe<&1, Unit>, Result<&2, &2, KErr, Reply>, Chan.recv(Unit, ch),
        u => Client.send.go(cfg, req))
    case None{}:
      Client.send.go(cfg, req)

# Sends a request and reads the whole reply, whatever its status, after
# taking a token when the config has a rate limit.
def Client.send(+cfg: K.Config, req: H.Req) -> IO(Result<&2, &2, KErr, Reply>):
  Client.send.gate(cfg, req, K.Config.limit(cfg))

def Client.json.status.fix.go(+c: U32, +k: U32, r: String, m: String, zero: Bool) -> C.Status:
  match zero:
    case True{}:
      C.Status{c, r, m}
    case False{}:
      C.Status{k, r, m}

# A Status without a code (some proxies) takes the HTTP status.
def Client.json.status.fix(+c: U32, s: C.Status) -> C.Status:
  match s:
    case C.Status{+k, r, m}:
      Client.json.status.fix.go(c, k, r, m, U32.is_eq(k, 0))

def Client.json.err(s: C.Status, m: Maybe<&2, U32>) -> KErr:
  match m:
    case Some{n}:
      KRetry{s, n}
    case None{}:
      KApi{s}

def Client.json.or(m: Maybe<&2, U32>, h: Maybe<&2, U32>) -> Maybe<&2, U32>:
  match m:
    case Some{n}:
      Some{n}
    case None{}:
      h

# h: the Retry-After header; the Status body's details.retryAfterSeconds
# wins when both name a delay.
def Client.json.status(+c: U32, j: Result<&2, &2, String, J.Json>, ok: Bool, h: Maybe<&2, U32>) ->
  Result<&2, &2, KErr, J.Json>:
  match j ok:
    case Done{x} True{}:
      Done{x}
    case Fail{m} True{}:
      Fail{KDecode{m}}
    case Done{+x} False{}:
      Fail{Client.json.err(Client.json.status.fix(c, C.Status.of(x)),
        Client.json.or(J.Json.as_u32(J.Json.at(x, ["details", "retryAfterSeconds"])), h))}
    case Fail{m} False{}:
      Fail{Client.json.err(C.Status{c, "", "non-JSON error body"}, h)}

# A 2xx reply's body as JSON; any other status as the Status it carries.
def Client.json.of(r: Result<&2, &2, KErr, Reply>) -> Result<&2, &2, KErr, J.Json>:
  match r:
    case Done{Reply{+c, body, h}}:
      Client.json.status(c, J.Json.parse(body), Bool.and(U32.is_ge(c, 200), U32.is_lt(c, 300)), h)
    case Fail{e}:
      Fail{e}

def Client.json(+cfg: K.Config, req: H.Req) -> IO(Result<&2, &2, KErr, J.Json>):
  IO.bind(Result<&2, &2, KErr, Reply>, Result<&2, &2, KErr, J.Json>, Client.send(cfg, req),
    r => IO.pure(Result<&2, &2, KErr, J.Json>, Client.json.of(r)))

# Verbs (kube-client's Api<K>)
# -----

def Client.get(+cfg: K.Config, a: C.Api, name: String) -> IO(Result<&2, &2, KErr, J.Json>):
  Client.json(cfg, C.Req.read(a, name))

def Client.list(+cfg: K.Config, a: C.Api, lp: C.ListParams) -> IO(Result<&2, &2, KErr, J.Json>):
  Client.json(cfg, C.Req.list(a, lp))

def Client.create(+cfg: K.Config, a: C.Api, obj: J.Json) -> IO(Result<&2, &2, KErr, J.Json>):
  Client.json(cfg, C.Req.create(a, obj))

def Client.replace(+cfg: K.Config, a: C.Api, name: String, obj: J.Json) ->
  IO(Result<&2, &2, KErr, J.Json>):
  Client.json(cfg, C.Req.replace(a, name, obj))

def Client.delete(+cfg: K.Config, a: C.Api, name: String) -> IO(Result<&2, &2, KErr, J.Json>):
  Client.json(cfg, C.Req.delete(a, name))

# A delete with options: propagation, grace period, preconditions.
def Client.delete_with(+cfg: K.Config, a: C.Api, name: String, o: C.DeleteOpts) ->
  IO(Result<&2, &2, KErr, J.Json>):
  Client.json(cfg, C.Req.delete_with(a, name, o))

# Replaces the status subresource (a PUT carrying the object's
# resourceVersion, so a stale write fails with 409).
def Client.replace_status(+cfg: K.Config, a: C.Api, name: String, obj: J.Json) ->
  IO(Result<&2, &2, KErr, J.Json>):
  Client.json(cfg, C.Req.replace_status(a, name, obj))

def Client.patch(+cfg: K.Config, a: C.Api, name: String, p: C.PatchKind, body: J.Json) ->
  IO(Result<&2, &2, KErr, J.Json>):
  Client.json(cfg, C.Req.patch(a, name, "", p, body))

def Client.patch_status(+cfg: K.Config, a: C.Api, name: String, p: C.PatchKind, body: J.Json) ->
  IO(Result<&2, &2, KErr, J.Json>):
  Client.json(cfg, C.Req.patch(a, name, "status", p, body))

# Server-side apply, kube's recommended write: the server merges our fields
# under our manager name and tracks ownership.
def Client.apply(+cfg: K.Config, a: C.Api, name: String, manager: String, body: J.Json) ->
  IO(Result<&2, &2, KErr, J.Json>):
  Client.patch(cfg, a, name, C.PApply{manager, True{}}, body)

# Server-side apply that only forces when asked: without force, a field
# another manager owns (an HPA's spec.replicas) fails with 409 Conflict
# rather than being taken over.
def Client.apply_with(+cfg: K.Config, a: C.Api, name: String, manager: String, force: Bool,
  body: J.Json) -> IO(Result<&2, &2, KErr, J.Json>):
  Client.patch(cfg, a, name, C.PApply{manager, force}, body)

def Kc.rebased(r: Result<&2, &2, String, J.Json>, +path: String) -> Result<&2, &2, String, J.Json>:
  match r:
    case Done{+kc}:
      Done{K.Kube.rebase(kc, K.Kube.dir(path))}
    case Fail{e}:
      Fail{path ++ ": " ++ e}

# Configs
# -------

# Reads one kubeconfig, JSON or YAML (yaml.bend), with its relative paths
# made absolute against its own directory, as client-go does.
def Kc.parse(+t: String, +path: String, json: Bool) -> Result<&2, &2, String, J.Json>:
  match json:
    case True{}:
      Kc.rebased(J.Json.parse(t), path)
    case False{}:
      Done{K.Kube.rebase(Y.Yaml.parse(t), K.Kube.dir(path))}

def Kc.read.got(r: Res(String), +path: String) -> Result<&2, &2, String, J.Json>:
  match r:
    case Done{+t}:
      Kc.parse(t, path, String.starts_with(String.trim_start(t), "{"))
    case Fail{(c, m)}:
      Fail{m}

def Kc.read(+path: String) -> IO(Result<&2, &2, String, J.Json>):
  IO.bind(Res(String), Result<&2, &2, String, J.Json>, Fs.read(path),
    r => IO.pure(Result<&2, &2, String, J.Json>, Kc.read.got(r, path)))

# Merges the files of a KUBECONFIG list in order; a file that does not
# exist is skipped, as client-go skips it.
def Kc.merge.got(acc: Maybe<&2, J.Json>, r: Result<&2, &2, String, J.Json>) -> Maybe<&2, J.Json>:
  match acc r:
    case Some{+a} Done{+b}:
      Some{K.Kube.merge(a, b)}
    case None{} Done{b}:
      Some{b}
    case a Fail{e}:
      a

def Kc.merge(ps: List<&2, String>, acc: Maybe<&2, J.Json>) -> IO(Maybe<&2, J.Json>):
  match ps:
    case Nil{}:
      IO.pure(Maybe<&2, J.Json>, acc)
    case Con{+p, t}:
      IO.bind(Result<&2, &2, String, J.Json>, Maybe<&2, J.Json>, Kc.read(p),
        r => Kc.merge(t, Kc.merge.got(acc, r)))

def Config.from_kubeconfig.got(r: Maybe<&2, J.Json>, ctx: String) -> Result<&2, &2, String, K.Config>:
  match r:
    case Some{+kc}:
      K.Kube.config(kc, ctx)
    case None{}:
      Fail{"kubeconfig: no readable file"}

# A kubeconfig (one path, or a KUBECONFIG list "a:b") at a context ("" for
# its current one). JSON and YAML are both read natively.
def Config.from_kubeconfig(+path: String, ctx: String) -> IO(Result<&2, &2, String, K.Config>):
  IO.bind(Maybe<&2, J.Json>, Result<&2, &2, String, K.Config>,
    Kc.merge(String.split(path, ':'), None{}),
    m => IO.pure(Result<&2, &2, String, K.Config>, Config.from_kubeconfig.got(m, ctx)))

def Config.in_cluster.ns(host: String, port: String, ns: Res(String)) ->
  IO(Result<&2, &2, String, K.Config>):
  match ns:
    case Done{n}:
      IO.pure(Result<&2, &2, String, K.Config>, Done{K.InCluster.config(host, port, n)})
    case Fail{e}:
      IO.pure(Result<&2, &2, String, K.Config>, Done{K.InCluster.config(host, port, "default")})

def Config.in_cluster.port(host: String, port: Res(String)) -> IO(Result<&2, &2, String, K.Config>):
  match port:
    case Done{p}:
      IO.bind(Res(String), Result<&2, &2, String, K.Config>,
        Fs.read(K.InCluster.dir() ++ "/namespace"), n => Config.in_cluster.ns(host, p, n))
    case Fail{e}:
      IO.pure(Result<&2, &2, String, K.Config>, Fail{"KUBERNETES_SERVICE_PORT is not set"})

def Config.in_cluster.host(host: Res(String)) -> IO(Result<&2, &2, String, K.Config>):
  match host:
    case Done{h}:
      IO.bind(Res(String), Result<&2, &2, String, K.Config>,
        IO.get_env("KUBERNETES_SERVICE_PORT"), p => Config.in_cluster.port(h, p))
    case Fail{e}:
      IO.pure(Result<&2, &2, String, K.Config>, Fail{"not in a cluster"})

# The pod's own service account (client-go's InClusterConfig).
def Config.in_cluster() -> IO(Result<&2, &2, String, K.Config>):
  IO.bind(Res(String), Result<&2, &2, String, K.Config>, IO.get_env("KUBERNETES_SERVICE_HOST"),
    Config.in_cluster.host)

def Config.infer.home(r: Res(String)) -> IO(Result<&2, &2, String, K.Config>):
  match r:
    case Done{home}:
      Config.from_kubeconfig(home ++ "/.kube/config", "")
    case Fail{e}:
      IO.pure(Result<&2, &2, String, K.Config>, Fail{"no KUBECONFIG, no cluster, no HOME"})

def Config.infer.pod(r: Res(String)) -> IO(Result<&2, &2, String, K.Config>):
  match r:
    case Done{h}:
      Config.in_cluster()
    case Fail{e}:
      IO.bind(Res(String), Result<&2, &2, String, K.Config>, IO.get_env("HOME"), Config.infer.home)

def Config.infer.kc(r: Res(String)) -> IO(Result<&2, &2, String, K.Config>):
  match r:
    case Done{path}:
      Config.from_kubeconfig(path, "")
    case Fail{e}:
      IO.bind(Res(String), Result<&2, &2, String, K.Config>, IO.get_env("KUBERNETES_SERVICE_HOST"),
        Config.infer.pod)

# As kube-rs's Config::infer: $KUBECONFIG when set, else the pod's service
# account when in a cluster, else ~/.kube/config.
def Config.infer() -> IO(Result<&2, &2, String, K.Config>):
  IO.bind(Res(String), Result<&2, &2, String, K.Config>, IO.get_env("KUBECONFIG"), Config.infer.kc)
