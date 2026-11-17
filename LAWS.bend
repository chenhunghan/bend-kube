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
import ./src/lease.bend as E
import ./src/control.bend as X
import ./src/cond.bend as Co
import ./src/config.bend as K
import ./src/admission.bend as A
import ./src/pb.bend as Pr
import ./src/hpack.bend as Hp

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

# A cleanup that failed, or that holds (waiting on something outside),
# keeps the finalizer, so the object is not deleted before cleanup is done.
law fin_failed_cleanup_keeps:
  for m: String
  {F.Fin.keeps(Q.Retry{m}) == True{} : Bool}

law fin_held_cleanup_keeps:
  for ms: U32
  {F.Fin.keeps(Q.Hold{ms}) == True{} : Bool}

# A finished cleanup lets the finalizer go.
law fin_done_cleanup_releases:
  {F.Fin.keeps(Q.AwaitChange{}) == False{} : Bool}

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

# Controllers (kube-runtime's predicates and trigger mappers)
# ----------------------------------------------------------

# An object with a generation, a version, a deletion stamp and a status,
# for the laws below.
def Ex.obj(gen: J.Json, rv: String, del: J.Json, st: J.Json) -> J.Json:
  J.Json.obj([J.KV{"metadata", J.Json.obj([J.KV{"name", J.JStr{"w"}},
    J.KV{"namespace", J.JStr{"default"}}, J.KV{"generation", gen},
    J.KV{"resourceVersion", J.JStr{rv}}, J.KV{"deletionTimestamp", del}])}, J.KV{"status", st}])

# Without predicates, every change reconciles.
law filter_none_passes:
  for old: Maybe<&2, J.Json>
  for new: J.Json
  {X.Pred.passes(Nil{}, old, new) == True{} : Bool}

# With predicates, an object the cache has not seen always reconciles.
law filter_uncached_passes:
  for p: X.Pred
  for ps: List<&2, X.Pred>
  for new: J.Json
  {X.Pred.passes(p <> ps, None{}, new) == True{} : Bool}

# Under the generation predicate, a change that leaves the generation alone
# (a status write, whatever its version) does not reconcile: a controller's
# own status updates do not wake it.
law filter_same_generation_skips:
  for r1: String
  for r2: String
  for a: J.Json
  for b: J.Json
  {X.Pred.passes([X.PGeneration{}], Some{Ex.obj(J.JNum{"3"}, r1, J.JNull{}, a)},
    Ex.obj(J.JNum{"3"}, r2, J.JNull{}, b)) == False{} : Bool}

# A new generation (a spec change) reconciles.
law filter_generation_passes:
  for r1: String
  for r2: String
  for a: J.Json
  for b: J.Json
  {X.Pred.passes([X.PGeneration{}], Some{Ex.obj(J.JNum{"3"}, r1, J.JNull{}, a)},
    Ex.obj(J.JNum{"4"}, r2, J.JNull{}, b)) == True{} : Bool}

# The start of a deletion reconciles, whatever the predicates, so a
# finalizer is never missed.
law filter_deletion_passes:
  for r1: String
  for r2: String
  for a: J.Json
  for b: J.Json
  for t: String
  {X.Pred.passes([X.PGeneration{}], Some{Ex.obj(J.JNum{"3"}, r1, J.JNull{}, a)},
    Ex.obj(J.JNum{"3"}, r2, J.JStr{t}, b)) == True{} : Bool}

# An object without a generation (a ConfigMap) reconciles on every change.
law filter_no_generation_passes:
  for a: J.Json
  for b: J.Json
  {X.Pred.passes([X.PGeneration{}], Some{Ex.obj(J.JNull{}, "1", J.JNull{}, a)},
    Ex.obj(J.JNull{}, "2", J.JNull{}, b)) == True{} : Bool}

# Without predicates, an applied primary is cached and reconciles.
law fold_apply_triggers:
  for x: J.Json
  for s: S.Store
  for ks: List<&2, String>
  for g: List<&2, String>
  {X.Fold.prim(Nil{}, [W.OApply{x}], X.Fold{s, ks, g})
    == X.Fold{S.Store.apply(s, W.OApply{x}), C.Obj.key(x) <> ks, g} : X.Fold}

# A deleted primary leaves the cache, reconciles nothing, and is forgotten.
law fold_delete_forgets:
  for ps: List<&2, X.Pred>
  for x: J.Json
  for s: S.Store
  for ks: List<&2, String>
  for g: List<&2, String>
  {X.Fold.prim(ps, [W.ODelete{x}], X.Fold{s, ks, g})
    == X.Fold{S.Store.apply(s, W.ODelete{x}), ks, C.Obj.key(x) <> g} : X.Fold}

# An owned object reconciles the owner it names of the primary's kind and
# API group, in its own namespace (kube-runtime's trigger_owners).
law owner_triggers_owner:
  for prim: S.Store
  {X.Rel.keys(X.ROwner{}, C.Res{"bend-kube.dev", "v1alpha1", "Website", "websites", True{}},
    J.Json.obj([J.KV{"metadata", J.Json.obj([J.KV{"name", J.JStr{"w-web"}},
      J.KV{"namespace", J.JStr{"default"}},
      J.KV{"ownerReferences", J.Json.arr([J.Json.obj([
        J.KV{"apiVersion", J.JStr{"bend-kube.dev/v1alpha1"}}, J.KV{"kind", J.JStr{"Website"}},
        J.KV{"name", J.JStr{"w"}}])])}])}]), prim)
    == ["default/w"] : List<&2, String>}

# A cluster-scoped primary is named by its owned objects without their
# namespace, so a namespaced child reconciles it.
law owner_triggers_cluster_owner:
  for prim: S.Store
  {X.Rel.keys(X.ROwner{}, C.Res{"bend-kube.dev", "v1", "Tenant", "tenants", False{}},
    J.Json.obj([J.KV{"metadata", J.Json.obj([J.KV{"name", J.JStr{"quota"}},
      J.KV{"namespace", J.JStr{"team-a"}},
      J.KV{"ownerReferences", J.Json.arr([J.Json.obj([
        J.KV{"apiVersion", J.JStr{"bend-kube.dev/v1"}}, J.KV{"kind", J.JStr{"Tenant"}},
        J.KV{"name", J.JStr{"a"}}])])}])}]), prim)
    == ["a"] : List<&2, String>}

