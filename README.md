# bend-kube

A Kubernetes client and controller runtime in [Bend](https://bend-lang.com).
Its design follows [kube-rs](https://github.com/kube-rs/kube): a pure core
of kube-core, a client and a runtime. How it talks to the API follows
[client-go](https://github.com/kubernetes/client-go): reflector relists,
workqueue semantics, Lease leader election and token rotation. Clone
those two beside the code as `kube/` and `client-go/` to read along; git
ignores them.

The rules that matter are stated as laws in `LAWS.bend` and proven in
`PROOF.bend`; `bend PROOF.bend` gates every commit and image build.

It is published on BendHub as `bend-kube-runtime` (the hub auctions
names under 12 characters), so a controller imports it by name and
version; `bend` fetches and caches the package (in `~/.bend/lib`) on first
use, checking every file against its hash:

<!-- x-release-please-start-version -->
```python
import Base
import bend-kube-runtime@0.8.0.0/src/json.bend as J
import bend-kube-runtime@0.8.0.0/src/core.bend as C
import bend-kube-runtime@0.8.0.0/src/config.bend as K
import bend-kube-runtime@0.8.0.0/src/queue.bend as Q
import bend-kube-runtime@0.8.0.0/src/control.bend as X
import bend-kube-runtime@0.8.0.0/src/kube.bend as Kb

def reconcile(o: J.Json, c: X.Ctx) -> IO(Q.Action):
  # make the world match o, idempotently, reading the caches through c
  # (X.Ctx.cfg, X.Ctx.children, X.Ctx.find); then say when to look again
  IO.pure(Q.Action, Q.Requeue{300000})

# ConfigMaps, reconciled on spec changes (none for ConfigMaps: every change),
# owning Deployments.
def spec() -> X.Spec:
  X.Spec.filter(X.Spec.owns(X.Spec.of(C.Api{C.Res.config_maps(), C.InNs{"default"}}),
    C.Api{C.Res.deployments(), C.InNs{"default"}}), [X.PGeneration{}])

def main() -> IO(Unit):
  Kb.Kube.control(~reconcile, spec(),
    Kb.Opts.with_election(Kb.Opts.default(), "default", "my-controller"))
```
<!-- x-release-please-end -->

The hub wants four-number versions: release `vX.Y.Z` is
`bend-kube-runtime@X.Y.Z.0`. Inside this repo, the examples import `../src/`.

## Layout

| bend-kube | kube-rs / client-go counterpart | pure? |
|---|---|---|
| `src/json.bend` | serde_json (arbitrary precision) | yes |
| `src/yaml.bend` | serde_yaml (the block YAML kubeconfigs use) | yes |
| `src/typed.bend` + `tools/gen.py` | k8s-openapi and kube-derive: typed records from OpenAPI or CRD schemas | yes |
| `src/utf8.bend`, `src/base64.bend`, `src/time.bend` | std / chrono | yes |
| `src/http.bend` | hyper's HTTP/1.1 codec | yes |
| `src/ws.bend` | WebSocket framing (RFC 6455) | yes |
| `src/core.bend` | kube-core: `ApiResource`, `Request`, params, `WatchEvent`, `Status`, `ObjectRef` | yes |
| `src/config.bend` | kube-client `Config`, kubeconfig, in-cluster | yes |
| `src/watcher.bend` | kube-runtime `watcher`, client-go `Reflector` | yes |
| `src/store.bend` | kube-runtime `reflector::Store` | yes |
| `src/queue.bend` | client-go `workqueue`, kube-runtime `scheduler` | yes |
| `src/control.bend` | kube-runtime `Controller` builder, `predicates`, trigger mappers; controller-runtime `Watches` | yes |
| `src/lease.bend` | client-go `leaderelection.tryAcquireOrRenew` | yes |
| `src/finalizer.bend` | kube-runtime `finalizer` (decisions) | yes |
| `src/proxy.bend` | Go's `ProxyFromEnvironment` and the CONNECT exchange | yes |
| `src/admission.bend` | controller-runtime `admission.Response`, `conversion` reviews, request framing | yes |
| `src/net.bend` + `src/effs/tls.c` | rustls / crypto/tls (OpenSSL via `dlopen`) | effect |
| `src/sys.bend` + `src/effs/sys.c` | wall clock, SIGTERM | effect |
| `src/client.bend` | kube-client `Client`, `Api<K>` verbs | IO |
| `src/stream.bend` | kube-client `log_stream`: a streaming GET, such as a followed pod log | IO |
| `src/exec.bend` | kube-client `exec` (`v5.channel.k8s.io` over WebSocket) | IO |
| `src/runtime.bend` | kube-runtime `Controller` | IO |
| `src/leader.bend` | client-go `leaderelection.RunOrDie` | IO |
| `src/helpers.bend` | kube-runtime `finalizer()`, client-go `EventRecorder` | IO |
| `src/serve.bend` | controller-runtime `/healthz` `/readyz` `/metrics` | IO |
| `src/webhook.bend` | controller-runtime `webhook.Server` (HTTPS) | IO |
| `src/log.bend` | structured JSON logs | IO |
| `src/kube.bend` | the `kube` facade: `Kube.run` | IO |

`tools/y2j.bend` converts YAML to JSON with the same reader. `tools/order.py`
and `tools/fix_plus.py` keep Bend files in the order and form the checker
wants.

Every decision is made by a pure module and every effect is performed by
an IO module. `ci.sh` makes sure no effect leaks into a pure module, so the
laws can range over all of the controller's logic.

## Behavior

**Watching** (client-go's reflector, kube-runtime's watcher):

- It lists in pages (`limit=500`, `continue`), then watches from the list's
  `resourceVersion` with `allowWatchBookmarks` and `timeoutSeconds=290`.
- A watch that ends resumes from the last version seen. A 410 Gone, whether
  on a watch event, a watch request or a continue token, relists from
  scratch at once.
- Other failures back off exponentially (800ms doubling to 30s, plus up to
  50% jitter); success resets it. A watch stream that is cut off, or that
  ends without a whole response, counts as a failure. Only the server's
  orderly end resumes at once, so a flapping server or load balancer isn't
  hammered.
- Failures are logged with their reason: the API status, or the network
  error.
- `resourceVersion` is opaque: it is copied and never compared.

**Caching:** a relist builds a fresh buffer between Init and InitDone and
swaps it in whole, so objects deleted while the watch was down disappear.
Objects are cached without `metadata.managedFields` (the server-side apply
bookkeeping, often half an object's size) and without the
`kubectl.kubernetes.io/last-applied-configuration` annotation (a whole
copy of what kubectl applied, a Secret's data included). These are the
transforms kube-rs and controller-runtime users apply by hand.

**Controllers** (`src/control.bend`; kube-runtime's `Controller` builder):
`X.Spec.of(api)` names the primary, and
`Kube.control(~rec, spec, opts)` runs it with `rec(obj, ctx)`:

- `X.Spec.owns(s, api)` watches objects the primary owns. To narrow the
  watch by label, use `X.Spec.watches_where(s, api, label, "", X.ROwner{})`. An event on one
  (deletions included) queues the owners it names that have the primary's
  kind and API group.
  - A namespaced primary is looked up in the child's namespace.
  - A cluster-scoped primary is looked up by name alone.
- `X.Spec.watches(s, api, rel)` watches any related kind, mapped to
  primaries by a relation. The relation is applied to the object as cached
  before the change and as it is after, so if the link moves, the old
  primary and the new one both reconcile:
  - `X.ROwner{}`: owner references.
  - `X.RLabel{key}`: a label names the primary.
  - `X.RRef{path}`: a field of the primary (a string, or a list of strings)
    names the object. An example is a Secret named in `spec.secretName`.
  - `X.RAll{}`: every primary in the object's namespace.
  - `X.RAnnotated{ns_key, name_key}`: two annotations name the primary's
    namespace (the object's own when that one is missing) and name. A
    syncer's copy in another namespace or cluster maps back this way, as
    vcluster's `vcluster.loft.sh/object-namespace` and `object-name` do.
  - `X.RMap{}`: the controller's own mapper names them (kube-runtime's
    `watches(.., mapper)`). Run it with
    `Kb.Kube.control_mapped(~rec, ~map, spec, opts)` (or
    `control_all_mapped`); `map(n, obj, ctx)` is pure and answers the
    primary keys (`"ns/name"`, or `"name"`) that an object of the n-th
    related watch triggers, with the caches in `ctx`. It sees each object
    as it is and as it was cached, so a link that moves wakes both ends.

  When a related watch relists, objects that vanished while it was down
  reconcile the primaries they mapped to. `X.Spec.watches_where(s, api,
  label, field, rel)` adds label and field selectors.

  `X.Spec.drop(s, ["data", "stringData"])` keeps top-level fields of the
  last related watch out of its cache. A controller that only needs to
  know a referenced Secret changed then holds no Secret's data; it reads
  what it needs with `Client.get`.

  `X.Spec.watch_filter(s, preds)` filters the last related watch with the
  same predicates `X.Spec.filter` gives the primary (below). A change
  triggers its primaries only when what the predicates see differs from
  the cached object. Deletions, objects a relist drops, a new uid, the
  start of a deletion and a change of finalizers always trigger. Without
  it, every change triggers.
- **Other clusters.** `X.Spec.watch_on(s, cfg)` runs the last related
  watch against another cluster, and `X.Spec.on(s, cfg)` runs the primary
  there. A syncer can then watch its primaries in one cluster and their
  copies in another, mapping each copy back by label (`X.RLabel{key}`).
  `X.Ctx.cluster(ctx, n)` gives the reconcile the config of watch n (0 the
  primary, n the n-th related watch); `X.Ctx.cfg` stays the controllers'
  own config, which holds the lease.
  - The same resource and selectors on two clusters are two watches. On
    one cluster, as the same user, they are one watch shared by every
    controller.
  - Under leader election every config takes the controllers' leadership
    fence, so no request to any cluster outlives the lease.
  - Each other cluster gets one connection pool, shared by every watch and
    reconcile that talks to it as the same user. A pool holds connections
    to one server, so a pool the config carried is dropped.
    `Kb.Kube.connect(cfg, qps, burst)` gives it its own rate limit.
  - Watch logs (`listing`, list and watch failures, backoff) carry a
    `server` field: the API server's URL, and its `tls-server-name` when set.
- `X.Spec.filter(s, preds)` (kube-runtime's `predicate_filter`): a primary
  change reconciles only when one of these differs from the cached object:
  `X.PGeneration{}` (the spec), `X.PLabels{}`, `X.PAnnotations{}` or
  `X.PFinalizers{}`. So with `[X.PGeneration{}]`, a controller's own status
  writes don't wake it.
  - An object the cache hasn't seen always passes, and so does one
    recreated under the same name (a new uid).
  - A deletion that starts always passes, and so does a change of
    finalizers. A controller that adds its finalizer and waits is therefore
    woken by the change.
  - An object without a generation (a ConfigMap) passes on every change.
  - An unchanged relist is quiet.

  Requeues and retries are not filtered.
- `X.Spec.label` and `X.Spec.field` set the primary's selectors.
  `X.Spec.max` sets how many reconciles run at once (default 8, at least 1).
- `X.Spec.timeout(s, ms)` treats a reconcile still running after ms as
  hung. The process logs it and exits with status 1, so the pod restarts as
  after a crash. A Bend computation can't be cancelled, and freeing the key
  while the late run continued would let the same key run twice.
  - The default is no limit, as in controller-runtime and kube-runtime.
    `Kb.Opts.with_timeout(o, ms)` sets one for every spec that sets none
    (controller-runtime's manager-wide `ReconciliationTimeout`); a spec's
    own wins.
  - One watchdog per controller keeps the timeout: each reconcile tells it
    when it starts and ends, and it checks on each message and at least
    once a second. A timeout costs two channel sends per reconcile, not a
    sleeper per reconcile, and fires within about a second of its deadline.
  - Without a limit, a hung reconcile holds its slot.
    `bendkube_reconcile_running` stuck at the maximum shows it.
- **Reconcile context:** `ctx` gives:
  - the client config (`X.Ctx.cfg`) and the controller's index
    (`X.Ctx.idx`);
  - how many times in a row this key has failed (`X.Ctx.fails`), so a
    reconcile can escalate or give up;
  - read-only snapshots of every cache: the primary's (`X.Ctx.get`,
    `X.Ctx.list`), and each related watch's, numbered from 1 in the order
    added (`X.Ctx.find`, `X.Ctx.all`). `X.Ctx.children(ctx, n, owner)`
    returns the objects the owner controls (`controller: true`, by uid).

  Reads from the cache aren't requests to the API server.
- No reconcile starts until every cache has listed, nor while any watch is
  midway through a relist. A key queued from an early page is reconciled
  against the new list once it is swapped in, never dropped against the
  old one. `/readyz` waits for every cache's first list.
- **Errors:** a reconcile answers `Retry{msg}` to back off, or
  `RetryIn{msg, ms}` when it chooses the delay itself. After a failed call,
  `Cl.KErr.action(e)` picks for it. It answers `RetryIn` with the delay the
  server named, and `Retry` otherwise. The delay is the Status body's
  `details.retryAfterSeconds`, else the `Retry-After` header (in seconds,
  so a proxy's plain 429 counts too), kept between 1s and 1000s like the
  key's own backoff; `Cl.KErr.retry_after` exposes it. Both are logged as
  warnings with the key and count as errors. `Hold{ms}` means "not done
  yet, look again after ms" and isn't an error. `Cl.KErr` has
  `is_conflict`, `is_not_found`, `is_already_exists` and `is_throttled`.
- **Status:** `src/cond.bend` keeps `status.conditions` as
  apimachinery's `meta.SetStatusCondition` does. `Cond.set` replaces a
  condition by type, and `lastTransitionTime` changes only when the status
  does. `Cond.get`, `Cond.is_true` and `Cond.patch` help write them with
  `Client.patch_status`. `Client.replace_status` puts the whole status.
- **Finalizers:** `Finalizer.control(~apply, ~cleanup, ctx, api, name, obj)`
  is kube-runtime's `finalizer()`, with callbacks that get the context. A
  cleanup that answers `Retry`, `RetryIn` or `Hold` keeps the finalizer, so
  a cleanup waiting on an external deletion holds the object without
  counting errors. Any other answer removes it.
- **Writes:** `Client.apply` forces conflicts, as a controller that owns
  its fields wants. `Client.apply_with(.., force, ..)` doesn't force, so a
  field another manager owns (an HPA's `spec.replicas`) fails with 409
  instead of being taken over.
  `Client.replace_retry(cfg, api, name, obj, tries)` is a PUT that survives
  write conflicts (client-go's `RetryOnConflict`): after a 409 it reads the
  object, takes its resourceVersion and puts again, up to `tries` more
  times. It overwrites what other writers changed in between, so keep it
  for objects one writer owns whole. On busy objects such as pods,
  `Client.apply` and `Client.patch` don't conflict on a version at all.
- **Deletes:** `Client.delete_with(cfg, api, name, C.DeleteOpts{..})` sets
  propagation (`Background`, `Foreground`, `Orphan`), a grace period, and
  uid or resourceVersion preconditions.
- `Kube.control_with(~rec, cfg, specs, opts)` runs controllers against a
  given config: another cluster, or a test server.

`Kube.run(~rec, primary, owned, opts)` remains, with `rec(obj, cfg)`; it is
`Kube.control` with owned watches and no predicates.

**Queueing** (client-go's workqueue):

- A key waits in the queue at most once.
- A key never runs on two workers at once. If it is added while it runs, it
  runs again when the current run ends.
- At most `X.Spec.max` (`Opts.max` for `Kube.run`) reconciles run
  concurrently.
- Errors back off per key, from 5ms doubling to at most 1000s.
- A delayed requeue is staled by any newer add.
- A key has at most one pending wake, the earliest asked for by the
  monotonic clock (kube-runtime's scheduler). A later or equal request
  starts no sleeper; only an earlier one starts another, and the outdone
  sleeper wakes to nothing when its time comes. Requeues of a key don't
  pile up timers; only strictly earlier wakes add one each. Delays of a
  second or more get up to 10% jitter, so requeues armed together spread
  out.
- When a key leaves the queue and its object is gone, its bookkeeping is
  forgotten. That covers objects deleted while their key ran or waited, and
  objects a relist dropped.
- A key whose object is gone frees its slot for the keys behind it.
- Nothing is reconciled until the first list completes.

**Many controllers, shared watches** (controller-runtime's Manager,
kube-runtime's shared reflectors): `Kube.control_all(~rec, [spec, ..],
opts)` (or the older `Kube.run_all(~rec, [Ctrl{..}, ..], opts)`) runs several
controllers in one process; `X.Ctx.idx(ctx)` names the one reconciling. Each has its own loop, store and
queue, but a watch two of them need (same resource, scope and label
selector) runs once and fans out to both. `examples/multi.bend` runs three
subscriptions on one list and watch. Metrics carry a
`controller="index/Kind"` label, and `/readyz` waits for every
controller's store.

**Owned objects** (`owns`): an event on an owned object queues its owners of
the primary kind, through `ownerReferences`. Deletions are included.

**Writes:** `Client.apply` is server-side apply (`fieldManager`, `force`).
Finalizer patches are JSON patches that `test` before they `add` or
`remove`, so they never clobber another controller's finalizer.

**Leader election** (client-go's defaults: 15s lease, 2s retry, 10s renew
deadline):

- Expiry is judged by this process's own clock, by when it last saw the
  record change. Remote timestamps are never compared.
- Each Lease read and write is bounded by what is left of the renew
  deadline. Lateness is judged by the clock after the calls return, so a
  hung write cannot keep a stale leader running. A renewal that lands only
  after the deadline also counts as lost, as in client-go. After a failed
  try, a leader waits at most what is left of its deadline, and checks the
  deadline before every read and every write and after every call. So it
  stops once the deadline is reached, whatever the retry period.
- After a success it also naps no further than the deadline. A write that
  lands past the deadline stops the process rather than starting or
  continuing work; an acquisition counts from when its read returned,
  before the winning write. Together with the startup rule that the lease
  outlasts the deadline by at least a second, a leader always stops before
  a standby can judge its Lease expired.
- **Leadership fence.** The leader loop shares Bend's event loop with every
  reconcile, so a long computation could delay its checks. A fence keeper
  therefore holds the last renewal, which the leader moves after each
  success. Immediately before every write of request bytes, the client asks
  the keeper. That covers a request's first send, a pooled send, a retry on
  a fresh connection, and exec's input. A write found past the renew
  deadline exits the process before the bytes leave. The keeper always
  answers, so a check never passes for want of a reading. Watches and log
  streams are reads; they go through the same send path and are fenced too.
  What remains is the single step between the check and the write effect
  that follows it: another computation could run there, and a long one
  could carry the write past the deadline. Kubernetes has no server-side
  fencing tokens, so client-side fencing can only narrow this, not close it.
  The 1s minimum margin between deadline and lease is the budget for it, so
  keep long pure computations out of reconciles.
- A Lease is observed when its read returns, and another holder's Lease
  lasts its own `leaseDurationSeconds`, so a slow read or a contender
  configured with a shorter duration can't expire a live leader.
- Lease calls bypass the client rate limit, so a burst of reconciles
  cannot delay a renewal.
- Lease writes go through `resourceVersion`, so of two contenders only one
  write lands.
- A leader that cannot renew within the deadline exits with status 1, so
  two leaders never act at once.
- SIGTERM drains (see Shutdown), then releases the Lease and exits with
  status 0, so failover takes milliseconds after the drain. The release
  reads the Lease afresh and retries if a renewal raced it (a 409), up to
  three times within 4s, and logs the outcome.
- Election timing is checked at startup, as client-go checks it, plus a
  margin. Every setting must be above zero, the lease must outlast the
  renew deadline by at least a second, and the deadline must exceed 1.2
  retry periods. Unsafe timing stops the
  process with the reason.
- `Opts.with_election(o, ns, name)` names each replica by its pod
  (`HOSTNAME`) plus a random suffix. Two replicas can't share an identity,
  which would let both renew. `Opts.with_lease(o, E.LOpts{..})` sets the
  identity, Lease duration, renew deadline and retry period by hand.
- Every timing decision (Lease expiry, the renew deadline, lateness)
  uses the monotonic clock, as client-go does. The wall clock only stamps
  the Lease, so stepping it either way changes nothing. Time that runs
  backwards still counts as none.

**Shutdown:** on SIGTERM or SIGINT, with or without leader election, every
controller stops starting reconciles. The process waits for the running
ones, up to `Opts.with_grace`, then exits with status 0.
- The default grace is 20s; with up to 4s to release the Lease, that fits
  Kubernetes' default 30s termination grace period.
- The Lease is released only after a clean drain. If a reconcile is still
  running at the deadline, the process exits holding the Lease, and the
  standby takes over when it expires, never alongside the old reconcile.
- A replica whose controllers never started (a standby) exits at once.
- A second signal exits at once, with status 1.

**Client rate limit** (client-go's token bucket): every request except a
watch takes a token from a bucket of `burst` tokens, refilled at `qps` a
second. The default is 50 qps with a burst of 100; set it with
`Opts.with_rate(o, qps, burst)`, where qps 0 turns the limit off.

**Typed resources:** `tools/gen.py` turns a CRD or a type in a Kubernetes
OpenAPI v3 document into Bend records with a decoder (`T.of`), an encoder
(`T.to`), `T.res()` and `T.api(scope)`. A decode error names the field's
path (`spec.replicas: expected an integer from 0 to 4294967295`).
Required fields are plain, optional ones are `Maybe`, lists are `List`.
An integer is `U32` only when its schema says `minimum >= 0`; otherwise,
like `int64` and floats, it keeps its exact text, so negative numbers and
large values round-trip. Also: and maps, int-or-string and
anything past `--depth` stay `J.Json`. `examples/website.bend` is a typed
operator: `Website` decodes into generated records, and `Deployment` can be
generated straight from the cluster's own OpenAPI.

**Connections:** `Kube.run` gives the client a pool of up to 8 idle
keep-alive HTTP/1.1 connections, as kube-rs's hyper client pools them.

- A connection goes back to the pool only after a response its framing
  ended, without `Connection: close`.
- A stale pooled connection is retried once on a fresh one, by Go's
  transport rule: retry when the request was not written, or when no
  response byte came and the method is GET, HEAD or PUT. A law states this
  rule. Unlike Go, a DELETE is never replayed: if the first one landed and
  the name was recreated, a replay would delete the replacement.
- 50 sequential GETs take 32ms pooled against 240ms with fresh
  connections.
- Watches hold their own connection.

**Auth:**

- `Config.infer` follows kube-rs: `$KUBECONFIG` (a single file or a merged
  `a:b` list), then the in-cluster service account, then `~/.kube/config`.
- Kubeconfigs are read natively, JSON or YAML, merged as client-go merges
  them. Relative paths resolve against each file's directory.
- Client certificates and CA bundles can be inline or in files. Bearer
  tokens can be inline, in a file, or from an exec plugin (EKS, GKE, AKS and
  OIDC plugins via `ExecCredential`). A plugin gets its `env` entries and
  `KUBERNETES_EXEC_INFO`.
- Token files and plugins are read again on every connection, so rotated
  service-account tokens are picked up.

**TLS:**

- The server is always verified against the given CA, or the system roots
  if none is given, and by name (or by IP for an IP literal), with TLS 1.2
  as the minimum. Only the certificate's SANs name the server, never its CN
  (as in Go), and an empty name is refused rather than left unchecked.
- A kubeconfig `*-data` field that is not base64 fails the connection
  (as client-go refuses the kubeconfig). Before 0.9 it meant "none", which
  for `certificate-authority-data` trusted the system roots.
- `tls-server-name` (client-go's `TLSClientConfig.ServerName`) is honored:
  the client connects to the server's host and verifies the certificate
  against that name, which it also sends as SNI. This is how a client
  behind NAT reaches a cluster whose certificate names `127.0.0.1` or
  `localhost`. `K.Config.with_server_name` sets it in code.
- `insecure-skip-tls-verify` is ignored.
- `HTTPS_PROXY` and `NO_PROXY` are read as Go reads them (client-go uses
  Go's `ProxyFromEnvironment`), in pure Bend (`src/proxy.bend`):
  - `HTTPS_PROXY` (or `https_proxy`) is an `http://` proxy (the scheme may
    be omitted), with percent-encoded `user:pass` sent as
    `Proxy-Authorization`. Other schemes fail the connection; they never
    fall back to a direct one.
  - `NO_PROXY` (or `no_proxy`) entries are separated by commas or spaces:
    `*`, `name` (the name and its subdomains), `.name` or `*.name`
    (subdomains only), IPv4 CIDRs, and `:port` to narrow an entry.
  - `localhost` and loopback addresses never use a proxy.
  - The proxy's answer must be a 200 with nothing after it. The connection
    then goes through the CONNECT tunnel, and TLS verification stays end
    to end with the API server.
- The effects only dial, handshake and move bytes (`Tls.dial`,
  `Tls.secure`, `Tls.send`, `Tls.send_bytes`, `Tls.recv`, `Tls.close`); see the trust
  boundary under Scope.
- Names resolve through DNS, and IPv6 is supported.
- The health server and the webhook server listen dual-stack (`::` with
  IPv4 mapped in, `Y.Sys.listen`), so they answer on IPv6-only and
  dual-stack clusters; IPv4 only on a host without IPv6, and on the JS
  lane.
- SIGPIPE is ignored, so a dead peer shows up as an error instead of
  killing the process.

**Logs and exec** (kube-client's `log_stream` and `exec`):

- `Stream.fold(~S, ~on, st, cfg, path, ms)` sends a GET on a connection of
  its own and folds every cut of the body into the state `st` with `on`
  as it is decoded, until the body ends; it answers the last state.
  `Stream.log_path(ns, pod, container, True{})` names a followed pod log,
  which ends when the container does. A status other than 200 fails with
  the Status message the body carries.
- `Exec.run(cfg, ns, pod, container, cmd, stdin, ms)` runs a command the
  way `kubectl exec` does: a WebSocket upgrade speaking
  `v5.channel.k8s.io`, the first version that can close stdin, so a
  command reading stdin to its end works. The input goes in one write,
  then stdin closes. Stdout, stderr and the final Status are collected
  (`Exec.ok`, `Exec.why`, `Exec.stdout`, `Exec.stderr`), so it suits short
  commands. A refused upgrade (for example 403 or 404) is a KApi error.
- Frames are decoded byte by byte (`src/ws.bend`), so frames split across
  reads, or several in one read, decode the same. Pings are not answered.

**Operations:**

- Logs are one JSON object per line on stderr.
- `/healthz`, `/readyz` and `/metrics` are served on `:8080`
  (`Opts.with_port`; the `BEND_KUBE_PORT` environment variable overrides
  it; 0 for none). `/readyz` answers:
  - 503 until every cache is synced;
  - `standby` on a replica that isn't the leader;
  - 503 if the status keeper does not answer within 2s.
- Each controller publishes its status at most once a second, whenever its
  readiness changes, and one second after it goes idle with changes
  unpublished.
- A health port that can't be bound exits the process.
- Events name the pod (`HOSTNAME`) as their reporting instance, and their
  note is cut to the API's 1 kB.
- Metrics: `bendkube_reconcile_total`, `bendkube_reconcile_errors_total`,
  `bendkube_reconcile_duration_seconds` (a histogram with Prometheus'
  default buckets), `bendkube_watch_events_total`,
  `bendkube_reconcile_running`, `bendkube_queue_depth`,
  `bendkube_store_objects` (the primary's cache),
  `bendkube_cache_objects{cache="n"}` (each related watch's cache),
  `bendkube_store_ready` and `bendkube_leader`.
  Counters are 32-bit and wrap; Prometheus reads a wrap as a reset.
- A controller's own metrics: `Metrics.add(ctx, name, labels, n)` adds to
  a counter and `Metrics.set(ctx, name, labels, v)` sets a gauge, from
  `src/helpers.bend`. `labels` is the inside of the braces, as
  `bundle="b1"`. `/metrics` serves them after bend-kube's own series.
  `examples/bundle.bend` counts its syncs this way. A series lives until
  `Metrics.drop(ctx, name, labels)` removes it, so drop series labeled by
  object when the object goes, or keep labels to a fixed set. The
  duration sum is kept in seconds and lasts 136 years. A duration made
  absurd by the wall clock stepping back counts as 0.
- Events go to `events.k8s.io/v1` (`Event.publish`).

**Webhooks:** `Wh.Webhook.serve(~admit, ~convert, port, cert, key)` serves
admission and conversion webhooks over HTTPS (controller-runtime's webhook
server), and `Wh.Webhook.admission(~admit, port, cert, key)` serves
admission only.
- `admit(path, request)` answers an `A.Verdict`: `A.Verdict.allow()`,
  `A.Verdict.deny(msg)` (403), `A.Verdict.deny_with(code, msg)`,
  `A.Verdict.patch(ops)` with JSON-patch operations (`A.Patch.op`), and
  `A.Verdict.warn(v, text)`. It may read the API server. The path routes
  between handlers (`/validate`, `/mutate`).
- `convert(obj, apiVersion)` is pure. It answers the object in the desired
  version, or why it can't be; one failure fails the whole review.
- `cert` and `key` are PEM file paths (a mounted Secret, such as
  cert-manager's `tls.crt` and `tls.key`). They are read for every
  connection, so a rotated certificate is served without a restart.
- Limits: at most 256 connections at once (more are closed as they
  arrive), 8 MiB per request (a larger Content-Length is refused with 413
  before its body is read), 10s for any one read, and 30s for a whole
  connection from its accept. A peer that stops sending mid-request is
  closed. When `accept` fails (out of descriptors), the server pauses 200
  ms rather than spin. An optimized build answers a pod-sized review in
  about 3 ms and a 2 MB one in about 1.2s.
- The TLS context is built once per certificate and key and rebuilt when
  the PEM text changes, so a handshake costs no PEM parsing. Renegotiation
  is off.
- `admit` has no deadline of its own: the API server gives up after the
  webhook's `timeoutSeconds` (at most 30), but a hung `admit` holds its
  connection slot. Keep it short, and give it its own timeout if it calls
  out.
- Put the webhook behind a NetworkPolicy that admits only the API server:
  it asks clients for no certificate.
  Webhooks answer on every replica: start the server with `IO.spawn` before
  `Kube.control`, not under leader election.
- The server side of TLS (`Tls.accept`) runs on the native lane only.

**Parallelism:** the watch lines that arrive in one read are separate JSON
documents. They are decoded and parsed as balanced Bend parallel calls
(`Drv.inputs.par`), and `tests/par_test.bend` checks that the result is the
same as the sequential one. Reconciles run concurrently on Bend's event
loop.

## Laws

`LAWS.bend` holds 79 laws, proven in `PROOF.bend` and accepted by both
`bend PROOF.bend` and `--verdict`, the Lean-proven kernel:

- **Watcher:**
  - a 410 on a watch event, a watch request or a continue token relists at
    once;
  - other errors back off and count the failure;
  - a watch that ends resumes from the same version;
  - bookmarks move the version;
  - the last page emits InitDone and starts the watch;
  - the first page emits Init;
  - backoff is capped at 30s.
- **Store:**
  - Init clears the buffer;
  - InitDone swaps the buffer in whole and marks the store ready.
- **Queue:**
  - adding a running key marks it dirty and doesn't queue it;
  - adding a waiting key deduplicates;
  - no key starts when every slot is taken;
  - `done` on a key that isn't running is a no-op;
  - `forget` never disturbs a running key;
  - retry backoff is capped at 1000s.
- **Finalizers:**
  - a live object with the finalizer is applied;
  - a deleted object without it is done;
  - a deleted object with it is cleaned up, and the finalizer is removed
    only through a `test`ed patch at its index.
- **Controllers:**
  - without predicates every change reconciles; with them, an uncached
    object always does;
  - under the generation predicate a status write (same generation, any
    version) does not, a new generation does, and so does the start of a
    deletion;
  - an object without a generation reconciles on every change;
  - an applied primary is cached and queued; a deleted one leaves the
    cache, queues nothing and is forgotten;
  - an owned object queues the owner it names of the primary's kind and
    API group, in its namespace;
  - a cluster-scoped owner is queued by name;
  - an owner of the same kind in another group queues nothing;
  - under any predicate, a change of finalizers reconciles.
  - an object recreated under the same name (a new uid) reconciles;
  - an `RMap` object is left whole to the mapper, with the watch it came
    from;
  - an object's annotations name the primary of `RAnnotated`, in the
    namespace they name, and without the name annotation none;
  - a related watch without predicates triggers on every change, and a
    filtered one still triggers on every deletion;
  - a watch on another cluster keeps the controllers' leadership fence and
    never borrows a connection pool; without a cluster of its own it runs
    on the controllers' config;
  - a spec without its own reconcile timeout takes the manager's, and its
    own wins.
- **Webhooks:**
  - a denial without a code answers 403 with its message, for the request's
    uid, in the review's apiVersion;
  - an allowed request without a patch carries no patch and no status;
  - a request without Content-Length or chunked framing has no body;
  - a request whose Content-Length is past the cap is refused before its
    body.
- **Leader election:**
  - another holder's Lease seen changing within its duration is live;
  - our clock stepping back doesn't expire it;
  - unchanged past its duration, it can be taken;
  - our own Lease is renewed, and a released one is free.
  - another holder's Lease lasts its own recorded duration;
  - the default timing is accepted; a lease no longer than its renew
    deadline is refused, and so is one that outlasts it by less than a
    second;
  - a leader is late once its deadline is reached, and never naps past it;
  - a write that lands past the deadline is overdue: a leader counts from
    its last renewal, an acquisition from the start of its attempt.
- **Finalizer cleanup:** a failed or held cleanup keeps the finalizer, and
  a finished one releases it.
- **Conditions:** setting a condition with an unchanged status keeps its
  `lastTransitionTime`; a new status moves it.
- **HTTP:** a connection that ends before any response byte is *lost*
  (safe to retry); one that ends mid-response is *broken* (never retried).
- **Proxies:**
  - `localhost` and loopback hosts never use a proxy, whatever the
    environment says;
  - `NO_PROXY=*` bypasses every host, and no `HTTPS_PROXY` means direct;
  - an unsupported proxy scheme fails rather than connecting directly;
  - `.corp` bypasses subdomains only, `corp` never matches `evilcorp`, and
    an entry's port narrows it;
  - only a 200 opens a tunnel, bytes after the answer fail it, and so does
    a proxy that hangs up first.

## Build, test, deploy

```sh
tools/ci.sh                      # laws, --verdict, module checks, tests, generated-code drift, builds, package, tls
tests/run.sh                     # unit and scenario tests (UPDATE=1 rewrites expectations)
tests/tls.sh                     # TLS and proxies against local servers, both lanes, sanitizers
tests/package.sh                 # publish to a stand-in hub, build a controller from the package
KUBECONFIG=test.yaml tests/e2e.sh   # on a disposable cluster: operator, finalizer, shared watches, cached reads, drain, rate limit, leader handover
./y2j crd.yaml > crd.json && tools/gen.py crd crd.json -o gen/my.bend   # typed CRD views (--lib bend-kube-runtime@X.Y.Z.0/src outside this repo)
cd examples && bend mirror.bend -o mirror && KUBECONFIG=~/.kube/config ./mirror
docker build --build-arg EXAMPLE=mirror -t bend-kube-mirror .   # proof-gated image
kubectl apply -f deploy/mirror.yaml
```

- **Bend version:** bend-kube needs Bend **2.0.40**. Bend's C effect interface
  has no ABI promise, so `tools/ci.sh` and the Dockerfile pin the version
  (the Dockerfile also checks the archive's sha256). Rebuild and rerun CI on
  every upgrade.
- **OpenSSL:** it is loaded at run time (`libssl.so.3` or `.1.1`, or
  Homebrew's on macOS). Set `BEND_KUBE_LIBSSL` and `BEND_KUBE_LIBCRYPTO` to
  override where it is found.
- **macOS SDK:** if clang's linker rejects the newest SDK, set `SDKROOT` to
  an older SDK.
- **`src/` changes:** run `tools/order.py FILE` after editing. Bend binds a
  def only after the defs it calls, and the script reorders defs to match.
  `tools/fix_plus.py FILE` marks reused binders with `+`.

## Releasing

Commits follow [Conventional Commits](https://www.conventionalcommits.org)
(`feat:`, `fix:`, `feat!:` …). `.github/workflows/ci.yml` runs
`tools/ci.sh` on every pull request and push, and
`.github/workflows/e2e.yml` runs `tests/e2e.sh` on a kind cluster for
every pull request. On each push to `master`,
`.github/workflows/release.yml` runs
[release-please](https://github.com/googleapis/release-please), which keeps
a release pull request up to date (version, `CHANGELOG.md`, the imports
above). Merging that pull request:

1. tags `vX.Y.Z` and makes a GitHub release;
2. reruns every gate on the tag;
3. publishes `package.bend` and everything it imports to BendHub as
   `bend-kube-runtime@X.Y.Z.0`. A publish is public and permanent.

Publishing needs the `BENDAI_KEY` repository secret: the `key` field of
`~/.bend/bendai.json` after `bend login`.

## Examples

- `examples/mirror.bend` keeps a `<name>-mirror` copy of every ConfigMap,
  owned by the original. It uses server-side apply, `owns`, leader election
  and requeues. `deploy/mirror.yaml` deploys two replicas with least-privilege
  RBAC, probes and a restricted security context.
- `examples/guard.bend` runs a finalizer and records Events on ConfigMaps
  selected by a label.
- `examples/noop.bend` is a scale baseline:
  - 20,018 ConfigMaps (586 bytes each as JSON) are listed, cached and
    reconciled in 2.6s, and the process then holds 204 MB RSS;
  - a further 2,000 updates are reconciled within 5s, and memory stays
    flat (208 MB).
- `examples/website.bend` is a typed operator: a generated `Website` CRD
  type, an owned Deployment, the status subresource, Warning events for
  invalid specs, and leader election. It uses `Kube.control` with the
  generation predicate, so its own status writes don't wake it.
  `deploy/website.yaml` runs it with cluster-scoped least-privilege RBAC.
- `examples/bundle.bend` reads from its caches and follows a reference. A
  labeled ConfigMap names a Secret in `data.secret`, and the controller
  keeps an owned ConfigMap listing that Secret's key names. Secrets are an
  `RRef` watch, so a change to the Secret reconciles the ConfigMap. The
  Secret is read from the cache, and the outputs are counted with
  `X.Ctx.children`.
- `examples/webhook.bend` serves a validating, a mutating and a
  conversion webhook. It denies ConfigMaps with a `forbidden` key, warns
  about a `deprecated` one, labels every ConfigMap with a JSON patch, and
  converts `spec.size` (v1) to `spec.replicas` (v2).
- `examples/sync.bend` is a two-cluster syncer (`X.Spec.watch_on`,
  `X.RAnnotated`, `X.Spec.watch_filter`).
- `examples/pool_bench.bend` measures pooled against fresh connections.
- `examples/smoke.bend` makes one-shot client calls.
- **JS lane:** controllers also run with `bend file.bend`, no native build.
  TLS there goes through `node:tls` in a worker thread, with the same
  verification. Native binaries are the production target.

## Verified on a live cluster

All of this ran against k0s v1.36 (arm64), both from a laptop and
in-cluster; `tests/e2e.sh` also passes on kind (Kubernetes v1.35):

- **Auth and config:**
  - TLS with client certificates, service-account tokens, and an exec
    plugin with `env`;
  - YAML kubeconfigs read natively, a merged `KUBECONFIG` list, and
    relative certificate paths resolved, all without kubectl;
  - an unknown CA and a hostname mismatch rejected;
  - the API server reached through an authenticated CONNECT proxy.
- **Watching:**
  - paginated lists, and watch streams that resume after the server's
    timeout;
  - a 12-second API outage: backoff, then a resume from the last version
    with no lost event.
- **Connections:** keep-alive pooling, including the retry of a stale
  connection.
- **Controllers:**
  - mirror recreation, updates and garbage collection;
  - Lease handover on SIGTERM in about 30ms, and takeover when the leader
    pod is deleted;
  - probes and metrics on standby and leader replicas;
  - the finalizer lifecycle with Events;
  - the typed Website operator, both from a laptop and in-cluster, and on
    the JS lane;
  - two controllers sharing one watch;
  - the 20,018-object sync in 2.6s;
  - a Secret change reconciling the bundles that reference it, read from
    the cache;
  - the Website operator settling after Ready: no reconciles from its own
    status writes over 20s, and a spec change reconciling again;
  - SIGTERM waiting for a running reconcile, then exiting 0, with and
    without leader election (the Lease is released after the drain);
  - the rate limit: 13 requests at 4 qps with a burst of 2 took 2.77s;
  - two replicas: one leader, the standby waiting, and SIGTERM handing
    the Lease to the standby within seconds (also in `tests/e2e.sh`);
  - a leader frozen (SIGSTOP) past its renew deadline while its Website
    changed: on resume it exits without writing, and the Deployment keeps
    its old replica count;
  - a one-hour soak on kind of `examples/bundle.bend`:
    - 200 bundles under continuous churn (Secret changes, bundles deleted
      and recreated, outputs deleted): 51,045 operations;
    - 62,933 reconciles with zero errors, and every bundle correct at the
      end;
    - memory flat at about 31–36 MB after warm-up;
    - a clean drain on SIGTERM.

## Scope

- **Memory.** Bend strings are lists of characters, so a cached object
  takes many times its JSON size: a 0.6 KB ConfigMap takes about 10 KB.
  That came to 204 MB RSS for 20,000 of them. Size memory limits by the
  objects a controller caches, and narrow its watches with namespaces
  (`C.InNs`) and label selectors (`X.Spec.label`, `X.Spec.watches_where`).
- **Relist peak.** A relist builds the new cache beside the old one and
  swaps it in whole, so for a moment the process holds about twice the
  cache.
- **Writes need a namespace.** A write goes to the namespace its `C.Api`
  names. Build `C.Api{res, C.InNs{ns}}` from the object, because an
  `AllNs` api has no namespace in its path.
- **Finalizer RBAC.** Finalizers are written with JSON patches, so a
  controller using them needs `patch` on its primary.
- **Relations scan.** `RRef` and `RAll` look through the primary's cache
  for each related event, and `X.Ctx.children` looks through a related
  cache. That is linear in the cache's size, which is fine for thousands of
  objects.

- **Webhook TLS.** The webhook server presents a certificate but asks for
  none, and speaks HTTP/1.1 only, as the API server does to webhooks. Prefer
  CRD schemas, CEL rules (`x-kubernetes-validations`) and
  `ValidatingAdmissionPolicy` where they suffice; they need no server.
- **Mappers.** One mapper serves all of a process's `RMap` watches (`n`
  and `X.Ctx.idx` tell them apart), because a Bend callback is fixed at
  compile time and can't be stored in a spec.
- **Resync.** There is no periodic resync of every object. A reconcile asks
  for its next look with `Requeue{ms}`.
- **One lease.** Watches can run on other clusters (`X.Spec.watch_on`),
  but leader election and `X.Ctx.cfg` use the controllers' own config.
- **Plain HTTP.** The client speaks only TLS to the API server; it isn't a
  general HTTP client for external systems.
- **Typed patches.** Generated encoders omit absent fields, so a merge
  patch can't clear one; send `null` by hand when a field must go.

These are choices, matching kube-rs's defaults:

- **HTTP/1.1.** It uses HTTP/1.1 with pooling, which is kube-rs's default
  transport. HTTP/2 is not implemented.
- **No discovery.** There is no discovery API: resources are named in
  code or generated from schemas.

Boundaries:

- **TLS and signals: the trust boundary.** Cryptography is delegated to
  OpenSSL, as kube-rs delegates it to rustls or OpenSSL and client-go to
  Go's `crypto/tls`. Writing it in Bend would not make it safer: crypto
  must run in constant time, which Bend's evaluator cannot promise.
  Signals need `sigaction`, which only C can call. What stays foreign is
  kept small:
  - `src/effs/tls.c` promises: `Tls.dial` connects (IPv4 or IPv6) within
    its deadline for each address it tries, after resolving the name (DNS
    resolution itself is the system's and is not bounded by that deadline;
    an in-cluster config dials an IP); `Tls.secure` handshakes with TLS 1.2 or later and
    succeeds only if the server's chain verifies against the given roots
    (or the system's) and its certificate names the host (or IP); `Tls.send`
    and `Tls.recv` move bytes, an empty read being the end; a failed
    `Tls.secure` closes the connection. It decides nothing else: proxies
    and every HTTP decision are proven Bend.
  - `src/effs/sys.c` promises: `Sys.wall` is the system's wall clock, and
    `Sys.signal` answers once SIGTERM or SIGINT arrives.
  - `src/effs/tls.js` keeps the same promises on the JS lane, with
    `node:tls`.
  - `tests/tls.sh` holds them to it on both lanes, with the native build
    under UndefinedBehaviorSanitizer (and AddressSanitizer on Linux):
    - a verified server, and client certificates;
    - an unknown CA, a wrong name, an expired certificate, TLS 1.1, and a
      missing or bad client certificate, all refused;
    - servers that hang up, answer in plain HTTP, never answer, or send a
      truncated or oversized record;
    - every proxy path: tunnel, 407, 502, bypasses, bad schemes, early
      bytes, and a proxy that is down or hangs up.
- **YAML subset.** The YAML reader covers block and flow collections,
  block scalars (`|`, `>`, with chomping), anchors, aliases, merge keys
  (`<<`), tags (`!!str`; others ignored) and multi-document streams
  (`Yaml.parse_all`). Plain scalars resolve by YAML 1.2's core schema:
  null, booleans, and numbers (`-5`, `0.5`, `1e3`, written as JSON writes
  them; `0x1F` and `.inf` stay strings). It doesn't support complex keys
  (`? `) or anchors on inline `- key:` maps.
- **Fuel.** Long-running loops count down a nested fuel of 2^64 steps, so
  they terminate by structure. At a million steps a second that is longer
  than any process lives. A loop that ran out would exit the process
  rather than sit idle.
