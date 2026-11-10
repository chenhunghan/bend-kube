import Base
import ./json.bend as J
import ./http.bend as H
import ./utf8.bend as U
import ./base64.bend as B
import ./admission.bend as A
import ./net.bend as N
import ./client.bend as Cl
import ./log.bend as L
import ./sys.bend as Y

# Webhooks
# ========
#
# Admission and conversion webhooks (controller-runtime's webhook server)
# over HTTPS: the API server POSTs an AdmissionReview or a ConversionReview
# and reads the answer. One server takes both; it tells them apart by the
# review's kind, so any path works, and hands the path to the admission
# handler, which can route on it ("/validate-websites", "/mutate-pods").
#
# - admit(path, request) answers a Verdict: allowed or denied (with a code
#   and message), with optional JSON-patch operations (a mutation) and
#   warnings. It may read the API server or caches (IO).
# - convert(obj, apiVersion) is pure: the object in the desired version,
#   or why it cannot be.
#
# The certificate and key are PEM files, read again for every connection,
# so a rotated certificate (cert-manager's) is served without a restart.
# Each connection is served on its own computation, at most 256 at once
# (more are closed as they arrive); it reads at most 8 MiB (a larger
# Content-Length is refused before its body is read), waits at most 10s
# for any read, lives at most 30s from its accept, and is closed after
# one answer or when the peer stops sending. Webhooks answer on every
# replica, leader or not: start the server before Kube.control (IO.spawn),
# not inside it. Native lane only (Tls.accept).

# Serving
# -------

def Wh.admitted(+av: String, +uid: String, v: A.Verdict) -> IO(String):
  IO.pure(String, A.Wh.reply(200, J.Json.show(A.Wh.admission_review(av, uid, v))))

# The answer to a review.
def Wh.answer(~admit: String -> J.Json -> IO(A.Verdict), ~convert: J.Json -> String -> Result<&2, &2, String, J.Json>,
  +path: String, k: A.Review) -> IO(String):
  match k:
    case A.KAdmission{+j}:
      IO.bind(A.Verdict, String, admit(path, J.Json.get(j, "request")),
        v => Wh.admitted(J.Json.str_or(J.Json.get(j, "apiVersion"), "admission.k8s.io/v1"),
          J.Json.str_or(J.Json.at(j, ["request", "uid"]), ""), v))
    case A.KConversion{+j}:
      IO.pure(String, A.Wh.reply(200, J.Json.show(A.Wh.conversion_review(~convert, j))))
    case A.KBad{m}:
      IO.pure(String, A.Wh.error(400, m))

def Wh.respond(~admit: String -> J.Json -> IO(A.Verdict), ~convert: J.Json -> String -> Result<&2, &2, String, J.Json>,
  g: A.Got, post: Bool) -> IO(String):
  match g post:
    case A.Got{m, +p, b} True{}:
      Wh.answer(~admit, ~convert, p, A.Review.of(b))
    case A.Got{m, p, b} False{}:
      IO.pure(String, A.Wh.error(405, "POST a review"))

def Wh.got(+st: A.Rq) -> A.Got:
  A.Rq.got(st)

def Wh.is_post(g: A.Got) -> Bool:
  match g:
    case A.Got{m, p, b}:
      String.eq(m, "POST")

# Limits: open connections at once (more are closed as they arrive), the
# whole life of one connection from its accept (handshake, request and
# answer), and the wait for any one read or send.
def Wh.max_conns() -> U32:
  256

def Wh.life_ms() -> U32:
  30000

def Wh.read_ms() -> U32:
  10000

def Wh.mono() -> IO(U32):
  IO.bind(Nat, U32, IO.now(), n => IO.pure(U32, U32.from_nat(n)))

# How long the next read or send may wait: what is left of the
# connection's life (0 once it is over), at most Wh.read_ms.
def Wh.left.go(+left: U32, over: Bool) -> U32:
  match over:
    case True{}:
      0
    case False{}:
      U32.min(left, Wh.read_ms())