# An owner of the same kind in another API group is not the primary.
law owner_needs_group:
  for prim: S.Store
  {X.Rel.keys(X.ROwner{}, C.Res{"bend-kube.dev", "v1alpha1", "Website", "websites", True{}},
    J.Json.obj([J.KV{"metadata", J.Json.obj([J.KV{"name", J.JStr{"w-web"}},
      J.KV{"namespace", J.JStr{"default"}},
      J.KV{"ownerReferences", J.Json.arr([J.Json.obj([
        J.KV{"apiVersion", J.JStr{"other.io/v1"}}, J.KV{"kind", J.JStr{"Website"}},
        J.KV{"name", J.JStr{"w"}}])])}])}]), prim)
    == Nil{} : List<&2, String>}

# Under any predicate, a change of finalizers (one added, as a finalizer
# helper does before waiting for the change) reconciles.
law filter_finalizer_passes:
  for r1: String
  for r2: String
  for a: J.Json
  for b: J.Json
  for f: String
  {X.Pred.passes([X.PGeneration{}], Some{Ex.obj(J.JNum{"3"}, r1, J.JNull{}, a)},
    J.Json.set(Ex.obj(J.JNum{"3"}, r2, J.JNull{}, b), "metadata",
      J.Json.set(J.Json.get(Ex.obj(J.JNum{"3"}, r2, J.JNull{}, b), "metadata"), "finalizers",
        J.Json.arr([J.JStr{f}])))) == True{} : Bool}

# Leader election (client-go's leaderelection)
# --------------------------------------------

# A Lease held by "a", as another replica reads it.
def Ex.lease(+holder: String) -> J.Json:
  J.Json.obj([J.KV{"spec", J.Json.obj([J.KV{"holderIdentity", J.JStr{holder}},
    J.KV{"renewTime", J.JStr{"r"}}])}])

# Another holder's lease, last seen changing 1s ago (15s duration), is live:
# we wait.
law lease_live_is_held:
  {E.Lease.held(Ex.lease("a"), "b", E.Obs{"a", "r", 100000}, 101000, 15) == True{} : Bool}

# Our clock stepping back 1s does not make it expire.
law lease_clock_step_is_held:
  {E.Lease.held(Ex.lease("a"), "b", E.Obs{"a", "r", 100000}, 99000, 15) == True{} : Bool}

# Seen unchanged for longer than its duration, it has expired: we may take it.
law lease_expired_is_taken:
  {E.Lease.held(Ex.lease("a"), "b", E.Obs{"a", "r", 100000}, 115001, 15) == False{} : Bool}

# Our own lease is never held against us: we renew it.
law lease_ours_renews:
  for at: U32
  for now: U32
  {E.Lease.held(Ex.lease("b"), "b", E.Obs{"b", "r", at}, now, 15) == False{} : Bool}

# A released lease (no holder) is free at once.
law lease_released_is_free:
  for at: U32
  for now: U32
  {E.Lease.held(Ex.lease(""), "b", E.Obs{"", "r", at}, now, 15) == False{} : Bool}

# A held Lease lasts its holder's own duration (spec.leaseDurationSeconds),
# however short the contender's: 20s after its last change, a 30s lease is
# still live for a contender configured with 15s.
law lease_holder_duration_rules:
  {E.Lease.held(J.Json.obj([J.KV{"spec", J.Json.obj([J.KV{"holderIdentity", J.JStr{"a"}},
    J.KV{"renewTime", J.JStr{"r"}}, J.KV{"leaseDurationSeconds", J.JNum{"30"}}])}]),
    "b", E.Obs{"a", "r", 100000}, 120000, 15) == True{} : Bool}

# An object deleted and recreated under the same name (a new uid) passes the
# generation predicate even at the same generation.
law filter_new_uid_passes:
  for r1: String
  for r2: String
  for a: J.Json
  for b: J.Json
  {X.Pred.passes([X.PGeneration{}],
    Some{J.Json.set(Ex.obj(J.JNum{"1"}, r1, J.JNull{}, a), "metadata",
      J.Json.set(J.Json.get(Ex.obj(J.JNum{"1"}, r1, J.JNull{}, a), "metadata"), "uid", J.JStr{"u1"}))},
    J.Json.set(Ex.obj(J.JNum{"1"}, r2, J.JNull{}, b), "metadata",
      J.Json.set(J.Json.get(Ex.obj(J.JNum{"1"}, r2, J.JNull{}, b), "metadata"), "uid", J.JStr{"u2"})))
    == True{} : Bool}

# The default election timing (15s lease, 10s renew deadline, 2s retry) is
# accepted; a lease no longer than its renew deadline is refused.
law lease_default_timing_ok:
  {E.Lease.timing(15, 10000, 2000) == None{} : Maybe<&2, String>}

law lease_short_lease_refused:
  {E.Lease.timing(5, 10000, 2000)
    == Some{"leader election: the lease duration must exceed the renew deadline by at least a second"} : Maybe<&2, String>}

# A lease that outlasts its deadline by less than a second leaves too little
# slack between a leader stopping and a standby starting: refused.
law lease_thin_margin_refused:
  {E.Lease.timing(15, 14500, 2000)
    == Some{"leader election: the lease duration must exceed the renew deadline by at least a second"} : Maybe<&2, String>}

# A leader is late from the moment its renew deadline is reached, and it
# never sleeps past it: after 9.9s of a 10s deadline it naps at most 0.1s,
# however long its retry period.
law leader_late_at_deadline:
  {E.Lease.late(10000, 0, 10000) == True{} : Bool}

law leader_nap_bounded:
  {E.Lease.nap(9900, 0, 10000, 2000, True{}) == 100 : U32}

# A candidate whose winning write lands past the renew deadline, counted
# from the start of that attempt, must not start: 2.5s after an attempt
# begun at 0.1s, with a 2.4s deadline, it is overdue.
law acquisition_overdue_stops:
  {E.Lease.overdue(2600, 0, 100, 2400, False{}) == True{} : Bool}

