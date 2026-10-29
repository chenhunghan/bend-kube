import Base
import ./utf8.bend as U
import ./base64.bend as B
import ./config.bend as K

# Proxy
# =====
#
# Whether and how a connection to the API server goes through a proxy, as
# client-go decides it (Go's http.ProxyFromEnvironment): HTTPS_PROXY names
# an http:// proxy, optionally with user:password; NO_PROXY lists what
# bypasses it. Through a proxy, the connection is a CONNECT tunnel, and TLS
# (with its verification) still runs end to end with the API server.
#
# Pure: net.bend reads the environment, dials, and feeds the proxy's answer
# to Tunnel; the effects never decide anything about proxies.

type Proxy is Data:
  Proxy{host: String, port: U32, auth: String}

# auth is the Basic credential (base64 of "user:password"), "" for none.
type Route is Data:
  Direct{}
  Via{proxy: Proxy}
  NoRoute{why: String}

# IPv4
# ----

def Ip4.octet.if(+v: U32, ok: Bool) -> Maybe<&2, U32>:
  match ok:
    case True{}:
      Some{v}
    case False{}:
      None{}

def Ip4.octet.go(m: Maybe<&2, U32>) -> Maybe<&2, U32>:
  match m:
    case Some{+v}:
      Ip4.octet.if(v, U32.is_le(v, 255))
    case None{}:
      None{}

def Ip4.octet(s: String) -> Maybe<&2, U32>:
  Ip4.octet.go(U32.read(s))

def Ip4.join(a: Maybe<&2, U32>, b: Maybe<&2, U32>, c: Maybe<&2, U32>, d: Maybe<&2, U32>) ->
  Maybe<&2, U32>:
  match a b c d:
    case Some{w} Some{x} Some{y} Some{z}:
      Some{U32.add(U32.mul(U32.add(U32.mul(U32.add(U32.mul(w, 256), x), 256), y), 256), z)}
    case _ _ _ _:
      None{}

def Ip4.parse.go(ps: List<&2, String>) -> Maybe<&2, U32>:
  match ps:
    case Con{a, Con{b, Con{c, Con{d, Nil{}}}}}:
      Ip4.join(Ip4.octet(a), Ip4.octet(b), Ip4.octet(c), Ip4.octet(d))
    case _:
      None{}

# "10.1.2.3" as a number, if it is a dotted IPv4 address.
def Ip4.parse(s: String) -> Maybe<&2, U32>:
  Ip4.parse.go(String.split(s, '.'))

def Ip4.is_loopback(m: Maybe<&2, U32>) -> Bool:
  match m:
    case Some{v}:
      U32.is_eq(U32.shrn(v, 24n), 127)
    case None{}:
      False{}

# The mask of a prefix length; None past 32.
def Ip4.mask.go(+bits: U32, ok: Bool) -> Maybe<&2, U32>:
  match ok:
    case True{}:
      Some{U32.shln(4294967295, U32.to_nat(U32.sub(32, bits)))}
    case False{}:
      None{}

def Ip4.mask(+bits: U32) -> Maybe<&2, U32>:
  Ip4.mask.go(bits, U32.is_le(bits, 32))

def Ip4.in(h: Maybe<&2, U32>, n: Maybe<&2, U32>, m: Maybe<&2, U32>) -> Bool:
  match h n m:
    case Some{x} Some{y} Some{+k}:
      U32.is_eq(U32.and(x, k), U32.and(y, k))
    case _ _ _:
      False{}

def Ip4.mask.of(m: Maybe<&2, U32>) -> Maybe<&2, U32>:
  match m:
    case Some{+b}:
      Ip4.mask(b)
    case None{}:
      None{}

def Ip4.cidr.go(h: String, parts: List<&2, String>) -> Bool:
  match parts:
    case Con{n, Con{b, Nil{}}}:
      Ip4.in(Ip4.parse(h), Ip4.parse(n), Ip4.mask.of(U32.read(b)))
    case _:
      False{}

# Whether IPv4 host h lies in the "net/bits" block.
def Ip4.cidr(h: String, block: String) -> Bool:
  Ip4.cidr.go(h, String.split(block, '/'))

