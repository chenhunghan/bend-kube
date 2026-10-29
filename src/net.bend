import Base
import ./proxy.bend as P

# Net
# ===
#
# A TLS connection is a Socket handle wrapped in Tls, so code typed against
# Tls can never hand it to the raw TCP effects. The effects (effs/tls.c on
# native builds, effs/tls.js on the JavaScript lane) only dial, handshake
# and move bytes; every decision about proxies is proxy.bend's, here.

type Tls is Type:
  Tls{sock: Socket}

type Bytes is Data:
  Bytes{list: List<&2, U32>}

def Res(-A: Type) -> Type:
  Result<&1, &1, U32 & String, A>

# Effects
# -------

# A plain TCP connection: host may be a name (resolved, IPv4 or IPv6) or an
# IP literal; ms bounds the connect (0 for 30s). Until Tls.secure, Tls.send
# and Tls.recv carry its bytes as they are.
def Tls.dial(host: String, port: U32, ms: U32) -> IO(Res(Socket)):
  import "./effs/tls.c"
  import "./effs/tls.js"

# Handshakes on a connection from Tls.dial and verifies the server as host
# (a name, or an IP literal), always: ca is a PEM bundle of trusted roots
# ("" for the system's), cert and key a PEM client certificate and key (""
# for none), ms the handshake's deadline (0 for 30s). TLS 1.2 or later. A
# failure closes the connection.
def Tls.secure(sock: Socket, host: String, ca: String, cert: String, key: String, ms: U32) ->
  IO(Res(Socket)):
  import "./effs/tls.c"
  import "./effs/tls.js"

# Sends text as UTF-8; ms bounds the whole send (0: no deadline).
def Tls.send(sock: Socket, text: String, ms: U32) -> IO(Socket & Res(Unit)):
  import "./effs/tls.c"
  import "./effs/tls.js"

# Up to max bytes (0: 16KiB); an empty list is the end of the stream. ms
# bounds the wait (0: none), past which it fails with ETIMEDOUT (60).
def Tls.recv(sock: Socket, max: U32, ms: U32) -> IO(Socket & Res(List<&2, U32>)):
  import "./effs/tls.c"
  import "./effs/tls.js"

def Tls.close(sock: Socket) -> IO(Unit):
  import "./effs/tls.c"
  import "./effs/tls.js"

# Opening
# -------

def Tls.fail(s: Socket, e: U32 & String) -> IO(Res(Socket)):
  IO.bind(Unit, Res(Socket), Tls.close(s), u => IO.pure(Res(Socket), Fail{e}))

# What the CONNECT exchange just saw.
type TunEv is Type:
  TGot{sock: Socket, r: Res(List<&2, U32>), st: P.Tunnel}
  TStep{sock: Socket, st: P.Tunnel}

def TunEv.got(p: Socket & Res(List<&2, U32>), st: P.Tunnel) -> TunEv:
  match p:
    case (s, r):
      TGot{s, r, st}

# Reads the proxy's answer to CONNECT; once it opens the tunnel, secures
# the connection end to end with the API server.
def Tls.tunnel(fuel: Nat, ev: TunEv, +host: String, ca: String, cert: String, key: String,
  +ms: U32) -> IO(Res(Socket)):
  match fuel ev:
    case 0n TGot{s, r, st}:
      Tls.fail(s, (0, "proxy: answer too long"))
    case 0n TStep{s, st}:
      Tls.fail(s, (0, "proxy: answer too long"))
    case 1n+f TGot{s, Done{bs}, st}:
      Tls.tunnel(f, TStep{s, P.Tunnel.feed(st, bs)}, host, ca, cert, key, ms)
    case 1n+f TGot{s, Fail{(c, m)}, st}:
      Tls.fail(s, (c, "proxy: " ++ m))
    case 1n+f TStep{s, P.TMore{h}}:
      IO.bind(Socket & Res(List<&2, U32>), Res(Socket), Tls.recv(s, 4096, ms),
        p => Tls.tunnel(f, TunEv.got(p, P.TMore{h}), host, ca, cert, key, ms))
    case 1n+f TStep{s, P.TOpen{}}:
      Tls.secure(s, host, ca, cert, key, ms)
    case 1n+f TStep{s, P.TFail{why}}:
      Tls.fail(s, (0, why))

def Tls.open.sent(p: Socket & Res(Unit), +host: String, ca: String, cert: String, key: String,
  +ms: U32) -> IO(Res(Socket)):
  match p:
    case (s, Done{u}):
      Tls.tunnel(4294967295n, TStep{s, P.Tunnel.init()}, host, ca, cert, key, ms)
    case (s, Fail{(c, m)}):
      Tls.fail(s, (c, "proxy: " ++ m))

def Tls.open.proxied(d: Res(Socket), req: String, +host: String, ca: String, cert: String,
  key: String, +ms: U32) -> IO(Res(Socket)):
  match d:
    case Done{s}:
      IO.bind(Socket & Res(Unit), Res(Socket), Tls.send(s, req, ms),
        p => Tls.open.sent(p, host, ca, cert, key, ms))
    case Fail{(c, m)}:
      IO.pure(Res(Socket), Fail{(c, "proxy: " ++ m)})

def Tls.open.direct(d: Res(Socket), +host: String, ca: String, cert: String, key: String,
  +ms: U32) -> IO(Res(Socket)):
  match d:
    case Done{s}:
      Tls.secure(s, host, ca, cert, key, ms)
    case Fail{e}:
      IO.pure(Res(Socket), Fail{e})

def Tls.open.route(r: P.Route, +host: String, +port: U32, ca: String, cert: String,
  key: String, +ms: U32) -> IO(Res(Socket)):
  match r:
    case P.Direct{}:
      IO.bind(Res(Socket), Res(Socket), Tls.dial(host, port, ms),
        d => Tls.open.direct(d, host, ca, cert, key, ms))
    case P.Via{P.Proxy{ph, pp, auth}}:
      IO.bind(Res(Socket), Res(Socket), Tls.dial(ph, pp, ms),
        d => Tls.open.proxied(d, P.Proxy.connect(host, port, auth), host, ca, cert, key, ms))
    case P.NoRoute{why}:
      IO.pure(Res(Socket), Fail{(22, why)})

def Tls.env.or(r: Res(String), alt: Res(String)) -> String:
  match r alt:
    case Done{SCon{c, t}} a:
      SCon{c, t}
    case _ Done{v}:
      v
    case _ _:
      ""

# The first of two environment variables that is set and not empty, as Go
# reads HTTPS_PROXY then https_proxy.
def Tls.env(name: String, alt: String) -> IO(String):
  IO.bind(Res(String), String, IO.get_env(name),
    r => IO.bind(Res(String), String, IO.get_env(alt), a => IO.pure(String, Tls.env.or(r, a))))

# Opens a verified TLS connection to host:port (see Tls.secure), through
# the CONNECT tunnel of HTTPS_PROXY unless NO_PROXY or a loopback host
# says otherwise (proxy.bend).
def Tls.open(+host: String, +port: U32, ca: String, cert: String, key: String, +ms: U32) ->
  IO(Res(Socket)):
  IO.bind(String, Res(Socket), Tls.env("HTTPS_PROXY", "https_proxy"),
    url => IO.bind(String, Res(Socket), Tls.env("NO_PROXY", "no_proxy"),
      no => Tls.open.route(P.Proxy.route(url, no, host, port), host, port, ca, cert, key, ms)))