# A leader counts from its last renewal, however recent the attempt.
law renewal_overdue_from_last:
  {E.Lease.overdue(10000, 0, 9000, 10000, True{}) == True{} : Bool}

# Conditions (apimachinery's meta.SetStatusCondition)
# ---------------------------------------------------

# Setting a condition whose status is unchanged keeps its transition time.
law cond_same_status_keeps_time:
  for r1: String
  for m1: String
  for t0: String
  for r2: String
  for m2: String
  for g: String
  for now: String
  {Co.Cond.get(Co.Cond.set([Co.Cond.make("Ready", "True", r1, m1, "1", t0)],
    Co.Cond.make("Ready", "True", r2, m2, "2", now)), "Ready")
    == Some{Co.Cond.make("Ready", "True", r2, m2, "2", t0)} : Maybe<&2, J.Json>}

# A changed status takes the new transition time.
law cond_new_status_moves_time:
  for r1: String
  for m1: String
  for t0: String
  for r2: String
  for m2: String
  for now: String
  {Co.Cond.get(Co.Cond.set([Co.Cond.make("Ready", "False", r1, m1, "1", t0)],
    Co.Cond.make("Ready", "True", r2, m2, "2", now)), "Ready")
    == Some{Co.Cond.make("Ready", "True", r2, m2, "2", now)} : Maybe<&2, J.Json>}

# Per-watch filters and clusters
# ------------------------------

# A related watch without predicates triggers on every change, as before
# watches had filters.
law rel_unfiltered_is_rel:
  for r: X.Rel
  for res: C.Res
  for outs: List<&2, W.Out>
  for prim: S.Store
  for f: X.Fold
  {X.Fold.rel_where(r, Nil{}, res, outs, prim, f) == X.Fold.rel(r, res, outs, prim, f) : X.Fold}

# A deleted related object triggers its primaries, whatever the watch's
# predicates: a filter never hides a deletion.
law rel_filter_keeps_deletions:
  for r: X.Rel
  for ps: List<&2, X.Pred>
  for res: C.Res
  for x: J.Json
  for prim: S.Store
  for s: S.Store
  for ks: List<&2, String>
  for g: List<&2, String>
  {X.Fold.rel_where(r, ps, res, [W.ODelete{x}], prim, X.Fold{s, ks, g})
    == X.Fold.rel(r, res, [W.ODelete{x}], prim, X.Fold{s, ks, g}) : X.Fold}

# A watch on another cluster runs under the controllers' leadership fence:
# no request to any cluster outlives the lease.
law cluster_keeps_fence:
  for h: String
  for p: U32
  for b: String
  for ca: K.Src
  for cert: K.Src
  for key: K.Src
  for tok: K.Src
  for ns: String
  for pl: Maybe<&2, Chan(Socket)>
  for lm: Maybe<&2, Chan(Unit)>
  for sn: String
  for fc: Maybe<&2, Chan(K.FenceMsg)>
  for main: K.Config
  {K.Config.fence(X.Cluster.of(main, Some{K.Config{h, p, b, ca, cert, key, tok, ns, pl, lm, sn, fc}}))
    == K.Config.fence(main) : Maybe<&2, Chan(K.FenceMsg)>}

# A primary on another cluster never borrows a connection pool: a pool
# holds connections to one server.
law cluster_drops_pool:
  for a: C.Api
  for h: String
  for p: U32
  for b: String
  for ca: K.Src
  for cert: K.Src
  for key: K.Src
  for tok: K.Src
  for ns: String
  for pl: Maybe<&2, Chan(Socket)>
  for lm: Maybe<&2, Chan(Unit)>
  for sn: String
  for fc: Maybe<&2, Chan(K.FenceMsg)>
  for main: K.Config
  {X.Spec.clusters(X.Spec.on(X.Spec.of(a), K.Config{h, p, b, ca, cert, key, tok, ns, pl, lm, sn, fc}), main)
    == [K.Config{h, p, b, ca, cert, key, tok, ns, None{}, lm, sn, K.Config.fence(main)}] : List<&2, K.Config>}

# Without a cluster of its own, every watch runs on the controllers' config.
law cluster_default_is_main:
  for a: C.Api
  for main: K.Config
  {X.Spec.clusters(X.Spec.of(a), main) == [main] : List<&2, K.Config>}

# A spec without its own reconcile timeout takes the manager's
# (Opts.with_timeout); with none set anywhere there is none.
law timeout_unset_takes_default:
  for a: C.Api
  for ms: U32
  {X.Spec.timeout_or(X.Spec.of(a), ms) == X.Spec.timeout(X.Spec.of(a), ms) : X.Spec}

# A spec's own timeout wins over the manager's.
law timeout_own_wins:
  for a: C.Api
  for d: U32
  {X.Spec.timeout_or(X.Spec.timeout(X.Spec.of(a), 500), d) == X.Spec.timeout(X.Spec.of(a), 500) : X.Spec}

# A copy in another namespace (or cluster) reconciles the primary its
# annotations name, in the namespace they name: a syncer's host object
# maps back to its virtual one (vcluster's object-namespace, object-name).
law annotated_triggers_named:
  for prim: S.Store
  {X.Rel.keys(X.RAnnotated{"src/ns", "src/name"}, C.Res{"", "v1", "Service", "services", True{}},
    J.Json.obj([J.KV{"metadata", J.Json.obj([J.KV{"name", J.JStr{"web-x-default-x-vc"}},
      J.KV{"namespace", J.JStr{"vc-host"}},
      J.KV{"annotations", J.Json.obj([J.KV{"src/ns", J.JStr{"default"}}, J.KV{"src/name", J.JStr{"web"}}])}])}]),
    prim)
    == ["default/web"] : List<&2, String>}

# Without the name annotation, an object names no primary.
law annotated_needs_name:
  for prim: S.Store
  {X.Rel.keys(X.RAnnotated{"src/ns", "src/name"}, C.Res{"", "v1", "Service", "services", True{}},
    J.Json.obj([J.KV{"metadata", J.Json.obj([J.KV{"name", J.JStr{"other"}},
      J.KV{"namespace", J.JStr{"vc-host"}},
      J.KV{"annotations", J.Json.obj([J.KV{"src/ns", J.JStr{"default"}}])}])}]), prim)
    == Nil{} : List<&2, String>}

