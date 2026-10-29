import Base
import ./src/json.bend as J
import ./src/core.bend as C
import ./src/watcher.bend as W
import ./src/store.bend as S
import ./src/queue.bend as Q
import ./src/finalizer.bend as F
import ./src/http.bend as H
import ./src/utf8.bend as U
import ./src/proxy.bend as P

# LAWS
# ====
#
# The rules bend-kube must keep, stated over its pure state machines. They
# are how client-go and kube-runtime say the API behaves; PROOF.bend proves
# each one. Humans own this file: change a law only on purpose.

# Watcher (client-go's reflector)
# -------------------------------

# A watch that answers 410 Gone relists from scratch, at once.
law watch_gone_relists:
  for rv: String
  for f: U32
  for first: Bool
  for r: String
  for m: String
  {W.Watcher.step(W.WState{W.WWatch{rv}, f, first}, W.IEvent{C.WError{C.Status{410, r, m}}})
    == W.Step{W.WState{W.WList{""}, f, True{}}, Nil{}, False{}} : W.Step}

# So does a watch request the server refuses with 410.
law watch_request_gone_relists:
  for rv: String
  for f: U32
  for first: Bool
  {W.Watcher.step(W.WState{W.WWatch{rv}, f, first}, W.IWatchErr{410})
    == W.Step{W.WState{W.WList{""}, f, True{}}, Nil{}, False{}} : W.Step}

# An expired continue token restarts the list from its first page.
law list_gone_relists:
  for c: String
  for f: U32
  for first: Bool
  {W.Watcher.step(W.WState{W.WList{c}, f, first}, W.IListErr{410})
    == W.Step{W.WState{W.WList{""}, f, True{}}, Nil{}, False{}} : W.Step}

# A failed watch request (not 410) retries from the same version after a
# backoff, counting the failure.
law watch_error_backs_off:
  for rv: String
  for f: U32
  for first: Bool
  {W.Watcher.step(W.WState{W.WWatch{rv}, f, first}, W.IWatchErr{500})
    == W.Step{W.WState{W.WWatch{rv}, (f + 1 : U32), False{}}, Nil{}, True{}} : W.Step}

# A watch that ends (the server's timeout) resumes from the same version,
# with no backoff and no events.
law watch_end_resumes:
  for rv: String
  for f: U32
  for first: Bool
  {W.Watcher.step(W.WState{W.WWatch{rv}, f, first}, W.IWatchEnd{})
    == W.Step{W.WState{W.WWatch{rv}, 0, False{}}, Nil{}, False{}} : W.Step}

# A bookmark moves the resume version and emits nothing.
law bookmark_advances:
  for rv: String
  for v: String
  for f: U32
  for first: Bool
  {W.Watcher.step(W.WState{W.WWatch{rv}, f, first}, W.IEvent{C.WBookmark{v}})
    == W.Step{W.WState{W.WWatch{v}, 0, False{}}, Nil{}, False{}} : W.Step}

# The last page of a list (no continue token) emits its objects, closes
# the relist with InitDone, and starts watching from the list's version.
law last_page_watches:
  for c: String
  for f: U32
  for first: Bool
  for items: List<&2, J.Json>
  for rv: String
  {W.Watcher.step(W.WState{W.WList{c}, f, first}, W.IPage{C.Page{items, rv, ""}})
    == W.Step{W.WState{W.WWatch{rv}, 0, True{}},
      W.Watcher.init_out(first, W.Watcher.page_outs(items, [W.OInitDone{}])), False{}} : W.Step}

# The first page of a relist opens it with Init.
law first_page_inits:
  for items: List<&2, J.Json>
  {W.Watcher.init_out(True{}, W.Watcher.page_outs(items, Nil{}))
    == W.OInit{} <> W.Watcher.page_outs(items, Nil{}) : List<&2, W.Out>}

# The watcher's backoff never exceeds 30s, however many failures.
law watch_backoff_capped:
  {W.Backoff.delay(6) == 30000 : U32}

# Store (kube-runtime's reflector)
# --------------------------------

# A relist starts from an empty buffer, whatever the store held.
law init_clears_buffer:
  for objs: Map<&2, J.Json>
  for buf: Map<&2, J.Json>
  for r: Bool
  {S.Store.apply(S.Store{objs, buf, r}, W.OInit{})
    == S.Store{objs, Map.new(&2, J.Json), r} : S.Store}

