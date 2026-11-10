#!/bin/bash
# End-to-end tests against a real cluster. Usage:
#   KUBECONFIG=/path/to/test-cluster.yaml tests/e2e.sh
# Needs a disposable cluster (it creates the namespace bend-e2e and the
# websites.bend-kube.dev CRD, and deletes both at the end), kubectl, and
# openssl. Builds the examples natively (set SDKROOT on macOS if needed).
set -euo pipefail
cd "$(dirname "$0")/.."
: "${KUBECONFIG:?point KUBECONFIG at a disposable test cluster}"
ctx=$(kubectl config current-context)
case "$ctx" in *prod*) echo "refusing to run against context $ctx"; exit 1;; esac
work=$(mktemp -d)
trap 'kill $(jobs -p) 2>/dev/null || true; kubectl delete ns bend-e2e bend-e2e-host --wait=false >/dev/null 2>&1 || true; kubectl delete crd websites.bend-kube.dev --wait=false >/dev/null 2>&1 || true; rm -rf "$work"' EXIT
pass() { echo "ok   $*"; }
fail() { echo "FAIL $*"; exit 1; }
k() { kubectl -n bend-e2e "$@"; }

echo "== build"
for e in smoke website guard bundle; do (cd examples && bend $e.bend -o "$work/$e") >/dev/null 2>&1 || fail "build $e"; done
kubectl config view --raw --minify -o json > "$work/kc.json"; chmod 600 "$work/kc.json"
pass build

echo "== client and TLS"
KUBECONFIG="$work/kc.json" "$work/smoke" | grep "^ok " >/dev/null && pass "list namespaces" || fail "list namespaces"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$work/o.key" -out "$work/o.crt" -subj /CN=other -days 1 2>/dev/null
python3 -I - "$work" <<'PY'
import base64, json, sys
w = sys.argv[1]; c = json.load(open(w + "/kc.json"))
c["clusters"][0]["cluster"]["certificate-authority-data"] = base64.b64encode(open(w + "/o.crt", "rb").read()).decode()
json.dump(c, open(w + "/wrong-ca.json", "w"))
PY
KUBECONFIG="$work/wrong-ca.json" "$work/smoke" | grep "server certificate rejected" >/dev/null \
  && pass "an unknown CA is rejected" || fail "an unknown CA was accepted"
python3 -I - "$work" <<'PY'
import json, sys
w = sys.argv[1]
for name, out in (("kubernetes.default.svc", "sni-ok"), ("wrong.example", "sni-bad")):
    c = json.load(open(w + "/kc.json"))
    c["clusters"][0]["cluster"]["tls-server-name"] = name
    json.dump(c, open(w + "/" + out + ".json", "w"))
PY
KUBECONFIG="$work/sni-ok.json" "$work/smoke" | grep "^ok " >/dev/null \
  && KUBECONFIG="$work/sni-bad.json" "$work/smoke" | grep "server certificate rejected" >/dev/null \
  && pass "tls-server-name verifies the server as that name" || fail "tls-server-name"

echo "== proxy"
# Loopback hosts never use a proxy (as in Go), so the tunnel reaches the API
# server by a name in its certificate that the test proxy resolves; the
# proxy's other cases run locally in tests/tls.sh.
python3 -I - "$work" <<'PY'
import json, sys, urllib.parse
w = sys.argv[1]; c = json.load(open(w + "/kc.json"))
u = urllib.parse.urlsplit(c["clusters"][0]["cluster"]["server"])
c["clusters"][0]["cluster"]["server"] = "https://kubernetes.default.svc:%d" % (u.port or 443)
json.dump(c, open(w + "/via-proxy.json", "w")); open(w + "/api-host", "w").write(u.hostname)
PY
python3 -I tests/fixtures/connect_proxy.py 23129 "kubernetes.default.svc=$(cat "$work/api-host")" > "$work/proxy.log" 2>&1 &
sleep 1
HTTPS_PROXY=http://user:s3cret@127.0.0.1:23129 KUBECONFIG="$work/via-proxy.json" "$work/smoke" | grep "^ok " >/dev/null \
  && grep "CONNECT kubernetes.default.svc:.* auth-ok" "$work/proxy.log" >/dev/null \
  && pass "API server through a CONNECT tunnel" || fail "proxy tunnel"