# NO_PROXY
# --------
#
# Entries are separated by commas or spaces. "*" bypasses every host; an
# IPv4 CIDR bypasses the addresses in it; "name" bypasses the name and its
# subdomains, ".name" (or "*.name") only its subdomains; ":port" on an entry
# narrows it to that port. Hosts compare in lower case.

# An entry, split from its port ("" for any).
type Ent is Data:
  Ent{host: String, port: String}

def Ent.of.go(parts: List<&2, String>, +item: String) -> Ent:
  match parts:
    case Con{h, Con{p, Nil{}}}:
      Ent{h, p}
    case _:
      Ent{item, ""}

def Ent.of(+item: String) -> Ent:
  Ent.of.go(String.split(item, ':'), item)

def NoProxy.star(e: String) -> String:
  match e:
    case SCon{'*', SCon{'.', t}}:
      SCon{'.', t}
    case x:
      x

def NoProxy.name.go(+e: String, +host: String, dot: Bool) -> Bool:
  match dot:
    case True{}:
      String.ends_with(host, e)
    case False{}:
      Bool.or(String.eq(host, e), String.ends_with(host, "." ++ e))

def NoProxy.name(+e: String, +host: String) -> Bool:
  NoProxy.name.go(e, host, String.starts_with(e, "."))

def NoProxy.port_ok(+want: String, +port: U32) -> Bool:
  Bool.or(String.is_empty(want), String.eq(want, U32.show(port)))

def NoProxy.ent(e: Ent, +host: String, +port: U32) -> Bool:
  match e:
    case Ent{+h, +p}:
      Bool.and(NoProxy.port_ok(p, port),
        Bool.or(Ip4.cidr(host, h), NoProxy.name(NoProxy.star(h), host)))

def NoProxy.hit.go(+host: String, +port: U32, +item: String, star: Bool) -> Bool:
  match star:
    case True{}:
      True{}
    case False{}:
      NoProxy.ent(Ent.of(item), host, port)

def NoProxy.hit(+host: String, +port: U32, +item: String) -> Bool:
  NoProxy.hit.go(host, port, item, String.eq(item, "*"))

def NoProxy.any(xs: List<&2, String>, +host: String, +port: U32) -> Bool:
  match xs:
    case Nil{}:
      False{}
    case Con{x, t}:
      Bool.or(NoProxy.hit(host, port, x), NoProxy.any(t, host, port))

def NoProxy.commas(s: String) -> String:
  match s:
    case SNil{}:
      SNil{}
    case SCon{' ', t}:
      SCon{',', NoProxy.commas(t)}
    case SCon{c, t}:
      SCon{c, NoProxy.commas(t)}

# Whether NO_PROXY (no) sends host:port around the proxy.
def NoProxy.bypass(no: String, +host: String, +port: U32) -> Bool:
  NoProxy.any(String.split(String.to_lower(NoProxy.commas(no)), ','), host, port)

# Proxy URLs
# ----------

def Pct.hex.go(+c: U32, d: Bool, up: Bool, low: Bool) -> U32:
  match d up low:
    case True{} _ _:
      U32.sub(c, 48)
    case _ True{} _:
      U32.sub(c, 55)
    case _ _ True{}:
      U32.sub(c, 87)
    case _ _ _:
      16

# A hex digit's value, 16 for any other character.
def Pct.hex(+c: U32) -> U32:
  Pct.hex.go(c, Bool.and(U32.is_ge(c, 48), U32.is_le(c, 57)),
    Bool.and(U32.is_ge(c, 65), U32.is_le(c, 70)), Bool.and(U32.is_ge(c, 97), U32.is_le(c, 102)))

def Pct.esc.if(+a: Char, +b: Char, +hi: U32, +lo: U32, rest: List<&2, U32>, ok: Bool) ->
  List<&2, U32>:
  match ok:
    case True{}:
      Con{U32.add(U32.mul(hi, 16), lo), rest}
    case False{}:
      Con{37, U.Utf8.put(Char.to_u32(a), U.Utf8.put(Char.to_u32(b), rest))}

def Pct.esc(+a: Char, +b: Char, rest: List<&2, U32>) -> List<&2, U32>:
  +hi = Pct.hex(Char.to_u32(a))
  +lo = Pct.hex(Char.to_u32(b))
  Pct.esc.if(a, b, hi, lo, rest, Bool.and(U32.is_lt(hi, 16), U32.is_lt(lo, 16)))