# InitDone swaps the relisted buffer in whole: objects absent from the
# relist leave the store, and the store is ready.
law init_done_swaps:
  for objs: Map<&2, J.Json>
  for buf: Map<&2, J.Json>
  for r: Bool
  {S.Store.apply(S.Store{objs, buf, r}, W.OInitDone{})
    == S.Store{buf, Map.new(&2, J.Json), True{}} : S.Store}

# Queue (client-go's workqueue)
# -----------------------------

# Adding a key that is running does not queue it a second time: it is
# marked dirty, to run again when the current run ends.
law add_running_marks_dirty:
  for f: List<&2, String>
  for b: List<&2, String>
  for inq: Map<&2, U32>
  for run: Map<&2, U32>
  for d: Map<&2, U32>
  for g: Map<&2, U32>
  for fl: Map<&2, U32>
  for n: U32
  for mx: U32
  for key: String
  for running: {Q.Mp.has(run, key) == True{} : Bool}
  {Q.Queue.add(Q.Queue{f, b, inq, run, d, g, fl, n, mx}, key)
    == Q.Queue{f, b, inq, run, Q.Mp.on(d, key), Q.Mp.bump(g, key), fl, n, mx} : Q.Queue}

# Adding a key that already waits changes nothing but its timer.
law add_waiting_dedups:
  for f: List<&2, String>
  for b: List<&2, String>
  for inq: Map<&2, U32>
  for run: Map<&2, U32>
  for d: Map<&2, U32>
  for g: Map<&2, U32>
  for fl: Map<&2, U32>
  for n: U32
  for mx: U32
  for key: String
  for idle: {Q.Mp.has(run, key) == False{} : Bool}
  for waiting: {Q.Mp.has(inq, key) == True{} : Bool}
  {Q.Queue.add(Q.Queue{f, b, inq, run, d, g, fl, n, mx}, key)
    == Q.Queue{f, b, inq, run, d, Q.Mp.bump(g, key), fl, n, mx} : Q.Queue}

# No key starts while every worker slot is taken.
law pop_respects_limit:
  for f: List<&2, String>
  for b: List<&2, String>
  for inq: Map<&2, U32>
  for run: Map<&2, U32>
  for d: Map<&2, U32>
  for g: Map<&2, U32>
  for fl: Map<&2, U32>
  for n: U32
  for mx: U32
  for full: {U32.is_lt(n, mx) == False{} : Bool}
  {Q.Queue.pop(Q.Queue{f, b, inq, run, d, g, fl, n, mx})
    == (Q.Queue{f, b, inq, run, d, g, fl, n, mx}, None{}) : Q.Queue & Maybe<&2, String>}

# A failing key backs off for at most 1000s.
law retry_backoff_capped:
  {Q.Queue.backoff(18) == 1000000 : U32}

# Finishing a key that is not running changes nothing and arms no timer.
law done_idle_noop:
  for q: Q.Queue
  for key: String
  for a: Q.Action
  for idle: {Q.Queue.running(q, key) == False{} : Bool}
  {Q.Queue.done(q, key, a) == (q, Nil{}) : Q.Queue & List<&2, Q.Timer>}

# Forgetting never disturbs a key that is running.
law forget_running_keeps:
  for q: Q.Queue
  for key: String
  for running: {Q.Queue.running(q, key) == True{} : Bool}
  {Q.Queue.forget(q, key) == q : Q.Queue}

# Finalizers (kube-runtime's finalizer)
# -------------------------------------

# A live object that carries our finalizer is applied.
law fin_live_applies:
  for fs: List<&2, String>
  for name: String
  for i: U32
  {F.Fin.state.go(fs, name, Some{i}, False{}) == F.FApply{} : F.FState}

# A deleted object that no longer carries it needs nothing more.
law fin_gone_done:
  for fs: List<&2, String>
  for name: String
  {F.Fin.state.go(fs, name, None{}, True{}) == F.FDone{} : F.FState}

# A deleted object that still carries it is cleaned up, and the finalizer
# is removed only through a patch that tests it is still ours, at its index.
law fin_cleanup_tests:
  for fs: List<&2, String>
  for name: String
  for i: U32
  {F.Fin.state.go(fs, name, Some{i}, True{}) == F.FCleanup{F.Fin.remove_patch(i, name)} : F.FState}