echo "== typed operator"
kubectl create ns bend-e2e >/dev/null
kubectl apply -f deploy/website-crd.yaml >/dev/null
kubectl wait --for condition=established crd/websites.bend-kube.dev --timeout=60s >/dev/null
KUBECONFIG="$work/kc.json" "$work/website" > "$work/website.log" 2>&1 &
cat <<'EOF' | k apply -f - >/dev/null
apiVersion: bend-kube.dev/v1alpha1
kind: Website
metadata: {name: hello}
spec: {image: "registry.k8s.io/pause:3.10", replicas: 1}
EOF
for _ in $(seq 1 60); do [ "$(k get website hello -o jsonpath='{.status.phase}' 2>/dev/null)" = Ready ] && break; sleep 2; done
[ "$(k get website hello -o jsonpath='{.status.phase}')" = Ready ] && pass "website becomes Ready" || fail "website not Ready"
[ "$(k get deploy hello -o jsonpath='{.metadata.ownerReferences[0].kind}')" = Website ] && pass "deployment owned" || fail "deployment not owned"
[ "$(k get website hello -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')" = True ] \
  && pass "Ready condition set" || fail "Ready condition"
k patch website hello --type merge -p '{"spec":{"replicas":2}}' >/dev/null
for _ in $(seq 1 60); do [ "$(k get website hello -o jsonpath='{.status.readyReplicas}')" = 2 ] && break; sleep 2; done
[ "$(k get website hello -o jsonpath='{.status.readyReplicas}')" = 2 ] && pass "scale follows spec" || fail "scale"
cat <<'EOF' | k apply -f - >/dev/null
apiVersion: bend-kube.dev/v1alpha1
kind: Website
metadata: {name: huge}
spec: {image: x, replicas: 5000000000}
EOF
sleep 4
k get events.events.k8s.io --field-selector regarding.name=huge -o jsonpath='{.items[*].reason}' | grep InvalidSpec >/dev/null \
  && pass "invalid spec reported" || fail "invalid spec not reported"
k delete website hello --wait=true --timeout=60s >/dev/null
for _ in $(seq 1 30); do k get deploy hello >/dev/null 2>&1 || break; sleep 2; done
k get deploy hello >/dev/null 2>&1 && fail "deployment not collected" || pass "deployment collected with its website"

echo "== finalizer"
pkill -f "$work/website" || true
sed 's/"bend-demo"/"bend-e2e"/' examples/guard.bend > examples/.guard-e2e.bend
(cd examples && bend .guard-e2e.bend -o "$work/guard") >/dev/null 2>&1; rm -f examples/.guard-e2e.bend
KUBECONFIG="$work/kc.json" "$work/guard" > "$work/guard.log" 2>&1 &
k create configmap g --from-literal=a=b >/dev/null; k label configmap g bend-kube/guard=true >/dev/null
for _ in $(seq 1 30); do k get cm g -o jsonpath='{.metadata.finalizers}' | grep guard >/dev/null && break; sleep 1; done
k get cm g -o jsonpath='{.metadata.finalizers}' | grep guard >/dev/null && pass "finalizer added" || fail "finalizer"
k delete cm g --wait=true --timeout=30s >/dev/null && pass "finalizer released on delete" || fail "delete blocked"

echo "== shared watches"
pkill -f "$work/guard" || true
sed 's/"bend-demo"/"bend-e2e"/' examples/multi.bend > examples/.multi-e2e.bend
(cd examples && bend .multi-e2e.bend -o "$work/multi") >/dev/null 2>&1; rm -f examples/.multi-e2e.bend
k create configmap shared --from-literal=a=b >/dev/null
KUBECONFIG="$work/kc.json" "$work/multi" > "$work/multi.log" 2>&1 &
for _ in $(seq 1 30); do k get cm shared-mirror >/dev/null 2>&1 && break; sleep 1; done
k get cm shared-mirror >/dev/null 2>&1 && pass "first controller reconciles" || fail "mirror"
grep '"audit"' "$work/multi.log" | grep "bend-e2e/shared" >/dev/null && pass "second controller reconciles" || fail "audit"
[ "$(grep -c '"listing"' "$work/multi.log")" = 1 ] && pass "three subscriptions, one list and watch" || fail "watch not shared"

