import Base
import ./json.bend as J
import ./utf8.bend as U
import ./http.bend as H
import ./net.bend as N
import ./core.bend as C
import ./config.bend as K
import ./client.bend as Cl

# Stream
# ======
#
# A GET whose body arrives over time, such as a pod's log with
# follow=true: each cut of body bytes goes to a callback as it is decoded
# (chunked, sized, or read until close), until the body ends. A status
# other than 200 is a KApi error carrying the body's Status message. The
# connection is the stream's own, never pooled.

def Res() -> Type:
  Result<&2, &2, Cl.KErr, Unit>

# What the loop just saw: bytes (or a failure) from a recv, or the decoder
# after them with the body bytes it decoded, whether the server failed or
# the stream is over, whether the answer is 200, and whether its head came.
type SEv is Type:
  SGot{sock: Socket, resp: H.Resp, r: Result<&1, &1, U32 & String, List<&2, U32>>}
  SChk{sock: Socket, resp: H.Resp, body: List<&2, U32>, err: Maybe<&2, String>, ok: Bool,
    headed: Bool, empty: Bool, fin: Bool, code: U32}

def SEv.got(p: Socket & Result<&1, &1, U32 & String, List<&2, U32>>, resp: H.Resp) -> SEv:
  match p:
    case (s, r):
      SGot{s, resp, r}

def Stream.code(r: H.Resp) -> U32:
  match r:
    case H.Resp{p, Some{H.Head{c, reason, hs}}, out}:
      c
    case _:
      0

def Stream.check(s: Socket, +r: H.Resp, +body: List<&2, U32>, eof: Bool) -> SEv:
  SChk{s, r, body, H.Http.error(r), U32.is_eq(Stream.code(r), 200),
    Bool.not(U32.is_zero(Stream.code(r))), List.is_empty(&2, U32, body),
    Bool.or(eof, H.Http.is_done(r)), Stream.code(r)}

def Stream.taken(s: Socket, eof: Bool, rb: H.Resp & List<&2, U32>) -> SEv:
  match rb:
    case (+r, +body):
      Stream.check(s, r, body, eof)

def Stream.ended(eof: Bool, r: H.Resp) -> H.Resp:
  match eof:
    case True{}:
      H.Http.eof(r)
    case False{}:
      r

# Feeds a cut (empty at the end of the stream) and takes the body bytes it
# decoded.
def Stream.fed(s: Socket, +bs: List<&2, U32>, r: H.Resp) -> SEv:
  Stream.taken(s, List.is_empty(&2, U32, bs),
    H.Http.take(Stream.ended(List.is_empty(&2, U32, bs), H.Http.feed(bs, r))))

def Stream.message(+text: String, j: Result<&2, &2, String, J.Json>) -> String:
  match j:
    case Done{s}:
      J.Json.str_or(J.Json.at(s, ["message"]), text)
    case Fail{m}:
      text

def Stream.refused(+code: U32, +bad: List<&2, U32>) -> Cl.KErr:
  Cl.KApi{C.Status{code, "",
    Stream.message(String.trim(U.Utf8.decode_all(bad)), J.Json.parse(U.Utf8.decode_all(bad)))}}

def Stream.follow(on: Bool) -> String:
  match on:
    case True{}:
      "&follow=true"
    case False{}:
      ""

def Stream.recv(s: Socket, +ms: U32) ->
  IO(Socket & Result<&1, &1, U32 & String, List<&2, U32>>):
  N.Tls.recv(s, 65536, ms)