# A related object under RMap is left, whole, to the controller's mapper.
law map_defers_to_mapper:
  for res: C.Res
  for o: J.Json
  for prim: S.Store
  {X.Rel.keys(X.RMap{}, res, o, prim) == [X.Mapped.mark() ++ J.Json.show(o)] : List<&2, String>}

# A fold's keys split into plain keys and the objects for the mapper, each
# with the related watch it came from.
law map_split_keeps_keys:
  {X.Mapped.split([X.Mapped.mark() ++ "{}", "ns/a"], 2)
    == X.Split{["ns/a"], [X.Mapped{2, "{}"}]} : X.Split}

# Webhooks (controller-runtime's admission and conversion answers)
# ---------------------------------------------------------------

# A denial without a code answers 403 with its message, for the request's
# uid, in the review's own apiVersion.
law admission_deny_is_403:
  for av: String
  for uid: String
  for m: String
  {A.Wh.admission_review(av, uid, A.Verdict.deny(m))
    == J.Json.obj([J.KV{"apiVersion", J.JStr{av}}, J.KV{"kind", J.JStr{"AdmissionReview"}},
      J.KV{"response", J.Json.obj([J.KV{"uid", J.JStr{uid}}, J.KV{"allowed", J.JBool{False{}}},
        J.KV{"status", J.Json.obj([J.KV{"code", J.JNum{"403"}}, J.KV{"message", J.JStr{m}}])}])}]) : J.Json}

# An allowed request without a patch carries no patch and no status.
law admission_allow_is_bare:
  for av: String
  for uid: String
  {A.Wh.admission_review(av, uid, A.Verdict.allow())
    == J.Json.obj([J.KV{"apiVersion", J.JStr{av}}, J.KV{"kind", J.JStr{"AdmissionReview"}},
      J.KV{"response", J.Json.obj([J.KV{"uid", J.JStr{uid}}, J.KV{"allowed", J.JBool{True{}}}])}]) : J.Json}

# A request without Content-Length or chunked framing has no body: it is
# complete at its blank line, not read to the end of the stream.
law request_without_length_is_done:
  {A.Rq.done(A.Rq.feed(A.Rq.init(), U.Utf8.encode("GET /x HTTP/1.1\r\nHost: h\r\n\r\n"))) == True{} : Bool}

# A request whose Content-Length is past the cap is refused before any of
# its body is read.
law request_declared_over_cap_refused:
  {A.Rq.too_big(A.Rq.feed(A.Rq.init(), U.Utf8.encode("POST / HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n")),
    A.Rq.max_bytes()) == True{} : Bool}

# Once a step of a batch asks to back off (here a line that does not
# parse), the rest of the batch is not applied: the driver reconnects from
# the version before it, so no event is skipped past a gap.
law watch_stops_at_a_bad_line:
  for rv: String
  for f: U32
  for first: Bool
  for m: String
  for o: J.Json
  {W.Watcher.steps([W.IEvent{C.WBad{m}}, W.IEvent{C.WModified{o}}], W.Step{W.WState{W.WWatch{rv}, f, first}, Nil{}, False{}})
    == W.Watcher.steps([W.IEvent{C.WBad{m}}], W.Step{W.WState{W.WWatch{rv}, f, first}, Nil{}, False{}}) : W.Step}


# Protobuf (the wire format, protobuf.dev/programming-guides/encoding)
# --------------------------------------------------------------------

# The spec's first example: field 1 holding 150 is 08 96 01.
law pb_varint_150:
  {Pr.Pb.encode(Pr.Pb.u32(1, 150)) == [8, 150, 1] : List<&2, U32>}

# The spec's string: field 2 holding "testing" is 12 07, then the bytes.
law pb_string_testing:
  {Pr.Pb.encode(Pr.Pb.str(2, "testing")) == [18, 7, 116, 101, 115, 116, 105, 110, 103] : List<&2, U32>}

# The spec's nested message: field 3 holding {1: 150} is 1a 03 08 96 01.
law pb_nested_message:
  {Pr.Pb.encode(Pr.Pb.msg(3, Pr.Pb.u32(1, 150))) == [26, 3, 8, 150, 1] : List<&2, U32>}

# The spec's packed field: 4 holding [3, 270, 86942] is 22 06 03 8e 02 9e a7 05.
law pb_packed_varints:
  {Pr.Pb.encode(Pr.Pb.packed(4, [Pr.W64{0, 3}, Pr.W64{0, 270}, Pr.W64{0, 86942}]))
    == [34, 6, 3, 142, 2, 158, 167, 5] : List<&2, U32>}

# proto3 sends no field for a default value.
law pb_defaults_omitted:
  {Pr.Pb.encode(List.concat(&2, Pr.PbField, [Pr.Pb.u32(1, 0), Pr.Pb.str(2, ""), Pr.Pb.bool(3, False{})]))
    == [] : List<&2, U32>}

# The largest uint64 (and int64 -1) takes ten bytes, the last holding one bit.
law pb_varint_max:
  {Pr.Pb.varint(Pr.W64{4294967295, 4294967295}) == [255, 255, 255, 255, 255, 255, 255, 255, 255, 1] : List<&2, U32>}

# An int32 of -1 is sign-extended: ten bytes, as for int64 -1.
law pb_int32_negative:
  {Pr.Pb.encode(Pr.Pb.u64(1, Pr.Pb.int32(4294967295)))
    == [8, 255, 255, 255, 255, 255, 255, 255, 255, 255, 1] : List<&2, U32>}