echo "== cached reads and references"
pkill -f "$work/multi" || true
sed 's/"bend-demo"/"bend-e2e"/' examples/bundle.bend > examples/.bundle-e2e.bend
(cd examples && bend .bundle-e2e.bend -o "$work/bundle") >/dev/null 2>&1; rm -f examples/.bundle-e2e.bend
k create secret generic s1 --from-literal=user=a --from-literal=pass=b >/dev/null
k create configmap b1 --from-literal=secret=s1 >/dev/null; k label configmap b1 bend-kube/bundle=true >/dev/null
BEND_KUBE_PORT=18083 KUBECONFIG="$work/kc.json" "$work/bundle" > "$work/bundle.log" 2>&1 &
for _ in $(seq 1 30); do [ "$(k get cm b1-keys -o jsonpath='{.data.keys}' 2>/dev/null)" = '["pass","user"]' ] && break; sleep 1; done
[ "$(k get cm b1-keys -o jsonpath='{.data.keys}')" = '["pass","user"]' ] && pass "reconcile reads a referenced secret from the cache" || fail "bundle keys"
k patch secret s1 -p '{"stringData":{"token":"x"}}' >/dev/null
for _ in $(seq 1 30); do k get cm b1-keys -o jsonpath='{.data.keys}' | grep token >/dev/null && break; sleep 1; done
k get cm b1-keys -o jsonpath='{.data.keys}' | grep token >/dev/null && pass "a referenced secret's change reconciles its bundle" || fail "reference trigger"
grep '"owned":"1"' "$work/bundle.log" >/dev/null && pass "owned outputs read from the cache" || fail "children"
curl -s localhost:18083/metrics | grep '^bundle_syncs_total{bundle="b1"} ' >/dev/null \
  && curl -s localhost:18083/metrics | grep '^bundle_secret_keys{bundle="b1"} 3' >/dev/null \
  && pass "the controller's own metrics on /metrics" || fail "own metrics"
kill -TERM "$(pgrep -f "$work/bundle")"
for _ in $(seq 1 20); do pgrep -f "$work/bundle" >/dev/null || break; sleep 0.25; done
pgrep -f "$work/bundle" >/dev/null && fail "bundle did not exit on SIGTERM" || true
grep '"reconciles drained"' "$work/bundle.log" >/dev/null && pass "SIGTERM drains and exits" || fail "drain"

echo "== a watch on another cluster"
# The host cluster is the same API server under another identity (its
# tls-server-name), so the host watch runs through a config of its own.
sed 's/"bend-demo"/"bend-e2e"/; s/"bend-demo-host"/"bend-e2e-host"/' examples/sync.bend > examples/.sync-e2e.bend
(cd examples && bend .sync-e2e.bend -o "$work/sync") >/dev/null 2>&1; rm -f examples/.sync-e2e.bend
[ -x "$work/sync" ] || fail "build sync"
kubectl create ns bend-e2e-host >/dev/null
k create configmap src --from-literal=a=1 >/dev/null; k label configmap src bend-kube/sync=true >/dev/null
hk() { kubectl -n bend-e2e-host "$@"; }
HOST_KUBECONFIG="$work/sni-ok.json" KUBECONFIG="$work/kc.json" BEND_KUBE_PORT=0 "$work/sync" > "$work/sync.log" 2>&1 &
for _ in $(seq 1 30); do [ "$(hk get cm src-x-bend-e2e -o jsonpath='{.data.a}' 2>/dev/null)" = 1 ] && break; sleep 1; done
[ "$(hk get cm src-x-bend-e2e -o jsonpath='{.data.a}')" = 1 ] && pass "a source is copied to the host cluster" || fail "sync copy"
k patch configmap src -p '{"data":{"a":"2"}}' >/dev/null
for _ in $(seq 1 30); do [ "$(hk get cm src-x-bend-e2e -o jsonpath='{.data.a}')" = 2 ] && break; sleep 1; done
[ "$(hk get cm src-x-bend-e2e -o jsonpath='{.data.a}')" = 2 ] && pass "a source's change reaches its copy" || fail "sync update"
n0=$(grep -c '"synced"' "$work/sync.log")
hk patch configmap src-x-bend-e2e -p '{"data":{"a":"drift"}}' >/dev/null
sleep 3
[ "$(grep -c '"synced"' "$work/sync.log")" = "$n0" ] && pass "the host watch's filter ignores a data edit" || fail "filter let a data edit through"
hk delete configmap src-x-bend-e2e >/dev/null
for _ in $(seq 1 30); do [ "$(hk get cm src-x-bend-e2e -o jsonpath='{.data.a}' 2>/dev/null)" = 2 ] && break; sleep 1; done
[ "$(hk get cm src-x-bend-e2e -o jsonpath='{.data.a}' 2>/dev/null)" = 2 ] && pass "a copy deleted on the host maps back to its source and returns" || fail "sync restore"
grep '"listing"' "$work/sync.log" | grep "bend-e2e-host" | grep -q '(kubernetes.default.svc)' \
  && pass "the host watch lists through its own config, and its log names that server" || fail "host watch"
