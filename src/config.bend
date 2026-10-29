import Base
import ./json.bend as J
import ./utf8.bend as U
import ./base64.bend as B

# Config
# ======
#
# Where the API server is and how to prove who we are (kube-client's
# Config). Pure: a kubeconfig or the in-cluster environment becomes a Config
# whose secrets are either inline or still files to read; the IO side
# (client.bend) reads them, and re-reads token files on every connection,
# so rotated service-account tokens are picked up (client-go's
# CachedFileTokenSource).

# A secret's source: inline text, a file to read, a credential plugin to
# run (client-go's exec ExecCredential: its status.token), or nothing.
type Src is Data:
  Inline{text: String}
  FromFile{path: String}
  FromExec{cmd: String, args: List<&2, String>}
  NoSrc{}

# pool: idle keep-alive connections to reuse (client.bend), when the
# program made one (Config.with_pool); None opens one per request.
type Config is Data:
  Config{host: String, port: U32, base: String, ca: Src, cert: Src, key: Src, token: Src,
    namespace: String, pool: Maybe<&2, Chan(Socket)>}

def Config.host(c: Config) -> String:
  match c:
    case Config{h, p, b, ca, cert, key, tok, ns, pl}:
      h

def Config.namespace(c: Config) -> String:
  match c:
    case Config{h, p, b, ca, cert, key, tok, ns, pl}:
      ns

# Server URLs
# -----------

type Url is Data:
  Url{host: String, port: U32, base: String}

def Url.drop_scheme.go(s: String, tls: Bool) -> String:
  match tls:
    case True{}:
      String.drop(s, 8n)
    case False{}:
      s

def Url.drop_scheme(+s: String) -> String:
  Url.drop_scheme.go(s, String.starts_with(s, "https://"))

# Splits "authority/path" at the first '/'.
def Url.split_path(s: String, acc: String) -> String & String:
  match s:
    case SNil{}:
      (String.reverse(acc), "")
    case SCon{'/', t}:
      (String.reverse(acc), SCon{'/', t})
    case SCon{c, t}:
      Url.split_path(t, SCon{c, acc})

def Url.port(p: String, +dflt: U32) -> U32:
  Maybe.default(&2, U32, U32.read(p), dflt)

def Url.host_port.v6(parts: List<&2, String>, +dflt: U32) -> String & U32:
  match parts:
    case Con{h, Con{p, rest}}:
      (h, Url.port(String.drop(p, 1n), dflt))
    case Con{h, Nil{}}:
      (h, dflt)
    case Nil{}:
      ("", dflt)

def Url.host_port.v4(parts: List<&2, String>, +dflt: U32) -> String & U32:
  match parts:
    case Con{h, Con{p, rest}}:
      (h, Url.port(p, dflt))
    case Con{h, Nil{}}:
      (h, dflt)
    case Nil{}:
      ("", dflt)

# "[::1]:6443" or "host:6443" or "host": the host and the port (dflt when
# none is given).
def Url.host_port(a: String, +dflt: U32) -> String & U32:
  match a:
    case SCon{'[', t}:
      Url.host_port.v6(String.split(t, ']'), dflt)
    case +x:
      Url.host_port.v4(String.split(x, ':'), dflt)

def Url.trim_slash.go(s: String) -> String:
  match s:
    case SCon{'/', t}:
      t
    case x:
      x

def Url.trim_slash(s: String) -> String:
  String.reverse(Url.trim_slash.go(String.reverse(s)))

def Url.parse.fin(hp: String & U32, base: String) -> Url:
  match hp:
    case (h, p):
      Url{h, p, base}

def Url.parse.go(ap: String & String) -> Url:
  match ap:
    case (a, p):
      Url.parse.fin(Url.host_port(a, 443), Url.trim_slash(p))

def Url.parse(s: String) -> Url:
  Url.parse.go(Url.split_path(Url.drop_scheme(s), ""))

def Kube.named.if(+x: J.Json, +field: String, rest: J.Json, hit: Bool) -> J.Json:
  match hit:
    case True{}:
      J.Json.get(x, field)
    case False{}:
      rest

# Kubeconfig
# ----------

# The entry of a named list ("clusters", "users", "contexts") with this
# name, as its inner object (cluster, user or context).
def Kube.named(xs: List<&2, J.Json>, +name: String, +field: String) -> J.Json:
  match xs:
    case Nil{}:
      J.JNull{}
    case Con{+x, t}:
      Kube.named.if(x, field, Kube.named(t, name, field),
        String.eq(J.Json.str_or(J.Json.get(x, "name"), ""), name))

def Kube.src.b64(bs: Maybe<&2, List<&2, U32>>) -> Src:
  match bs:
    case Some{b}:
      Inline{U.Utf8.decode_all(b)}
    case None{}:
      NoSrc{}

def Kube.src.go(data: J.Json, path: J.Json) -> Src:
  match data path:
    case J.JStr{d} _:
      Kube.src.b64(B.B64.decode(d))
    case _ J.JStr{p}:
      FromFile{p}
    case _ _:
      NoSrc{}