def Wh.left(+dl: U32, +now: U32) -> U32:
  Wh.left.go((dl - now : U32), Bool.or(U32.is_ge(now, dl), U32.is_ge((dl - now : U32), 2147483648)))

# One connection's events: bytes read (with the request so far), the
# request after them (finished, broken, too big, or the peer done
# sending), the clock read before the next read, an answer to send, and
# its sending.
type CEv is Type:
  CRead{p: Socket & N.Res(List<&2, U32>), st: A.Rq}
  CStep{s: Socket, st: A.Rq, done: Bool, broken: Bool, big: Bool, eof: Bool}
  CWait{s: Socket, st: A.Rq, left: U32}
  CSend{s: Socket, text: String}
  CSent{p: Socket & N.Res(Unit)}

def CEv.step(s: Socket, +st: A.Rq, eof: Bool) -> CEv:
  CStep{s, st, A.Rq.done(st), A.Rq.broken(st), A.Rq.too_big(st, A.Rq.max_bytes()), eof}

def Wh.conn(~admit: String -> J.Json -> IO(A.Verdict), ~convert: J.Json -> String -> Result<&2, &2, String, J.Json>,
  fuel: Nat, ev: CEv, +dl: U32) -> IO(Unit):
  match fuel ev:
    case 0n CSent{(s, r)}:
      N.Tls.close(s)
    case 0n CRead{(s, r), st}:
      N.Tls.close(s)
    case 0n CStep{s, st, d, b, g, e}:
      N.Tls.close(s)
    case 0n CWait{s, st, l}:
      N.Tls.close(s)
    case 0n CSend{s, t}:
      N.Tls.close(s)
    case 1n+f CRead{(s, Done{+bs}), st}:
      Wh.conn(~admit, ~convert, f, CEv.step(s, A.Rq.feed(st, bs), List.is_empty(&2, U32, bs)), dl)
    case 1n+f CRead{(s, Fail{e}), st}:
      N.Tls.close(s)
    case 1n+f CStep{s, +st, True{}, b, g, e}:
      IO.bind(String, Unit, Wh.respond(~admit, ~convert, Wh.got(st), Wh.is_post(Wh.got(st))),
        text => Wh.conn(~admit, ~convert, f, CSend{s, text}, dl))
    case 1n+f CStep{s, st, False{}, True{}, g, e}:
      Wh.conn(~admit, ~convert, f, CSend{s, A.Wh.error(400, "malformed request")}, dl)
    case 1n+f CStep{s, st, False{}, False{}, True{}, e}:
      Wh.conn(~admit, ~convert, f, CSend{s, A.Wh.error(413, "request over " ++ U32.show(A.Rq.max_bytes()) ++ " bytes")}, dl)
    case 1n+f CStep{s, st, False{}, False{}, False{}, True{}}:
      # the peer stopped sending before the request was whole
      N.Tls.close(s)
    case 1n+f CStep{s, st, False{}, False{}, False{}, False{}}:
      IO.bind(U32, Unit, Wh.mono(), now => Wh.conn(~admit, ~convert, f, CWait{s, st, Wh.left(dl, now)}, dl))
    case 1n+f CWait{s, st, 0}:
      # the connection's life is over
      N.Tls.close(s)
    case 1n+f CWait{s, st, +l}:
      IO.bind(Socket & N.Res(List<&2, U32>), Unit, N.Tls.recv(s, 65536, l),
        p => Wh.conn(~admit, ~convert, f, CRead{p, st}, dl))
    case 1n+f CSend{s, text}:
      IO.bind(Socket & N.Res(Unit), Unit, N.Tls.send(s, text, Wh.read_ms()),
        p => Wh.conn(~admit, ~convert, f, CSent{p}, dl))
    case 1n+f CSent{(s, r)}:
      N.Tls.close(s)

def Wh.secured(~admit: String -> J.Json -> IO(A.Verdict), ~convert: J.Json -> String -> Result<&2, &2, String, J.Json>,
  r: N.Res(Socket), +dl: U32) -> IO(Unit):
  match r:
    case Done{s}:
      Wh.conn(~admit, ~convert, 4294967295n, CStep{s, A.Rq.init(), False{}, False{}, False{}, False{}}, dl)
    case Fail{(c, m)}:
      L.Log.warn("webhook handshake failed", [L.Log.kv("error", m)])