pkill -f "$work/sync" || true

echo "== write conflicts"
(cd tests/fixtures && bend conflict.bend -o "$work/conflict") >/dev/null 2>&1 || fail "build conflict"
k create configmap conflict --from-literal=a=start >/dev/null
KUBECONFIG="$work/kc.json" "$work/conflict" > "$work/conflict.log" 2>&1
grep -q "^stale replace: fail 409" "$work/conflict.log" && pass "a stale PUT conflicts" || fail "no conflict: $(cat "$work/conflict.log")"
grep -q "^stale replace_retry, 0 tries: fail 409" "$work/conflict.log" && pass "replace_retry with no tries keeps the 409" || fail "replace_retry 0"
grep -q "^stale replace_retry, 3 tries: ok a=retried" "$work/conflict.log" && [ "$(k get cm conflict -o jsonpath='{.data.a}')" = retried ] \
  && pass "replace_retry re-reads after a 409 and lands" || fail "replace_retry: $(cat "$work/conflict.log")"
grep -q "^replace_retry of a missing object: fail 404" "$work/conflict.log" && pass "replace_retry of a missing object fails with 404" || fail "replace_retry 404"

echo "== reconcile timeout"
(cd tests/fixtures && bend hang.bend -o "$work/hang") >/dev/null 2>&1 || fail "build hang"
k create configmap quick --from-literal=ms=1000 >/dev/null; k label configmap quick bend-kube/hang=true >/dev/null
KUBECONFIG="$work/kc.json" "$work/hang" > "$work/hang.log" 2>&1 &
hang_pid=$!
for _ in $(seq 1 30); do grep '"slept"' "$work/hang.log" | grep -q bend-e2e/quick && break; sleep 1; done
sleep 3
kill -0 "$hang_pid" 2>/dev/null && grep '"slept"' "$work/hang.log" | grep -q bend-e2e/quick \
  && pass "a reconcile within its timeout finishes, and the process lives on" || fail "hang: quick: $(cat "$work/hang.log")"
k create configmap stuck --from-literal=ms=30000 >/dev/null; k label configmap stuck bend-kube/hang=true >/dev/null
code=0; for _ in $(seq 1 15); do kill -0 "$hang_pid" 2>/dev/null || break; sleep 1; done
if kill -0 "$hang_pid" 2>/dev/null; then kill "$hang_pid"; fail "a hung reconcile did not exit the process"; fi
wait "$hang_pid" || code=$?
[ "$code" = 1 ] && grep '"reconcile hung past its timeout' "$work/hang.log" | grep -q bend-e2e/stuck \
  && pass "a reconcile past its timeout exits the process with status 1" || fail "hang: exit $code: $(cat "$work/hang.log")"