# A secret from "<name>-data" (base64, inline) or "<name>" (a path).
def Kube.src(+o: J.Json, +name: String) -> Src:
  Kube.src.go(J.Json.get(o, name ++ "-data"), J.Json.get(o, name))

def Kube.strs(xs: List<&2, J.Json>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{J.JStr{x}, t}:
      x <> Kube.strs(t)
    case Con{x, t}:
      Kube.strs(t)

# A plugin runs under `env`, which sets the plugin's env entries (and
# KUBERNETES_EXEC_INFO, as client-go does) on top of our environment.
def Kube.token.exec(c: J.Json, env: List<&2, String>, args: List<&2, String>) -> Src:
  match c:
    case J.JStr{cmd}:
      FromExec{"env", List.append(&2, String, env,
        ("KUBERNETES_EXEC_INFO={\"apiVersion\":\"client.authentication.k8s.io/v1\",\"kind\":\"ExecCredential\",\"spec\":{\"interactive\":false}}")
          <> cmd <> args)}
    case _:
      NoSrc{}

# An exec plugin's env entries ({name, value}) as "name=value".
def Kube.envs(xs: List<&2, J.Json>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{+x, t}:
      (J.Json.str_or(J.Json.get(x, "name"), "") ++ "=" ++ J.Json.str_or(J.Json.get(x, "value"), ""))
        <> Kube.envs(t)

def Kube.token.go(t: J.Json, f: J.Json, +e: J.Json) -> Src:
  match t f:
    case J.JStr{s} _:
      Inline{s}
    case _ J.JStr{p}:
      FromFile{p}
    case _ _:
      Kube.token.exec(J.Json.get(e, "command"), Kube.envs(J.Json.items(J.Json.get(e, "env"))),
        Kube.strs(J.Json.items(J.Json.get(e, "args"))))

def Kube.token(+u: J.Json) -> Src:
  Kube.token.go(J.Json.get(u, "token"), J.Json.get(u, "tokenFile"), J.Json.get(u, "exec"))

def Kube.config.pick.go(ctx: String, cur: String, empty: Bool) -> String:
  match empty:
    case True{}:
      cur
    case False{}:
      ctx

def Kube.config.pick(+ctx: String, cur: String) -> String:
  Kube.config.pick.go(ctx, cur, String.is_empty(ctx))

def Kube.config.fin(u: Url, ca: Src, cert: Src, key: Src, tok: Src, ns: String) ->
  Result<&2, &2, String, Config>:
  match u:
    case Url{h, p, b}:
      Done{Config{h, p, b, ca, cert, key, tok, ns, None{}}}

def Kube.config.server(s: J.Json, ca: Src, cert: Src, key: Src, tok: Src, ns: String) ->
  Result<&2, &2, String, Config>:
  match s:
    case J.JStr{url}:
      Kube.config.fin(Url.parse(url), ca, cert, key, tok, ns)
    case _:
      Fail{"kubeconfig: the cluster has no server"}

def Kube.config.build(+cl: J.Json, +u: J.Json, ns: String, name: String, missing: Bool) ->
  Result<&2, &2, String, Config>:
  match missing:
    case True{}:
      Fail{"kubeconfig: no context named " ++ name}
    case False{}:
      Kube.config.server(J.Json.get(cl, "server"), Kube.src(cl, "certificate-authority"),
        Kube.src(u, "client-certificate"), Kube.src(u, "client-key"), Kube.token(u), ns)

def Kube.config.with(+kc: J.Json, name: String, +c: J.Json) -> Result<&2, &2, String, Config>:
  Kube.config.build(
    Kube.named(J.Json.items(J.Json.get(kc, "clusters")),
      J.Json.str_or(J.Json.get(c, "cluster"), ""), "cluster"),
    Kube.named(J.Json.items(J.Json.get(kc, "users")),
      J.Json.str_or(J.Json.get(c, "user"), ""), "user"),
    J.Json.str_or(J.Json.get(c, "namespace"), "default"), name, J.Json.is_null(c))

def Kube.config.ctx(+kc: J.Json, +name: String) -> Result<&2, &2, String, Config>:
  Kube.config.with(kc, name, Kube.named(J.Json.items(J.Json.get(kc, "contexts")), name, "context"))

# The Config a kubeconfig (as JSON) names for a context ("" for its
# current-context), or why it cannot.
def Kube.config(+kc: J.Json, ctx: String) -> Result<&2, &2, String, Config>:
  Kube.config.ctx(kc, Kube.config.pick(ctx, J.Json.str_or(J.Json.get(kc, "current-context"), "")))

# In-cluster
# ----------

def InCluster.dir() -> String:
  "/var/run/secrets/kubernetes.io/serviceaccount"

# The pod's service account, from KUBERNETES_SERVICE_HOST and _PORT
# (client-go's InClusterConfig). An IPv6 host needs no brackets here.
def InCluster.config(host: String, port: String, ns: String) -> Config:
  Config{host, Url.port(port, 443), "", FromFile{InCluster.dir() ++ "/ca.crt"}, NoSrc{}, NoSrc{},
    FromFile{InCluster.dir() ++ "/token"}, String.trim(ns), None{}}

# Merging and paths
# -----------------

def Kube.names(xs: List<&2, J.Json>) -> List<&2, String>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{+x, t}:
      J.Json.str_or(J.Json.get(x, "name"), "") <> Kube.names(t)

def Kube.merge.new.put(x: J.Json, rest: List<&2, J.Json>, dup: Bool) -> List<&2, J.Json>:
  match dup:
    case True{}:
      rest
    case False{}:
      x <> rest

def Kube.merge.new(b: List<&2, J.Json>, +seen: List<&2, String>) -> List<&2, J.Json>:
  match b:
    case Nil{}:
      Nil{}
    case Con{+x, t}:
      Kube.merge.new.put(x, Kube.merge.new(t, seen),
        List.contains(~String, ~String.eq, seen, J.Json.str_or(J.Json.get(x, "name"), "")))

def Kube.merge.list(+a: List<&2, J.Json>, b: List<&2, J.Json>) -> List<&2, J.Json>:
  List.append(&2, J.Json, a, Kube.merge.new(b, Kube.names(a)))

def Kube.merge.field(+a: J.Json, +b: J.Json, +f: String) -> J.Json:
  J.Json.arr(Kube.merge.list(J.Json.items(J.Json.get(a, f)), J.Json.items(J.Json.get(b, f))))

def Kube.merge.cur(a: String, b: String) -> String:
  Kube.config.pick(a, b)

# Two kubeconfigs as client-go merges a KUBECONFIG list: an entry named in
# the first wins over the same name in the second, and current-context is
# the first one set.
def Kube.merge(+a: J.Json, +b: J.Json) -> J.Json:
  J.Json.obj([J.KV{"clusters", Kube.merge.field(a, b, "clusters")},
    J.KV{"contexts", Kube.merge.field(a, b, "contexts")},
    J.KV{"users", Kube.merge.field(a, b, "users")},
    J.KV{"current-context", J.JStr{Kube.merge.cur(J.Json.str_or(J.Json.get(a, "current-context"), ""),
      J.Json.str_or(J.Json.get(b, "current-context"), ""))}}])

def Kube.rebase.str(dir: String, s: String, abs: Bool) -> String:
  match abs:
    case True{}:
      s
    case False{}:
      dir ++ "/" ++ s

# A relative path in a kubeconfig is relative to the kubeconfig's directory.
def Kube.rebase.path(+dir: String, p: J.Json) -> J.Json:
  match p:
    case J.JStr{+s}:
      J.JStr{Kube.rebase.str(dir, s, String.starts_with(s, "/"))}
    case x:
      x

def Kube.rebase.key(+o: J.Json, +dir: String, +k: String, missing: Bool) -> J.Json:
  match missing:
    case True{}:
      o
    case False{}:
      J.Json.set(o, k, Kube.rebase.path(dir, J.Json.get(o, k)))

def Kube.rebase.keys(ks: List<&2, String>, +o: J.Json, +dir: String) -> J.Json:
  match ks:
    case Nil{}:
      o
    case Con{+k, t}:
      Kube.rebase.keys(t, Kube.rebase.key(o, dir, k, J.Json.is_null(J.Json.get(o, k))), dir)

def Kube.rebase.items(xs: List<&2, J.Json>, +dir: String, +inner: String, +ks: List<&2, String>) ->
  List<&2, J.Json>:
  match xs:
    case Nil{}:
      Nil{}
    case Con{+x, t}:
      J.Json.set(x, inner, Kube.rebase.keys(ks, J.Json.get(x, inner), dir))
        <> Kube.rebase.items(t, dir, inner, ks)

# The kubeconfig with every file path made absolute against dir.
def Kube.rebase(+kc: J.Json, +dir: String) -> J.Json:
  J.Json.set(J.Json.set(kc, "clusters",
    J.Json.arr(Kube.rebase.items(J.Json.items(J.Json.get(kc, "clusters")), dir, "cluster",
      ["certificate-authority"]))),
    "users", J.Json.arr(Kube.rebase.items(J.Json.items(J.Json.get(kc, "users")), dir, "user",
      ["client-certificate", "client-key", "tokenFile"])))

def Kube.dir.fin(d: String, bare: Bool) -> String:
  match bare:
    case True{}:
      "."
    case False{}:
      d

def Kube.dir.go(+parts: List<&2, String>) -> String:
  Kube.dir.fin(String.join(List.take(&2, String, parts, Nat.sub(List.length(&2, String, parts), 1n)), "/"),
    Nat.is_le(List.length(&2, String, parts), 1n))

# The directory of a path ("." when it has none).
def Kube.dir(+p: String) -> String:
  Kube.dir.go(String.split(p, '/'))

def Config.with_pool(c: Config, pool: Chan(Socket)) -> Config:
  match c:
    case Config{h, p, b, ca, cert, key, tok, ns, pl}:
      Config{h, p, b, ca, cert, key, tok, ns, Some{pool}}

def Config.pool(c: Config) -> Maybe<&2, Chan(Socket)>:
  match c:
    case Config{h, p, b, ca, cert, key, tok, ns, pl}:
      pl
