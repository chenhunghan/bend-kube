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

It is published on BendHub, so a controller imports it by name and
version; `bend` fetches and caches the package (in `~/.bend/lib`) on first
use, checking every file against its hash:

<!-- x-release-please-start-version -->
```python
import Base
import bend-kube@0.1.0.0/src/json.bend as J
import bend-kube@0.1.0.0/src/core.bend as C
import bend-kube@0.1.0.0/src/config.bend as K
import bend-kube@0.1.0.0/src/queue.bend as Q
import bend-kube@0.1.0.0/src/kube.bend as Kb

def reconcile(o: J.Json, cfg: K.Config) -> IO(Q.Action):
  # make the world match o, idempotently; then say when to look again
  IO.pure(Q.Action, Q.Requeue{300000})

def main() -> IO(Unit):
  Kb.Kube.run(~reconcile, C.Api{C.Res.config_maps(), C.InNs{"default"}}, Nil{},
    Kb.Opts.with_leader(Kb.Opts.default(), "default", "my-controller", "replica-a"))
```
<!-- x-release-please-end -->

The hub wants four-number versions: release `vX.Y.Z` is
`bend-kube@X.Y.Z.0`. Inside this repo, the examples import `../src/`.

## Layout

| bend-kube | kube-rs / client-go counterpart | pure? |
|---|---|---|
| `src/json.bend` | serde_json (arbitrary precision) | yes |
| `src/yaml.bend` | serde_yaml (the block YAML kubeconfigs use) | yes |
| `src/typed.bend` + `tools/gen.py` | k8s-openapi and kube-derive: typed records from OpenAPI or CRD schemas | yes |
| `src/utf8.bend`, `src/base64.bend`, `src/time.bend` | std / chrono | yes |
| `src/http.bend` | hyper's HTTP/1.1 codec | yes |
| `src/core.bend` | kube-core: `ApiResource`, `Request`, params, `WatchEvent`, `Status`, `ObjectRef` | yes |
| `src/config.bend` | kube-client `Config`, kubeconfig, in-cluster | yes |
| `src/watcher.bend` | kube-runtime `watcher`, client-go `Reflector` | yes |
| `src/store.bend` | kube-runtime `reflector::Store` | yes |
| `src/queue.bend` | client-go `workqueue`, kube-runtime `scheduler` | yes |
| `src/lease.bend` | client-go `leaderelection.tryAcquireOrRenew` | yes |
| `src/finalizer.bend` | kube-runtime `finalizer` (decisions) | yes |
| `src/proxy.bend` | Go's `ProxyFromEnvironment` and the CONNECT exchange | yes |
| `src/net.bend` + `src/effs/tls.c` | rustls / crypto/tls (OpenSSL via `dlopen`) | effect |
| `src/sys.bend` + `src/effs/sys.c` | wall clock, SIGTERM | effect |
| `src/client.bend` | kube-client `Client`, `Api<K>` verbs | IO |
| `src/runtime.bend` | kube-runtime `Controller` | IO |
| `src/leader.bend` | client-go `leaderelection.RunOrDie` | IO |
| `src/helpers.bend` | kube-runtime `finalizer()`, client-go `EventRecorder` | IO |
| `src/serve.bend` | controller-runtime `/healthz` `/readyz` `/metrics` | IO |
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
  50% jitter); success resets it.
- `resourceVersion` is opaque: it is copied and never compared.

**Caching:** a relist builds a fresh buffer between Init and InitDone and
swaps it in whole, so objects deleted while the watch was down disappear.