echo "== a relation mapped by code"
(cd tests/fixtures && bend mapped.bend -o "$work/mapped") >/dev/null 2>&1 || fail "build mapped"
for n in m1 m2 m3; do k create configmap $n --from-literal=a=b >/dev/null; k label configmap $n bend-kube/mapped=true >/dev/null; done
KUBECONFIG="$work/kc.json" "$work/mapped" > "$work/mapped.log" 2>&1 &
for _ in $(seq 1 30); do [ "$(grep -c '"reconciled"' "$work/mapped.log")" -ge 3 ] && break; sleep 1; done
since() { tail -n +"$(( $1 + 1 ))" "$work/mapped.log" | grep '"reconciled"' | grep -o 'bend-e2e/m[0-9]' | sort -u | tr '\n' ' '; }
n0=$(wc -l < "$work/mapped.log")
k create secret generic s --from-literal=x=1 >/dev/null; k annotate secret s bend-kube/for=m1,m3 >/dev/null
for _ in $(seq 1 20); do [ "$(since "$n0")" = "bend-e2e/m1 bend-e2e/m3 " ] && break; sleep 1; done
[ "$(since "$n0")" = "bend-e2e/m1 bend-e2e/m3 " ] && pass "the mapper names the primaries a related object triggers" || fail "mapped: $(since "$n0")"
n1=$(wc -l < "$work/mapped.log")
k annotate --overwrite secret s bend-kube/for=m2 >/dev/null
for _ in $(seq 1 20); do [ "$(since "$n1")" = "bend-e2e/m1 bend-e2e/m2 bend-e2e/m3 " ] && break; sleep 1; done
[ "$(since "$n1")" = "bend-e2e/m1 bend-e2e/m2 bend-e2e/m3 " ] && pass "a mapped object that moves wakes its old and new primaries" || fail "mapped move: $(since "$n1")"
pkill -f "$work/mapped" || true

echo "== rate limit and drain"
(cd tests/fixtures && bend slow.bend -o "$work/slow") >/dev/null 2>&1 || fail "build slow"
k create configmap slow --from-literal=a=b >/dev/null; k label configmap slow bend-kube/slow=true >/dev/null
KUBECONFIG="$work/kc.json" "$work/slow" > "$work/slow.log" 2>&1 &
for _ in $(seq 1 60); do grep '"gets done"' "$work/slow.log" >/dev/null && break; sleep 0.25; done
kill -TERM "$(pgrep -f "$work/slow")"
python3 -I - "$work/slow.log" <<'PY' && pass "13 requests at 4 qps, burst 2, take about 2.75s" || fail "rate limit"
import datetime, json, sys
ev = {j["msg"]: j["ts"] for j in map(json.loads, open(sys.argv[1]))}
t = lambda m: datetime.datetime.fromisoformat(ev[m].replace("Z", "+00:00"))
d = (t("gets done") - t("starting controllers")).total_seconds()
sys.exit(0 if 2.4 <= d <= 4.5 else 1)
PY
for _ in $(seq 1 40); do pgrep -f "$work/slow" >/dev/null || break; sleep 0.25; done
grep -A2 '"draining reconciles"' "$work/slow.log" | grep '"end"' >/dev/null \
  && grep '"reconciles drained"' "$work/slow.log" >/dev/null && pass "SIGTERM waits for a running reconcile" || fail "drain mid-reconcile"

echo "== leader election"
kubectl create ns bend-kube-system >/dev/null 2>&1 || true
holder() { kubectl -n bend-kube-system get lease bend-kube-website -o jsonpath='{.spec.holderIdentity}' 2>/dev/null; }
HOSTNAME=replica-a BEND_KUBE_PORT=18081 KUBECONFIG="$work/kc.json" "$work/website" > "$work/lead-a.log" 2>&1 &
pid_a=$!
for _ in $(seq 1 30); do holder | grep '^replica-a_' >/dev/null && break; sleep 1; done
HOSTNAME=replica-b BEND_KUBE_PORT=18082 KUBECONFIG="$work/kc.json" "$work/website" > "$work/lead-b.log" 2>&1 &
pid_b=$!
sleep 6
holder | grep '^replica-a_' >/dev/null && ! grep '"became leader"' "$work/lead-b.log" >/dev/null \
  && pass "one leader; the standby waits" || fail "two leaders"
kill -TERM "$pid_a"
for _ in $(seq 1 20); do holder | grep '^replica-b_' >/dev/null && break; sleep 0.5; done
holder | grep '^replica-b_' >/dev/null && grep '"released leader lease"' "$work/lead-a.log" >/dev/null \
  && pass "SIGTERM hands the lease over within seconds" || fail "handover"
kill -TERM "$pid_b"; wait "$pid_b" 2>/dev/null || true
kubectl -n bend-kube-system delete lease bend-kube-website >/dev/null 2>&1 || true

echo; echo "all e2e tests pass"