def Wh.keyed(~admit: String -> J.Json -> IO(A.Verdict), ~convert: J.Json -> String -> Result<&2, &2, String, J.Json>,
  sock: Socket, cert: N.Res(String), key: N.Res(String), +dl: U32) -> IO(Unit):
  match cert key:
    case Done{c} Done{k}:
      IO.bind(N.Res(Socket), Unit, N.Tls.accept(sock, c, k, Wh.read_ms()), r => Wh.secured(~admit, ~convert, r, dl))
    case Fail{(c, m)} _:
      IO.bind(Unit, Unit, N.Tls.close(sock), u => L.Log.error("webhook certificate unreadable", [L.Log.kv("error", m)]))
    case _ Fail{(c, m)}:
      IO.bind(Unit, Unit, N.Tls.close(sock), u => L.Log.error("webhook key unreadable", [L.Log.kv("error", m)]))

# One accepted connection: the certificate and key read now (a rotated one
# is served from the next connection on), the handshake, one answer, all
# within Wh.life_ms of the accept.
def Wh.serve_conn(~admit: String -> J.Json -> IO(A.Verdict), ~convert: J.Json -> String -> Result<&2, &2, String, J.Json>,
  sock: Socket, cert: String, key: String) -> IO(Unit):
  IO.bind(U32, Unit, Wh.mono(),
    t0 => IO.bind(N.Res(String), Unit, Cl.Fs.read(cert),
      c => IO.bind(N.Res(String), Unit, Cl.Fs.read(key),
        k => Wh.keyed(~admit, ~convert, sock, c, k, (t0 + Wh.life_ms() : U32)))))

# A connection holds one of Wh.max_conns tokens while it is served, and
# gives it back on every way out.
def Wh.held(~admit: String -> J.Json -> IO(A.Verdict), ~convert: J.Json -> String -> Result<&2, &2, String, J.Json>,
  sock: Socket, +cert: String, +key: String, +slots: Chan(Unit)) -> IO(Unit):
  IO.bind(Unit, Unit, Wh.serve_conn(~admit, ~convert, sock, cert, key),
    u => IO.bind(Poll<&1, &1, Result<&1, &1, Unit, Unit>, Unit>, Unit, Chan.try_send(Unit, slots, Unit{}, 0),
      p => IO.pure(Unit, Unit{})))

def Wh.slot(~admit: String -> J.Json -> IO(A.Verdict), ~convert: J.Json -> String -> Result<&2, &2, String, J.Json>,
  sock: Socket, +cert: String, +key: String, +slots: Chan(Unit), p: Poll<&1, &1, Maybe<&1, Unit>, Unit>) -> IO(Unit):
  match p:
    case Ready{Some{u}}:
      IO.spawn(Unit, Wh.held(~admit, ~convert, sock, cert, key, slots))
    case _:
      # every slot is taken: refuse this one rather than queue it
      N.Tls.close(sock)

type AEv is Type:
  AGot{l: Listener, r: Result<&1, &1, U32 & String, Socket>}

def AEv.got(p: Listener & N.Res(Socket)) -> AEv:
  match p:
    case (l, r):
      AGot{l, r}

def Wh.accepted(~admit: String -> J.Json -> IO(A.Verdict), ~convert: J.Json -> String -> Result<&2, &2, String, J.Json>,
  r: N.Res(Socket), +cert: String, +key: String, +slots: Chan(Unit)) -> IO(Unit):
  match r:
    case Done{s}:
      IO.bind(Poll<&1, &1, Maybe<&1, Unit>, Unit>, Unit, Chan.try_recv(Unit, slots, 0),
        p => Wh.slot(~admit, ~convert, s, cert, key, slots, p))
    case Fail{(c, m)}:
      # out of descriptors (EMFILE) and the like: the listener stays
      # readable, so wait before accepting again rather than spin
      IO.bind(Unit, Unit, L.Log.warn("webhook accept failed; pausing", [L.Log.kv("error", m)]),
        u => IO.sleep(200))