# The bytes of a percent-encoded URL part ("%40" is '@'); a '%' that starts
# no escape stays as it is.
def Pct.decode(s: String) -> List<&2, U32>:
  match s:
    case SNil{}:
      Nil{}
    case SCon{'%', SCon{a, SCon{b, t}}}:
      Pct.esc(a, b, Pct.decode(t))
    case SCon{c, t}:
      U.Utf8.put(Char.to_u32(c), Pct.decode(t))

def Proxy.parse.fin(+h: String, +p: U32, auth: String, empty: Bool) -> Route:
  match empty:
    case True{}:
      NoRoute{"HTTPS_PROXY names no host"}
    case False{}:
      Via{Proxy{h, p, auth}}

def Proxy.parse.hp(hp: String & U32, auth: String) -> Route:
  match hp:
    case (+h, +p):
      Proxy.parse.fin(h, p, auth, String.is_empty(h))

# The authority's parts split at '@', last first: the host, then the
# user info (which may itself hold an '@').
def Proxy.parse.at(rs: List<&2, String>) -> Route:
  match rs:
    case Con{hp, Nil{}}:
      Proxy.parse.hp(K.Url.host_port(hp, 80), "")
    case Con{hp, us}:
      Proxy.parse.hp(K.Url.host_port(hp, 80),
        B.B64.encode(Pct.decode(String.join(List.reverse(&2, String, us), "@"))))
    case Nil{}:
      NoRoute{"HTTPS_PROXY names no host"}

def Proxy.parse.auth(ap: String & String) -> Route:
  match ap:
    case (a, p):
      Proxy.parse.at(List.reverse(&2, String, String.split(a, '@')))

def Proxy.parse.go(+u: String, http: Bool, other: Bool) -> Route:
  match http other:
    case True{} _:
      Proxy.parse.auth(K.Url.split_path(String.drop(u, 7n), ""))
    case False{} True{}:
      NoRoute{"HTTPS_PROXY: only http:// proxies are supported"}
    case False{} False{}:
      Proxy.parse.auth(K.Url.split_path(u, ""))

# "http://user:pass@host:port", or "host:port" (http:// is assumed, as Go
# does). Other schemes fail rather than silently connecting directly.
def Proxy.parse(+u: String) -> Route:
  Proxy.parse.go(u, String.starts_with(String.to_lower(u), "http://"), String.contains(u, "://"))

# Routes
# ------

def Proxy.route.url(+url: String, empty: Bool) -> Route:
  match empty:
    case True{}:
      Direct{}
    case False{}:
      Proxy.parse(String.trim(url))

def Proxy.route.no(+url: String, by: Bool) -> Route:
  match by:
    case True{}:
      Direct{}
    case False{}:
      Proxy.route.url(url, String.is_empty(String.trim(url)))

def Proxy.route.local(+url: String, no: String, +host: String, +port: U32, local: Bool) ->
  Route:
  match local:
    case True{}:
      Direct{}
    case False{}:
      Proxy.route.no(url, NoProxy.bypass(no, host, port))

def Proxy.is_local(+host: String) -> Bool:
  Bool.or(Bool.or(String.eq(host, "localhost"), String.eq(host, "::1")),
    Ip4.is_loopback(Ip4.parse(host)))

# How to reach host:port, given HTTPS_PROXY (url) and NO_PROXY (no):
# localhost and loopback addresses never use a proxy (as in Go), nor do
# hosts NO_PROXY lists, nor anything when no proxy is set.
def Proxy.route(+url: String, no: String, host: String, +port: U32) -> Route:
  +h = String.to_lower(host)
  Proxy.route.local(url, no, h, port, Proxy.is_local(h))

# The CONNECT
# -----------

def Proxy.target.go(+h: String, +p: U32, v6: Bool) -> String:
  match v6:
    case True{}:
      "[" ++ h ++ "]:" ++ U32.show(p)
    case False{}:
      h ++ ":" ++ U32.show(p)

def Proxy.target(+h: String, +p: U32) -> String:
  Proxy.target.go(h, p, String.contains(h, ":"))

