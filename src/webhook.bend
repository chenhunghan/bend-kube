import Base
import ./json.bend as J
import ./http.bend as H
import ./utf8.bend as U
import ./base64.bend as B
import ./admission.bend as A
import ./net.bend as N
import ./client.bend as Cl
import ./log.bend as L

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
# Each connection is served on its own computation, reads at most 16 MiB
# within 10s, and is closed after one answer. Webhooks answer on every
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

# One connection's events: bytes read (with the request so far), the
# request after them (whether finished, broken, too big), an answer to
# send, and its sending.
type CEv is Type:
  CRead{p: Socket & N.Res(List<&2, U32>), st: A.Rq}
  CStep{s: Socket, st: A.Rq, done: Bool, broken: Bool, big: Bool}
  CSend{s: Socket, text: String}
  CSent{p: Socket & N.Res(Unit)}

def CEv.step(s: Socket, +st: A.Rq) -> CEv:
  CStep{s, st, A.Rq.done(st), A.Rq.broken(st), U32.is_gt(A.Rq.size(st), 16777216)}

def Wh.conn(~admit: String -> J.Json -> IO(A.Verdict), ~convert: J.Json -> String -> Result<&2, &2, String, J.Json>,
  fuel: Nat, ev: CEv) -> IO(Unit):
  match fuel ev:
    case 0n CSent{(s, r)}:
      N.Tls.close(s)
    case 0n e:
      IO.pure(Unit, Unit{})
    case 1n+f CRead{(s, Done{+bs}), st}:
      Wh.conn(~admit, ~convert, f, CEv.step(s, A.Rq.feed(st, bs)))
    case 1n+f CRead{(s, Fail{e}), st}:
      N.Tls.close(s)
    case 1n+f CStep{s, +st, True{}, b, g}:
      IO.bind(String, Unit, Wh.respond(~admit, ~convert, Wh.got(st), Wh.is_post(Wh.got(st))),
        text => Wh.conn(~admit, ~convert, f, CSend{s, text}))
    case 1n+f CStep{s, st, False{}, True{}, g}:
      Wh.conn(~admit, ~convert, f, CSend{s, A.Wh.error(400, "malformed request")})
    case 1n+f CStep{s, st, False{}, False{}, True{}}:
      Wh.conn(~admit, ~convert, f, CSend{s, A.Wh.error(413, "request over 16 MiB")})
    case 1n+f CStep{s, st, False{}, False{}, False{}}:
      IO.bind(Socket & N.Res(List<&2, U32>), Unit, N.Tls.recv(s, 65536, 10000),
        p => Wh.conn(~admit, ~convert, f, CRead{p, st}))
    case 1n+f CSend{s, text}:
      IO.bind(Socket & N.Res(Unit), Unit, N.Tls.send(s, text, 10000),
        p => Wh.conn(~admit, ~convert, f, CSent{p}))
    case 1n+f CSent{(s, r)}:
      N.Tls.close(s)

def Wh.secured(~admit: String -> J.Json -> IO(A.Verdict), ~convert: J.Json -> String -> Result<&2, &2, String, J.Json>,
  r: N.Res(Socket)) -> IO(Unit):
  match r:
    case Done{s}:
      IO.bind(Socket & N.Res(List<&2, U32>), Unit, N.Tls.recv(s, 65536, 10000),
        p => Wh.conn(~admit, ~convert, 4294967295n, CRead{p, A.Rq.init()}))
    case Fail{(c, m)}:
      L.Log.warn("webhook handshake failed", [L.Log.kv("error", m)])

def Wh.keyed(~admit: String -> J.Json -> IO(A.Verdict), ~convert: J.Json -> String -> Result<&2, &2, String, J.Json>,
  sock: Socket, cert: N.Res(String), key: N.Res(String)) -> IO(Unit):
  match cert key:
    case Done{c} Done{k}:
      IO.bind(N.Res(Socket), Unit, N.Tls.accept(sock, c, k, 10000), r => Wh.secured(~admit, ~convert, r))
    case Fail{(c, m)} _:
      IO.bind(Unit, Unit, N.Tls.close(sock), u => L.Log.error("webhook certificate unreadable", [L.Log.kv("error", m)]))
    case _ Fail{(c, m)}:
      IO.bind(Unit, Unit, N.Tls.close(sock), u => L.Log.error("webhook key unreadable", [L.Log.kv("error", m)]))