# Accepts forever (fuel permitting), serving each connection on its own.
def Wh.loop(~admit: String -> J.Json -> IO(A.Verdict), ~convert: J.Json -> String -> Result<&2, &2, String, J.Json>,
  outer: Nat, fuel: Nat, ev: AEv, +cert: String, +key: String, +slots: Chan(Unit)) -> IO(Unit):
  match outer fuel ev:
    case 0n 0n AGot{l, r}:
      Listener.close(l)
    case 1n+o 0n e:
      Wh.loop(~admit, ~convert, o, 4294967295n, e, cert, key, slots)
    case o 1n+f AGot{l, r}:
      IO.bind(Unit, Unit, Wh.accepted(~admit, ~convert, r, cert, key, slots),
        u => IO.bind(Listener & N.Res(Socket), Unit, TCP.accept(l),
          p => Wh.loop(~admit, ~convert, o, f, AEv.got(p), cert, key, slots)))

def Wh.fill(+c: Chan(Unit), n: Nat) -> IO(Unit):
  match n:
    case 0n:
      IO.pure(Unit, Unit{})
    case 1n+k:
      IO.bind(Poll<&1, &1, Result<&1, &1, Unit, Unit>, Unit>, Unit, Chan.try_send(Unit, c, Unit{}, 0),
        p => Wh.fill(c, k))

# Wh.max_conns tokens.
def Wh.slots() -> IO(Chan(Unit)):
  IO.bind(Chan(Unit), Chan(Unit), Chan.new(Unit, Wh.max_conns()),
    +c => IO.bind(Unit, Chan(Unit), Wh.fill(c, U32.to_nat(Wh.max_conns())), u => IO.pure(Chan(Unit), c)))

def Wh.listening(~admit: String -> J.Json -> IO(A.Verdict), ~convert: J.Json -> String -> Result<&2, &2, String, J.Json>,
  r: N.Res(Listener), +port: U32, +cert: String, +key: String) -> IO(Unit):
  match r:
    case Done{l}:
      IO.bind(Unit, Unit, L.Log.info("webhooks serving", [L.Log.kv("port", U32.show(port)), L.Log.kv("cert", cert)]),
        u => IO.bind(Chan(Unit), Unit, Wh.slots(),
          +slots => IO.bind(Listener & N.Res(Socket), Unit, TCP.accept(l),
            p => Wh.loop(~admit, ~convert, 4294967295n, 4294967295n, AEv.got(p), cert, key, slots))))
    case Fail{(c, m)}:
      IO.die(Unit, 1, "bend-kube: webhook server cannot listen: " ++ m)

# Serves admission and conversion webhooks over HTTPS on port (every
# address, IPv6 and IPv4, where the host has IPv6: Y.Sys.listen),
# with the PEM certificate and key at the paths cert and key (a mounted
# Secret, such as cert-manager's tls.crt and tls.key). admit(path,
# request) answers AdmissionReviews; convert(obj, apiVersion)
# ConversionReviews. Runs until the process exits.
def Webhook.serve(~admit: String -> J.Json -> IO(A.Verdict), ~convert: J.Json -> String -> Result<&2, &2, String, J.Json>,
  +port: U32, +cert: String, +key: String) -> IO(Unit):
  IO.bind(N.Res(Listener), Unit, Y.Sys.listen(port), r => Wh.listening(~admit, ~convert, r, port, cert, key))

# A server with no conversion: a ConversionReview fails every object.
def Webhook.no_convert(o: J.Json, to: String) -> Result<&2, &2, String, J.Json>:
  Fail{"no conversion webhook here"}

# Admission webhooks only (Webhook.serve with Webhook.no_convert).
def Webhook.admission(~admit: String -> J.Json -> IO(A.Verdict), +port: U32, +cert: String, +key: String) -> IO(Unit):
  Webhook.serve(~admit, ~Webhook.no_convert, port, cert, key)