# HTTP (the keep-alive pool's retry rule)
# ---------------------------------------

# A connection that ends before any byte of a response is lost, not broken:
# only then may a request on a reused connection be retried.
law eof_before_response_is_lost:
  for t: U32
  for h: Maybe<&2, H.Head>
  for o: List<&2, U32>
  {H.Http.eof(H.Resp{H.PHead{Nil{}, t}, h, o})
    == H.Resp{H.PLost{"connection closed before a response"}, h, o} : H.Resp}

# Bytes of a response make an early end a broken response, never retried.
law eof_mid_response_is_broken:
  for b: U32
  for bs: List<&2, U32>
  for t: U32
  for h: Maybe<&2, H.Head>
  for o: List<&2, U32>
  {H.Http.eof(H.Resp{H.PHead{b <> bs, t}, h, o})
    == H.Resp{H.PErr{"connection closed mid-response"}, h, o} : H.Resp}

# Proxies (Go's ProxyFromEnvironment, as client-go uses it)
# ---------------------------------------------------------

# localhost and loopback addresses never go through a proxy, whatever
# HTTPS_PROXY and NO_PROXY say.
law proxy_skips_localhost:
  for url: String
  for no: String
  for port: U32
  {P.Proxy.route(url, no, "localhost", port) == P.Direct{} : P.Route}

law proxy_skips_loopback:
  for url: String
  for no: String
  for port: U32
  {P.Proxy.route(url, no, "127.0.0.1", port) == P.Direct{} : P.Route}

# NO_PROXY=* sends every host around the proxy.
law no_proxy_star_bypasses:
  for url: String
  for port: U32
  {P.Proxy.route(url, "*", "api.example.com", port) == P.Direct{} : P.Route}

# Without HTTPS_PROXY, connections are direct.
law no_proxy_url_is_direct:
  for port: U32
  {P.Proxy.route("", "", "api.example.com", port) == P.Direct{} : P.Route}

# A proxy bend-kube cannot speak fails the connection: it never falls back
# to connecting directly.
law unsupported_proxy_fails:
  for port: U32
  {P.Proxy.route("socks5://proxy:1080", "", "api.example.com", port)
    == P.NoRoute{"HTTPS_PROXY: only http:// proxies are supported"} : P.Route}

# ".corp" bypasses the subdomains of corp, not corp itself.
law no_proxy_dot_is_subdomains_only:
  {P.Proxy.route("http://proxy:3128", ".corp", "corp", 443)
    == P.Via{P.Proxy{"proxy", 3128, ""}} : P.Route}

# "corp" bypasses corp and its subdomains, never a name that merely ends
# in the same letters.
law no_proxy_respects_labels:
  {P.Proxy.route("http://proxy:3128", "corp", "evilcorp", 443)
    == P.Via{P.Proxy{"proxy", 3128, ""}} : P.Route}

# An entry with a port bypasses only that port.
law no_proxy_port_narrows:
  {P.Proxy.route("http://proxy:3128", "api.corp:6443", "api.corp", 443)
    == P.Via{P.Proxy{"proxy", 3128, ""}} : P.Route}

# Only a 200 opens the tunnel; any other answer fails it, quoted.
law tunnel_needs_200:
  {P.Tunnel.feed(P.Tunnel.init(),
    U.Utf8.encode("HTTP/1.1 407 Proxy Authentication Required\r\n\r\n"))
    == P.TFail{"proxy refused CONNECT: HTTP/1.1 407 Proxy Authentication Required"} : P.Tunnel}

# Bytes after the proxy's answer, before we spoke TLS, fail the tunnel:
# nothing the proxy says may become part of the TLS stream.
law tunnel_rejects_early_bytes:
  for b: U32
  for bs: List<&2, U32>
  {P.Tunnel.feed(P.Tunnel.init(),
    List.append(&2, U32, U.Utf8.encode("HTTP/1.1 200 OK\r\n\r\n"), b <> bs))
    == P.TFail{"proxy sent bytes before the TLS handshake"} : P.Tunnel}

# A proxy that hangs up before its answer is whole fails the tunnel.
law tunnel_end_before_answer:
  for h: List<&2, U32>
  {P.Tunnel.feed(P.TMore{h}, Nil{})
    == P.TFail{"proxy closed the connection before answering CONNECT"} : P.Tunnel}