# Reads until the body ends; bad holds the body of a refusal. Answers the
# socket and the outcome.
def Stream.loop(~on: List<&2, U32> -> IO(Unit), fuel: Nat, ev: SEv, +bad: List<&2, U32>,
  +ms: U32) -> IO(Socket & Res()):
  match fuel ev:
    case 0n SGot{s, rp, r}:
      IO.pure(Socket & Res(), (s, Fail{Cl.KNet{0, "stream: too long"}}))
    case 0n SChk{s, r, b, er, ok, h, em, fin, c}:
      IO.pure(Socket & Res(), (s, Fail{Cl.KNet{0, "stream: too long"}}))
    case 1n+f SGot{s, rp, Done{+bs}}:
      Stream.loop(~on, f, Stream.fed(s, bs, rp), bad, ms)
    case 1n+f SGot{s, rp, Fail{(c, m)}}:
      IO.pure(Socket & Res(), (s, Fail{Cl.KNet{c, "stream: recv: " ++ m}}))
    case 1n+f SChk{s, r, b, Some{m}, ok, h, em, fin, c}:
      IO.pure(Socket & Res(), (s, Fail{Cl.KNet{0, "stream: " ++ m}}))
    case 1n+f SChk{s, +r, b, None{}, True{}, h, False{}, fin, +c}:
      IO.bind(Unit, Socket & Res(), on(b),
        u => Stream.loop(~on, f, SChk{s, r, Nil{}, None{}, True{}, True{}, True{}, fin, c}, bad,
          ms))
    case 1n+f SChk{s, r, b, None{}, True{}, h, True{}, True{}, c}:
      IO.pure(Socket & Res(), (s, Done{Unit{}}))
    case 1n+f SChk{s, +r, b, None{}, True{}, h, True{}, False{}, c}:
      IO.bind(Socket & Result<&1, &1, U32 & String, List<&2, U32>>, Socket & Res(),
        Stream.recv(s, ms), p => Stream.loop(~on, f, SEv.got(p, r), bad, ms))
    case 1n+f SChk{s, r, b, None{}, False{}, True{}, em, True{}, +c}:
      IO.pure(Socket & Res(), (s, Fail{Stream.refused(c, List.append(&2, U32, bad, b))}))
    case 1n+f SChk{s, +r, b, None{}, False{}, True{}, em, False{}, c}:
      IO.bind(Socket & Result<&1, &1, U32 & String, List<&2, U32>>, Socket & Res(),
        Stream.recv(s, ms), p => Stream.loop(~on, f, SEv.got(p, r), List.append(&2, U32, bad, b), ms))
    case 1n+f SChk{s, r, b, None{}, False{}, False{}, em, True{}, c}:
      IO.pure(Socket & Res(), (s, Fail{Cl.KNet{0, "stream: connection closed before a response"}}))
    case 1n+f SChk{s, +r, b, None{}, False{}, False{}, em, False{}, c}:
      IO.bind(Socket & Result<&1, &1, U32 & String, List<&2, U32>>, Socket & Res(),
        Stream.recv(s, ms), p => Stream.loop(~on, f, SEv.got(p, r), bad, ms))

def Stream.close(p: Socket & Res()) -> IO(Res()):
  match p:
    case (s, r):
      IO.bind(Unit, Res(), N.Tls.close(s), u => IO.pure(Res(), r))

def Stream.opened(~on: List<&2, U32> -> IO(Unit), t: Result<&1, &1, U32 & String, N.Tls>, +ms: U32) ->
  IO(Res()):
  match t:
    case Done{N.Tls{s}}:
      IO.bind(Socket & Res(), Res(),
        Stream.loop(~on, 4294967295n,
          SChk{s, H.Http.resp.init(), Nil{}, None{}, False{}, False{}, True{}, False{}, 0}, Nil{},
          ms), Stream.close)
    case Fail{(c, m)}:
      IO.pure(Res(), Fail{Cl.KNet{c, m}})

# GETs path (with its query) and hands each cut of the body to on, in
# order, until the body ends. ms bounds each wait for bytes (0: none; a
# followed log may stay quiet for long).
def Stream.get(~on: List<&2, U32> -> IO(Unit), +cfg: K.Config, path: String, +ms: U32) -> IO(Res()):
  IO.bind(Result<&1, &1, U32 & String, N.Tls>, Res(),
    Cl.Conn.open(cfg, H.Req{"GET", path, Nil{}, ""}, False{}), t => Stream.opened(~on, t, ms))

# The log of a pod's container, followed while it runs (follow=true): the
# stream ends when the container does.
def Stream.log_path(ns: String, pod: String, container: String, follow: Bool) -> String:
  "/api/v1/namespaces/" ++ H.Http.encode(ns) ++ "/pods/" ++ H.Http.encode(pod) ++
    "/log?container=" ++ H.Http.encode(container) ++ Stream.follow(follow)
