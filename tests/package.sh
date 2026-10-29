#!/bin/bash
# Tests the package as BendHub would ship it: package.bend must import
# every module; publishing it to a local stand-in hub (fixtures/fakehub.py)
# must ship only files inside this repo; and a controller importing
# bend-kube@<version>/src/... from that hub must build natively.
set -euo pipefail
cd "$(dirname "$0")/.."
PORT=${PORT:-24499}
work=$(mktemp -d)
trap 'exec 2>/dev/null; kill $(jobs -p) || true; wait || true; rm -rf "$work"' EXIT

missing=$(for f in src/*.bend; do grep -q "^import ./$f as " package.bend || echo "$f"; done)
[ -z "$missing" ] || { echo "FAIL package.bend does not import: $missing"; exit 1; }
echo "ok   package.bend imports every module"

ver="$(cat version.txt).0"
mkdir -p "$work/home/.bend"
echo '{"key":"test","login":"test"}' > "$work/home/.bend/bendai.json"
python3 tests/fixtures/fakehub.py "$PORT" 2>/dev/null &
for _ in $(seq 50); do curl -fs "http://127.0.0.1:$PORT/pow.json" >/dev/null && break; sleep 0.1; done
hub() { HOME="$work/home" BEND_HUB="http://127.0.0.1:$PORT" BEND_NO_TELEMETRY=1 "$@"; }

hub bend package.bend --publish "bend-kube@$ver" > "$work/publish.out" 2>&1 \
  || { cat "$work/publish.out"; echo "FAIL publish"; exit 1; }
hash=$(curl -fs "http://127.0.0.1:$PORT/name/bend-kube@$ver")
curl -fs "http://127.0.0.1:$PORT/$hash/manifest" | awk '{print $2}' > "$work/files"
bad=$(grep -v -E '^(LICENSE|LAWS\.bend|PROOF\.bend|package\.bend|src/[a-z0-9_]+\.bend|src/effs/[a-z]+\.(c|js))$' "$work/files" || true)
[ -z "$bad" ] || { echo "FAIL unexpected files in the package: $bad"; exit 1; }
echo "ok   published bend-kube@$ver: $(wc -l < "$work/files" | tr -d ' ') files"

mkdir "$work/consumer"
sed "s|^import \.\./src/|import bend-kube@$ver/src/|" examples/mirror.bend > "$work/consumer/main.bend"
(cd "$work/consumer" && hub bend main.bend -o op) > "$work/build.out" 2>&1 && [ -x "$work/consumer/op" ] \
  || { cat "$work/build.out"; echo "FAIL a controller importing bend-kube@$ver does not build"; exit 1; }
echo "ok   a controller importing bend-kube@$ver builds"
echo; echo "package tests pass"