# The spec's zigzag table: 0 -> 0, -1 -> 1, 1 -> 2, 2147483647 -> 4294967294,
# -2147483648 -> 4294967295; and back.
law pb_zigzag_table:
  {[Pr.Pb.zigzag(Pr.W64{0, 0}), Pr.Pb.zigzag(Pr.W64{4294967295, 4294967295}), Pr.Pb.zigzag(Pr.W64{0, 1}),
    Pr.Pb.zigzag(Pr.W64{0, 2147483647}), Pr.Pb.zigzag(Pr.W64{4294967295, 2147483648}),
    Pr.Pb.unzigzag(Pr.W64{0, 4294967295}), Pr.Pb.unzigzag(Pr.W64{0, 2})]
    == [Pr.W64{0, 0}, Pr.W64{0, 1}, Pr.W64{0, 2}, Pr.W64{0, 4294967294}, Pr.W64{0, 4294967295},
      Pr.W64{4294967295, 2147483648}, Pr.W64{0, 1}] : List<&2, Pr.W64>}

# fixed64 and fixed32 are little-endian.
law pb_fixed_little_endian:
  {Pr.Pb.encode([Pr.PbField{1, Pr.PF64{Pr.W64{16909060, 84281096}}}, Pr.PbField{2, Pr.PF32{16909060}}])
    == [9, 8, 7, 6, 5, 4, 3, 2, 1, 21, 4, 3, 2, 1] : List<&2, U32>}

# Decoding gives back each kind of field, unknown ones included, in order.
law pb_decode_fields:
  {Pr.Pb.decode([8, 150, 1, 9, 8, 7, 6, 5, 4, 3, 2, 1, 18, 2, 104, 105, 21, 4, 3, 2, 1, 160, 31, 0])
    == Done{[Pr.PbField{1, Pr.PVar{Pr.W64{0, 150}}}, Pr.PbField{1, Pr.PF64{Pr.W64{16909060, 84281096}}},
      Pr.PbField{2, Pr.PLen{[104, 105]}}, Pr.PbField{2, Pr.PF32{16909060}},
      Pr.PbField{500, Pr.PVar{Pr.W64{0, 0}}}]} : Result<&2, &2, String, List<&2, Pr.PbField>>}

# The largest uint64 decodes whole.
law pb_decode_varint_max:
  {Pr.Pb.decode([8, 255, 255, 255, 255, 255, 255, 255, 255, 255, 1])
    == Done{[Pr.PbField{1, Pr.PVar{Pr.W64{4294967295, 4294967295}}}]} : Result<&2, &2, String, List<&2, Pr.PbField>>}

# A scalar that came twice reads as the last; an absent one as its default.
law pb_last_value_wins:
  {[Pr.Pb.get_u32([Pr.PbField{1, Pr.PVar{Pr.W64{0, 1}}}, Pr.PbField{1, Pr.PVar{Pr.W64{0, 2}}}], 1),
    Pr.Pb.get_u32([Pr.PbField{1, Pr.PVar{Pr.W64{0, 1}}}], 2)] == [2, 0] : List<&2, U32>}

# A repeated scalar reads the same packed or not.
law pb_packed_or_not:
  {Pr.Pb.all_u64([Pr.PbField{4, Pr.PLen{[3, 142, 2]}}, Pr.PbField{4, Pr.PVar{Pr.W64{0, 9}}}], 4)
    == Done{[Pr.W64{0, 3}, Pr.W64{0, 270}, Pr.W64{0, 9}]} : Result<&2, &2, String, List<&2, Pr.W64>>}

# A message that ends inside a field is refused.
law pb_refuses_truncated:
  {[Pr.Pb.decode([8]), Pr.Pb.decode([18, 3, 1, 2]), Pr.Pb.decode([13, 1, 2])]
    == [Fail{"the message ends inside a field"}, Fail{"the message ends inside a field"},
      Fail{"the message ends inside a field"}] : List<&2, Result<&2, &2, String, List<&2, Pr.PbField>>>}

# Groups, field number 0 and a varint past ten bytes are refused.
law pb_refuses_malformed:
  {[Pr.Pb.decode([11]), Pr.Pb.decode([0, 1]), Pr.Pb.decode([8, 128, 128, 128, 128, 128, 128, 128, 128, 128, 128, 1])]
    == [Fail{"wire type 3, 4, 6 or 7 is not supported"}, Fail{"field number 0"},
      Fail{"a varint longer than 10 bytes"}] : List<&2, Result<&2, &2, String, List<&2, Pr.PbField>>>}

# A map<string, string> is one entry message per pair, key 1 and value 2.
law pb_str_map_entries:
  {Pr.Pb.encode(Pr.Pb.str_map(1, [Pr.PbStr{"a", "b"}])) == [10, 6, 10, 1, 97, 18, 1, 98] : List<&2, U32>}

# HPACK (RFC 7541)
# ----------------

# RFC 7541 C.1: 10 and 1337 with a 5-bit prefix, 42 with an 8-bit one.
law hpack_c1_integers:
  {[Hp.Hp.int(0, 31, 10), Hp.Hp.int(0, 31, 1337), Hp.Hp.int(0, 255, 42)]
    == [[10], [31, 154, 10], [42]] : List<&2, List<&2, U32>>}

# RFC 7541 C.2.1: a literal with indexing enters the table.
law hpack_c2_1_literal_indexed:
  {Hp.Hp.decode_seq(Hp.Hp.dec_new(4096, 65536), [[64, 10, 99, 117, 115, 116, 111, 109, 45, 107, 101, 121, 13, 99, 117, 115, 116, 111, 109, 45, 104, 101, 97, 100, 101, 114]])
    == Done{Hp.HSeq{[[H.Header{"custom-key", "custom-header"}]], [H.Header{"custom-key", "custom-header"}], 55}} : Result<&2, &2, String, Hp.HSeq>}

# RFC 7541 C.2.2: a literal without indexing leaves the table empty.
law hpack_c2_2_literal_not_indexed:
  {Hp.Hp.decode_seq(Hp.Hp.dec_new(4096, 65536), [[4, 12, 47, 115, 97, 109, 112, 108, 101, 47, 112, 97, 116, 104]])
    == Done{Hp.HSeq{[[H.Header{":path", "/sample/path"}]], [], 0}} : Result<&2, &2, String, Hp.HSeq>}