def Proxy.auth_line.go(+auth: String, none: Bool) -> String:
  match none:
    case True{}:
      ""
    case False{}:
      "Proxy-Authorization: Basic " ++ auth ++ "\r\n"

# The request that opens a tunnel to host:port.
def Proxy.connect(+host: String, +port: U32, +auth: String) -> String:
  +t = Proxy.target(host, port)
  "CONNECT " ++ t ++ " HTTP/1.1\r\nHost: " ++ t ++ "\r\n"
    ++ Proxy.auth_line.go(auth, String.is_empty(auth)) ++ "\r\n"

# The proxy's answer
# ------------------
#
# Bytes of the answer's head accumulate (last first) until its blank line;
# a 200 opens the tunnel. Any byte after the head would belong to the TLS
# stream before we sent a ClientHello, so it fails the tunnel, as does a
# head past 16KiB or a connection that ends first.

type Tunnel is Data:
  TMore{head: List<&2, U32>}
  TOpen{}
  TFail{why: String}

def Tunnel.init() -> Tunnel:
  TMore{Nil{}}

def Tunnel.is_end(+h: List<&2, U32>) -> Bool:
  match h:
    case Con{+a, Con{+b, Con{+c, Con{+d, t}}}}:
      Bool.and(Bool.and(U32.is_eq(a, 10), U32.is_eq(b, 13)), Bool.and(U32.is_eq(c, 10), U32.is_eq(d, 13)))
    case _:
      False{}

def Tunnel.line.if(+b: U32, rest: List<&2, U32>, cr: Bool) -> List<&2, U32>:
  match cr:
    case True{}:
      Nil{}
    case False{}:
      Con{b, rest}

# The bytes before the first CR.
def Tunnel.line(bs: List<&2, U32>) -> List<&2, U32>:
  match bs:
    case Nil{}:
      Nil{}
    case Con{+b, t}:
      Tunnel.line.if(b, Tunnel.line(t), U32.is_eq(b, 13))

def Tunnel.verdict.go(+line: String, ok: Bool) -> Tunnel:
  match ok:
    case True{}:
      TOpen{}
    case False{}:
      TFail{"proxy refused CONNECT: " ++ line}

def Tunnel.verdict(+line: String) -> Tunnel:
  Tunnel.verdict.go(line, Bool.and(String.starts_with(line, "HTTP/1."),
    String.starts_with(String.drop(line, 9n), "200")))

def Tunnel.done(h: List<&2, U32>, rest: List<&2, U32>) -> Tunnel:
  match rest:
    case Nil{}:
      Tunnel.verdict(U.Utf8.decode_all(Tunnel.line(List.reverse(&2, U32, h))))
    case Con{b, t}:
      TFail{"proxy sent bytes before the TLS handshake"}

def Tunnel.push(bs: List<&2, U32>, +h: List<&2, U32>, end: Bool) -> Tunnel:
  match bs end:
    case rest True{}:
      Tunnel.done(h, rest)
    case Nil{} False{}:
      TMore{h}
    case Con{+b, t} False{}:
      Tunnel.push(t, Con{b, h}, Tunnel.is_end(Con{b, h}))

def Tunnel.cap.go(+h: List<&2, U32>, long: Bool) -> Tunnel:
  match long:
    case True{}:
      TFail{"proxy answer too long"}
    case False{}:
      TMore{h}

def Tunnel.cap(t: Tunnel) -> Tunnel:
  match t:
    case TMore{+h}:
      Tunnel.cap.go(h, Nat.is_gt(List.length(&2, U32, h), 16384n))
    case x:
      x

def Tunnel.more(+h: List<&2, U32>, bs: List<&2, U32>, closed: Bool) -> Tunnel:
  match closed:
    case True{}:
      TFail{"proxy closed the connection before answering CONNECT"}
    case False{}:
      Tunnel.cap(Tunnel.push(bs, h, False{}))

# The tunnel after the next bytes of the answer; no bytes is the end.
def Tunnel.feed(t: Tunnel, +bs: List<&2, U32>) -> Tunnel:
  match t:
    case TMore{+h}:
      Tunnel.more(h, bs, List.is_empty(&2, U32, bs))
    case x:
      x
