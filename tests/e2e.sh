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
trap 'kill $(jobs -p) 2>/dev/null || true; kubectl delete ns bend-e2e --wait=false >/dev/null 2>&1 || true; kubectl delete crd websites.bend-kube.dev --wait=false >/dev/null 2>&1 || true; rm -rf "$work"' EXIT
pass() { echo "ok   $*"; }
fail() { echo "FAIL $*"; exit 1; }
k() { kubectl -n bend-e2e "$@"; }

echo "== build"
for e in smoke website guard; do (cd examples && bend $e.bend -o "$work/$e") >/dev/null 2>&1 || fail "build $e"; done
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

echo; echo "all e2e tests pass"