# RFC 7541 C.2.3: a never-indexed literal leaves the table empty.
law hpack_c2_3_literal_never_indexed:
  {Hp.Hp.decode_seq(Hp.Hp.dec_new(4096, 65536), [[16, 8, 112, 97, 115, 115, 119, 111, 114, 100, 6, 115, 101, 99, 114, 101, 116]])
    == Done{Hp.HSeq{[[H.Header{"password", "secret"}]], [], 0}} : Result<&2, &2, String, Hp.HSeq>}

# RFC 7541 C.2.4: an indexed field from the static table.
law hpack_c2_4_indexed:
  {Hp.Hp.decode_seq(Hp.Hp.dec_new(4096, 65536), [[130]])
    == Done{Hp.HSeq{[[H.Header{":method", "GET"}]], [], 0}} : Result<&2, &2, String, Hp.HSeq>}

# RFC 7541 C.3: three requests without Huffman, one table across them.
law hpack_c3_requests_decode:
  {Hp.Hp.decode_seq(Hp.Hp.dec_new(4096, 65536), [[130, 134, 132, 65, 15, 119, 119, 119, 46, 101, 120, 97, 109, 112, 108, 101, 46, 99, 111, 109], [130, 134, 132, 190, 88, 8, 110, 111, 45, 99, 97, 99, 104, 101], [130, 135, 133, 191, 64, 10, 99, 117, 115, 116, 111, 109, 45, 107, 101, 121, 12, 99, 117, 115, 116, 111, 109, 45, 118, 97, 108, 117, 101]])
    == Done{Hp.HSeq{[[H.Header{":method", "GET"}, H.Header{":scheme", "http"}, H.Header{":path", "/"}, H.Header{":authority", "www.example.com"}], [H.Header{":method", "GET"}, H.Header{":scheme", "http"}, H.Header{":path", "/"}, H.Header{":authority", "www.example.com"}, H.Header{"cache-control", "no-cache"}], [H.Header{":method", "GET"}, H.Header{":scheme", "https"}, H.Header{":path", "/index.html"}, H.Header{":authority", "www.example.com"}, H.Header{"custom-key", "custom-value"}]], [H.Header{"custom-key", "custom-value"}, H.Header{"cache-control", "no-cache"}, H.Header{":authority", "www.example.com"}], 164}} : Result<&2, &2, String, Hp.HSeq>}

# RFC 7541 C.3, encoded: the same bytes from the same headers.
law hpack_c3_requests_encode:
  {Hp.Hp.encode_seq(Hp.Hp.enc_new(4096, False{}), [[H.Header{":method", "GET"}, H.Header{":scheme", "http"}, H.Header{":path", "/"}, H.Header{":authority", "www.example.com"}], [H.Header{":method", "GET"}, H.Header{":scheme", "http"}, H.Header{":path", "/"}, H.Header{":authority", "www.example.com"}, H.Header{"cache-control", "no-cache"}], [H.Header{":method", "GET"}, H.Header{":scheme", "https"}, H.Header{":path", "/index.html"}, H.Header{":authority", "www.example.com"}, H.Header{"custom-key", "custom-value"}]])
    == [[130, 134, 132, 65, 15, 119, 119, 119, 46, 101, 120, 97, 109, 112, 108, 101, 46, 99, 111, 109], [130, 134, 132, 190, 88, 8, 110, 111, 45, 99, 97, 99, 104, 101], [130, 135, 133, 191, 64, 10, 99, 117, 115, 116, 111, 109, 45, 107, 101, 121, 12, 99, 117, 115, 116, 111, 109, 45, 118, 97, 108, 117, 101]] : List<&2, List<&2, U32>>}

# RFC 7541 C.4: the same requests, Huffman-coded.
law hpack_c4_requests_huffman_decode:
  {Hp.Hp.decode_seq(Hp.Hp.dec_new(4096, 65536), [[130, 134, 132, 65, 140, 241, 227, 194, 229, 242, 58, 107, 160, 171, 144, 244, 255], [130, 134, 132, 190, 88, 134, 168, 235, 16, 100, 156, 191], [130, 135, 133, 191, 64, 136, 37, 168, 73, 233, 91, 169, 125, 127, 137, 37, 168, 73, 233, 91, 184, 232, 180, 191]])
    == Done{Hp.HSeq{[[H.Header{":method", "GET"}, H.Header{":scheme", "http"}, H.Header{":path", "/"}, H.Header{":authority", "www.example.com"}], [H.Header{":method", "GET"}, H.Header{":scheme", "http"}, H.Header{":path", "/"}, H.Header{":authority", "www.example.com"}, H.Header{"cache-control", "no-cache"}], [H.Header{":method", "GET"}, H.Header{":scheme", "https"}, H.Header{":path", "/index.html"}, H.Header{":authority", "www.example.com"}, H.Header{"custom-key", "custom-value"}]], [H.Header{"custom-key", "custom-value"}, H.Header{"cache-control", "no-cache"}, H.Header{":authority", "www.example.com"}], 164}} : Result<&2, &2, String, Hp.HSeq>}

# RFC 7541 C.4, encoded with Huffman.
law hpack_c4_requests_huffman_encode:
  {Hp.Hp.encode_seq(Hp.Hp.enc_new(4096, True{}), [[H.Header{":method", "GET"}, H.Header{":scheme", "http"}, H.Header{":path", "/"}, H.Header{":authority", "www.example.com"}], [H.Header{":method", "GET"}, H.Header{":scheme", "http"}, H.Header{":path", "/"}, H.Header{":authority", "www.example.com"}, H.Header{"cache-control", "no-cache"}], [H.Header{":method", "GET"}, H.Header{":scheme", "https"}, H.Header{":path", "/index.html"}, H.Header{":authority", "www.example.com"}, H.Header{"custom-key", "custom-value"}]])
    == [[130, 134, 132, 65, 140, 241, 227, 194, 229, 242, 58, 107, 160, 171, 144, 244, 255], [130, 134, 132, 190, 88, 134, 168, 235, 16, 100, 156, 191], [130, 135, 133, 191, 64, 136, 37, 168, 73, 233, 91, 169, 125, 127, 137, 37, 168, 73, 233, 91, 184, 232, 180, 191]] : List<&2, List<&2, U32>>}