**Queueing** (client-go's workqueue):

- A key waits in the queue at most once.
- A key never runs on two workers at once. If it is added while it runs, it
  runs again when the current run ends.
- At most `Opts.max` reconciles run concurrently.
- Errors back off per key, from 5ms doubling to at most 1000s.
- A delayed requeue is staled by any newer add.
- Deleted keys are forgotten.
- Nothing is reconciled until the first list completes.

**Many controllers, shared watches** (controller-runtime's Manager,
kube-runtime's shared reflectors): `Kube.run_all(~rec, [Ctrl{..}, ..], opts)`
runs several controllers in one process. Each has its own loop, store and
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
- Lease writes go through `resourceVersion`, so of two contenders only one
  write lands.
- A leader that cannot renew within the deadline exits with status 1, so
  two leaders never act at once.
- SIGTERM releases the Lease and exits with status 0, so failover takes
  milliseconds.

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
  response byte came and the method is idempotent. A law states this
  rule.
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
  as the minimum.
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
  `Tls.secure`, `Tls.send`, `Tls.recv`, `Tls.close`); see the trust
  boundary under Scope.
- Names resolve through DNS, and IPv6 is supported.
- SIGPIPE is ignored, so a dead peer shows up as an error instead of
  killing the process.

**Operations:**

- Logs are one JSON object per line on stderr.
- `/healthz`, `/readyz` (503 until the store is synced; `standby` on a
  replica that isn't the leader) and `/metrics` are served on `:8080`.
- Metrics: `bendkube_reconcile_total`, `bendkube_reconcile_errors_total`,
  `bendkube_watch_events_total`, `bendkube_reconcile_running`,
  `bendkube_store_objects`, `bendkube_store_ready` and `bendkube_leader`.
- Events go to `events.k8s.io/v1` (`Event.publish`).

**Parallelism:** the watch lines that arrive in one read are separate JSON
documents. They are decoded and parsed as balanced Bend parallel calls
(`Drv.inputs.par`), and `tests/par_test.bend` checks that the result is the
same as the sequential one. Reconciles run concurrently on Bend's event
loop.

## Laws

`LAWS.bend` holds 33 laws, proven in `PROOF.bend` and accepted by both
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
KUBECONFIG=test.yaml tests/e2e.sh   # proxy tunnel, typed operator, finalizer, shared watches, on a disposable cluster
./y2j crd.yaml > crd.json && tools/gen.py crd crd.json -o gen/my.bend   # typed CRD views
cd examples && bend mirror.bend -o mirror && KUBECONFIG=~/.kube/config ./mirror
docker build --build-arg EXAMPLE=mirror -t bend-kube-mirror .   # proof-gated image
kubectl apply -f deploy/mirror.yaml
```

- **Bend version:** bend-kube needs Bend **2.0.39**. Bend's C effect interface
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
`tools/ci.sh` on every pull request and push. On each push to `master`,
`.github/workflows/release.yml` runs
[release-please](https://github.com/googleapis/release-please), which keeps
a release pull request up to date (version, `CHANGELOG.md`, the imports
above). Merging that pull request:

1. tags `vX.Y.Z` and makes a GitHub release;
2. reruns every gate on the tag;
3. publishes `package.bend` and everything it imports to BendHub as
   `bend-kube@X.Y.Z.0`. A publish is public and permanent.

Publishing needs the `BENDAI_KEY` repository secret: the `key` field of
`~/.bend/bendai.json` after `bend login`.

## Examples

- `examples/mirror.bend` keeps a `<name>-mirror` copy of every ConfigMap,
  owned by the original. It uses server-side apply, `owns`, leader election
  and requeues. `deploy/mirror.yaml` deploys two replicas with least-privilege
  RBAC, probes and a restricted security context.
- `examples/guard.bend` runs a finalizer and records Events on ConfigMaps
  selected by a label.
- `examples/noop.bend` is a scale baseline: 2,029 ConfigMaps listed, cached
  and reconciled in about 1s, at 37 MB RSS.
- `examples/website.bend` is a typed operator: a generated `Website` CRD
  type, an owned Deployment, the status subresource, Warning events for
  invalid specs, and leader election. `deploy/website.yaml` runs it with
  cluster-scoped least-privilege RBAC.
- `examples/pool_bench.bend` measures pooled against fresh connections.
- `examples/smoke.bend` makes one-shot client calls.
- **JS lane:** controllers also run with `bend file.bend`, no native build.
  TLS there goes through `node:tls` in a worker thread, with the same
  verification. Native binaries are the production target.

## Verified on a live cluster

All of this ran against k0s v1.36 (arm64), both from a laptop and
in-cluster:

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
  - the 2,029-object sync.

## Scope

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
  - `src/effs/tls.c` promises: `Tls.dial` connects (DNS, IPv4 or IPv6)
    within its deadline; `Tls.secure` handshakes with TLS 1.2 or later and
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
  (`Yaml.parse_all`). It doesn't support complex keys (`? `) or anchors
  on inline `- key:` maps.
- **Fuel.** Loops count down fuel of 4,294,967,295 steps so they terminate
  by structure; at a few steps a second that is years.