# One accepted connection: the certificate and key read now (a rotated one
# is served from the next connection on), the handshake, one answer.
def Wh.serve_conn(~admit: String -> J.Json -> IO(A.Verdict), ~convert: J.Json -> String -> Result<&2, &2, String, J.Json>,
  sock: Socket, cert: String, key: String) -> IO(Unit):
  IO.bind(N.Res(String), Unit, Cl.Fs.read(cert),
    c => IO.bind(N.Res(String), Unit, Cl.Fs.read(key), k => Wh.keyed(~admit, ~convert, sock, c, k)))

type AEv is Type:
  AGot{l: Listener, r: Result<&1, &1, U32 & String, Socket>}

def AEv.got(p: Listener & N.Res(Socket)) -> AEv:
  match p:
    case (l, r):
      AGot{l, r}

def Wh.accepted(~admit: String -> J.Json -> IO(A.Verdict), ~convert: J.Json -> String -> Result<&2, &2, String, J.Json>,
  r: N.Res(Socket), +cert: String, +key: String) -> IO(Unit):
  match r:
    case Done{s}:
      IO.spawn(Unit, Wh.serve_conn(~admit, ~convert, s, cert, key))
    case Fail{e}:
      IO.pure(Unit, Unit{})

# Accepts forever (fuel permitting), serving each connection on its own.
def Wh.loop(~admit: String -> J.Json -> IO(A.Verdict), ~convert: J.Json -> String -> Result<&2, &2, String, J.Json>,
  outer: Nat, fuel: Nat, ev: AEv, +cert: String, +key: String) -> IO(Unit):
  match outer fuel ev:
    case 0n 0n AGot{l, r}:
      Listener.close(l)
    case 1n+o 0n e:
      Wh.loop(~admit, ~convert, o, 4294967295n, e, cert, key)
    case o 1n+f AGot{l, r}:
      IO.bind(Unit, Unit, Wh.accepted(~admit, ~convert, r, cert, key),
        u => IO.bind(Listener & N.Res(Socket), Unit, TCP.accept(l),
          p => Wh.loop(~admit, ~convert, o, f, AEv.got(p), cert, key)))

def Wh.listening(~admit: String -> J.Json -> IO(A.Verdict), ~convert: J.Json -> String -> Result<&2, &2, String, J.Json>,
  r: N.Res(Listener), +port: U32, +cert: String, +key: String) -> IO(Unit):
  match r:
    case Done{l}:
      IO.bind(Unit, Unit, L.Log.info("webhooks serving", [L.Log.kv("port", U32.show(port)), L.Log.kv("cert", cert)]),
        u => IO.bind(Listener & N.Res(Socket), Unit, TCP.accept(l),
          p => Wh.loop(~admit, ~convert, 4294967295n, 4294967295n, AEv.got(p), cert, key)))
    case Fail{(c, m)}:
      IO.die(Unit, 1, "bend-kube: webhook server cannot listen: " ++ m)

# Serves admission and conversion webhooks over HTTPS on 0.0.0.0:port,
# with the PEM certificate and key at the paths cert and key (a mounted
# Secret, such as cert-manager's tls.crt and tls.key). admit(path,
# request) answers AdmissionReviews; convert(obj, apiVersion)
# ConversionReviews. Runs until the process exits.
def Webhook.serve(~admit: String -> J.Json -> IO(A.Verdict), ~convert: J.Json -> String -> Result<&2, &2, String, J.Json>,
  +port: U32, +cert: String, +key: String) -> IO(Unit):
  IO.bind(N.Res(Listener), Unit, TCP.listen("0.0.0.0", port), r => Wh.listening(~admit, ~convert, r, port, cert, key))

# A server with no conversion: a ConversionReview fails every object.
def Webhook.no_convert(o: J.Json, to: String) -> Result<&2, &2, String, J.Json>:
  Fail{"no conversion webhook here"}

# Admission webhooks only (Webhook.serve with Webhook.no_convert).
def Webhook.admission(~admit: String -> J.Json -> IO(A.Verdict), +port: U32, +cert: String, +key: String) -> IO(Unit):
  Webhook.serve(~admit, ~Webhook.no_convert, port, cert, key)