# RFC 7541 C.5: three responses in a 256-byte table, which evicts.
law hpack_c5_responses_decode:
  {Hp.Hp.decode_seq(Hp.Hp.dec_new(256, 65536), [[72, 3, 51, 48, 50, 88, 7, 112, 114, 105, 118, 97, 116, 101, 97, 29, 77, 111, 110, 44, 32, 50, 49, 32, 79, 99, 116, 32, 50, 48, 49, 51, 32, 50, 48, 58, 49, 51, 58, 50, 49, 32, 71, 77, 84, 110, 23, 104, 116, 116, 112, 115, 58, 47, 47, 119, 119, 119, 46, 101, 120, 97, 109, 112, 108, 101, 46, 99, 111, 109], [72, 3, 51, 48, 55, 193, 192, 191], [136, 193, 97, 29, 77, 111, 110, 44, 32, 50, 49, 32, 79, 99, 116, 32, 50, 48, 49, 51, 32, 50, 48, 58, 49, 51, 58, 50, 50, 32, 71, 77, 84, 192, 90, 4, 103, 122, 105, 112, 119, 56, 102, 111, 111, 61, 65, 83, 68, 74, 75, 72, 81, 75, 66, 90, 88, 79, 81, 87, 69, 79, 80, 73, 85, 65, 88, 81, 87, 69, 79, 73, 85, 59, 32, 109, 97, 120, 45, 97, 103, 101, 61, 51, 54, 48, 48, 59, 32, 118, 101, 114, 115, 105, 111, 110, 61, 49]])
    == Done{Hp.HSeq{[[H.Header{":status", "302"}, H.Header{"cache-control", "private"}, H.Header{"date", "Mon, 21 Oct 2013 20:13:21 GMT"}, H.Header{"location", "https://www.example.com"}], [H.Header{":status", "307"}, H.Header{"cache-control", "private"}, H.Header{"date", "Mon, 21 Oct 2013 20:13:21 GMT"}, H.Header{"location", "https://www.example.com"}], [H.Header{":status", "200"}, H.Header{"cache-control", "private"}, H.Header{"date", "Mon, 21 Oct 2013 20:13:22 GMT"}, H.Header{"location", "https://www.example.com"}, H.Header{"content-encoding", "gzip"}, H.Header{"set-cookie", "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1"}]], [H.Header{"set-cookie", "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1"}, H.Header{"content-encoding", "gzip"}, H.Header{"date", "Mon, 21 Oct 2013 20:13:22 GMT"}], 215}} : Result<&2, &2, String, Hp.HSeq>}

# RFC 7541 C.5, encoded.
law hpack_c5_responses_encode:
  {Hp.Hp.encode_seq(Hp.Hp.enc_new(256, False{}), [[H.Header{":status", "302"}, H.Header{"cache-control", "private"}, H.Header{"date", "Mon, 21 Oct 2013 20:13:21 GMT"}, H.Header{"location", "https://www.example.com"}], [H.Header{":status", "307"}, H.Header{"cache-control", "private"}, H.Header{"date", "Mon, 21 Oct 2013 20:13:21 GMT"}, H.Header{"location", "https://www.example.com"}], [H.Header{":status", "200"}, H.Header{"cache-control", "private"}, H.Header{"date", "Mon, 21 Oct 2013 20:13:22 GMT"}, H.Header{"location", "https://www.example.com"}, H.Header{"content-encoding", "gzip"}, H.Header{"set-cookie", "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1"}]])
    == [[72, 3, 51, 48, 50, 88, 7, 112, 114, 105, 118, 97, 116, 101, 97, 29, 77, 111, 110, 44, 32, 50, 49, 32, 79, 99, 116, 32, 50, 48, 49, 51, 32, 50, 48, 58, 49, 51, 58, 50, 49, 32, 71, 77, 84, 110, 23, 104, 116, 116, 112, 115, 58, 47, 47, 119, 119, 119, 46, 101, 120, 97, 109, 112, 108, 101, 46, 99, 111, 109], [72, 3, 51, 48, 55, 193, 192, 191], [136, 193, 97, 29, 77, 111, 110, 44, 32, 50, 49, 32, 79, 99, 116, 32, 50, 48, 49, 51, 32, 50, 48, 58, 49, 51, 58, 50, 50, 32, 71, 77, 84, 192, 90, 4, 103, 122, 105, 112, 119, 56, 102, 111, 111, 61, 65, 83, 68, 74, 75, 72, 81, 75, 66, 90, 88, 79, 81, 87, 69, 79, 80, 73, 85, 65, 88, 81, 87, 69, 79, 73, 85, 59, 32, 109, 97, 120, 45, 97, 103, 101, 61, 51, 54, 48, 48, 59, 32, 118, 101, 114, 115, 105, 111, 110, 61, 49]] : List<&2, List<&2, U32>>}

# RFC 7541 C.6: the same responses, Huffman-coded.
law hpack_c6_responses_huffman_decode:
  {Hp.Hp.decode_seq(Hp.Hp.dec_new(256, 65536), [[72, 130, 100, 2, 88, 133, 174, 195, 119, 26, 75, 97, 150, 208, 122, 190, 148, 16, 84, 212, 68, 168, 32, 5, 149, 4, 11, 129, 102, 224, 130, 166, 45, 27, 255, 110, 145, 157, 41, 173, 23, 24, 99, 199, 143, 11, 151, 200, 233, 174, 130, 174, 67, 211], [72, 131, 100, 14, 255, 193, 192, 191], [136, 193, 97, 150, 208, 122, 190, 148, 16, 84, 212, 68, 168, 32, 5, 149, 4, 11, 129, 102, 224, 132, 166, 45, 27, 255, 192, 90, 131, 155, 217, 171, 119, 173, 148, 231, 130, 29, 215, 242, 230, 199, 179, 53, 223, 223, 205, 91, 57, 96, 213, 175, 39, 8, 127, 54, 114, 193, 171, 39, 15, 181, 41, 31, 149, 135, 49, 96, 101, 192, 3, 237, 78, 229, 177, 6, 61, 80, 7]])
    == Done{Hp.HSeq{[[H.Header{":status", "302"}, H.Header{"cache-control", "private"}, H.Header{"date", "Mon, 21 Oct 2013 20:13:21 GMT"}, H.Header{"location", "https://www.example.com"}], [H.Header{":status", "307"}, H.Header{"cache-control", "private"}, H.Header{"date", "Mon, 21 Oct 2013 20:13:21 GMT"}, H.Header{"location", "https://www.example.com"}], [H.Header{":status", "200"}, H.Header{"cache-control", "private"}, H.Header{"date", "Mon, 21 Oct 2013 20:13:22 GMT"}, H.Header{"location", "https://www.example.com"}, H.Header{"content-encoding", "gzip"}, H.Header{"set-cookie", "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1"}]], [H.Header{"set-cookie", "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1"}, H.Header{"content-encoding", "gzip"}, H.Header{"date", "Mon, 21 Oct 2013 20:13:22 GMT"}], 215}} : Result<&2, &2, String, Hp.HSeq>}

# RFC 7541 C.6, encoded with Huffman.
law hpack_c6_responses_huffman_encode:
  {Hp.Hp.encode_seq(Hp.Hp.enc_new(256, True{}), [[H.Header{":status", "302"}, H.Header{"cache-control", "private"}, H.Header{"date", "Mon, 21 Oct 2013 20:13:21 GMT"}, H.Header{"location", "https://www.example.com"}], [H.Header{":status", "307"}, H.Header{"cache-control", "private"}, H.Header{"date", "Mon, 21 Oct 2013 20:13:21 GMT"}, H.Header{"location", "https://www.example.com"}], [H.Header{":status", "200"}, H.Header{"cache-control", "private"}, H.Header{"date", "Mon, 21 Oct 2013 20:13:22 GMT"}, H.Header{"location", "https://www.example.com"}, H.Header{"content-encoding", "gzip"}, H.Header{"set-cookie", "foo=ASDJKHQKBZXOQWEOPIUAXQWEOIU; max-age=3600; version=1"}]])
    == [[72, 130, 100, 2, 88, 133, 174, 195, 119, 26, 75, 97, 150, 208, 122, 190, 148, 16, 84, 212, 68, 168, 32, 5, 149, 4, 11, 129, 102, 224, 130, 166, 45, 27, 255, 110, 145, 157, 41, 173, 23, 24, 99, 199, 143, 11, 151, 200, 233, 174, 130, 174, 67, 211], [72, 131, 100, 14, 255, 193, 192, 191], [136, 193, 97, 150, 208, 122, 190, 148, 16, 84, 212, 68, 168, 32, 5, 149, 4, 11, 129, 102, 224, 132, 166, 45, 27, 255, 192, 90, 131, 155, 217, 171, 119, 173, 148, 231, 130, 29, 215, 242, 230, 199, 179, 53, 223, 223, 205, 91, 57, 96, 213, 175, 39, 8, 127, 54, 114, 193, 171, 39, 15, 181, 41, 31, 149, 135, 49, 96, 101, 192, 3, 237, 78, 229, 177, 6, 61, 80, 7]] : List<&2, List<&2, U32>>}

# Huffman padding is under 8 bits and all 1s, and EOS never appears.
law hpack_huffman_refusals:
  {[Hp.Hp.unhuff([0]), Hp.Hp.unhuff([255]), Hp.Hp.unhuff([255, 255, 255, 255]), Hp.Hp.unhuff([7])]
    == [Fail{"bad Huffman padding"}, Fail{"bad Huffman padding"}, Fail{"EOS inside a Huffman string"},
      Done{"0"}] : List<&2, Result<&2, &2, String, String>>}

# An index with no entry, a size update past the limit or after a header,
# an integer past 2^28 and a block that ends inside a field are refused.
law hpack_decode_refusals:
  {[Hp.Hp.decode_seq(Hp.Hp.dec_new(4096, 65536), [[128]]),
    Hp.Hp.decode_seq(Hp.Hp.dec_new(4096, 65536), [[190]]),
    Hp.Hp.decode_seq(Hp.Hp.dec_new(4096, 65536), [[63, 226, 31]]),
    Hp.Hp.decode_seq(Hp.Hp.dec_new(4096, 65536), [[130, 32]]),
    Hp.Hp.decode_seq(Hp.Hp.dec_new(4096, 65536), [[255, 255, 255, 255, 255, 1]]),
    Hp.Hp.decode_seq(Hp.Hp.dec_new(4096, 65536), [[64, 1]])]
    == [Fail{"no table entry at index 0"}, Fail{"no table entry at index 62"},
      Fail{"a table size update past the limit"}, Fail{"a table size update after a header"},
      Fail{"an integer past 2^28"}, Fail{"the header block ends inside a field"}]
    : List<&2, Result<&2, &2, String, Hp.HSeq>>}

# A header list is capped, each header counting its name, value and 32,
# so a few indexed bytes cannot expand without bound; so is a string.
law hpack_list_capped:
  {[Hp.Hp.decode_seq(Hp.Hp.dec_new(4096, 100), [[130, 130, 130]]),
    Hp.Hp.decode_seq(Hp.Hp.dec_new(4096, 10), [[0, 11]])]
    == [Fail{"the header list is larger than its limit"},
      Fail{"a string of 11 bytes is longer than the header list's limit"}]
    : List<&2, Result<&2, &2, String, Hp.HSeq>>}

# A size update shrinks the table at once; growing it back keeps it empty.
law hpack_size_update_evicts:
  {Hp.Hp.decode_seq(Hp.Hp.dec_new(4096, 65536), [[64, 1, 97, 1, 98], [32, 63, 225, 31, 130]])
    == Done{Hp.HSeq{[[H.Header{"a", "b"}], [H.Header{":method", "GET"}]], [], 0}} : Result<&2, &2, String, Hp.HSeq>}

# When the peer shrinks the table and grows it again, the next block
# signals both, the smallest first, so the tables stay in step.
law hpack_encoder_signals_resize:
  {Hp.Hp.encode_seq(Hp.Hp.enc_resize(Hp.Hp.enc_resize(Hp.Hp.enc_new(4096, False{}), 0), 4096),
    [[H.Header{":method", "GET"}]]) == [[32, 63, 225, 31, 130]] : List<&2, List<&2, U32>>}
