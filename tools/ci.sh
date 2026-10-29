#!/bin/bash
# The gates a change must pass, in order (AGENTS.md: run PROOF.bend before
# committing):
#   1. the laws hold (bend PROOF.bend, then --verdict on the Lean kernel);
#   2. every pure module proves clean: no foreign effect may leak into it;
#   3. every IO module type-checks, its only "failure" being its effects;
#   4. the unit and scenario tests match their expected output;
#   5. every example builds to a native binary;
#   6. the package publishes to a stand-in hub and a controller builds
#      from it (tests/package.sh);
#   7. TLS and proxies behave against local servers on both lanes, the
#      native one under sanitizers (tests/tls.sh; SKIP_TLS=1 skips it).
# On macOS with a newer SDK than clang's linker knows, set SDKROOT to an
# older SDK (for example .../MacOSX26.5.sdk).
set -eu
cd "$(dirname "$0")/.."
need_bend=2.0.39
have=$(bend version 2>&1 | tr -d '\n')
case "$have" in *"$need_bend"*) ;; *) echo "bend $need_bend required (have: $have)"; exit 1;; esac

step() { printf '\n== %s\n' "$*"; }

step "laws"
out=$(bend PROOF.bend 2>&1); echo "$out" | tail -2
echo "$out" | grep -q "ALL PROOFS CHECK"
out=$(bend PROOF.bend --verdict 2>&1); echo "$out" | tail -1
echo "$out" | grep -q "ALL PROOFS CHECK"

step "pure modules"
for m in json utf8 base64 yaml http core config proxy watcher store queue lease time finalizer typed; do
  out=$(bend src/$m.bend --check-only 2>&1) || true
  if echo "$out" | grep -q "ALL PROOFS CHECK"; then echo "ok   $m"; else echo "FAIL $m"; echo "$out"; exit 1; fi
done

step "IO modules"
for m in net sys client log runtime leader serve helpers kube; do
  out=$(bend src/$m.bend --check-only 2>&1) || true
  # The only acceptable complaint is the foreign effects themselves.
  rest=$(echo "$out" | grep -v "SOME PROOFS FAIL\|rely on unsafe or foreign code\|defs that depend on foreign effects\|^Hint: no law" || true)
  if [ -z "$rest" ]; then echo "ok   $m"; else echo "FAIL $m"; echo "$out"; exit 1; fi
done

step "tests"
tests/run.sh

step "generated types"
# The checked-in generated code must be what the generator makes today.
y2j_dir=$(mktemp -d)
(cd tools && bend y2j.bend -o "$y2j_dir/y2j") >/dev/null 2>&1 || { echo "FAIL y2j build"; exit 1; }
"$y2j_dir/y2j" deploy/website-crd.yaml > "$y2j_dir/website-crd.json"
python3 tools/gen.py crd "$y2j_dir/website-crd.json" -o "$y2j_dir/website.bend" --lib ../../src >/dev/null
if diff -q <(sed 1,6d "$y2j_dir/website.bend") <(sed 1,6d examples/gen/website.bend) >/dev/null; then
  echo "ok   website types"
else
  echo "FAIL examples/gen/website.bend is stale: regenerate with tools/gen.py"; exit 1
fi
out=$(bend examples/gen/website.bend --check-only 2>&1) || true
echo "$out" | grep -q "ALL PROOFS CHECK" && echo "ok   website types prove" || { echo "$out"; exit 1; }
rm -rf "$y2j_dir"

step "examples"
out_dir=$(mktemp -d)
for e in examples/*.bend tools/y2j.bend; do
  name=$(basename "$e" .bend)
  dir=$(dirname "$e")
  (cd "$dir" && bend "$name.bend" -o "$out_dir/$name") >/dev/null 2>&1 \
    && echo "ok   $name" || { echo "FAIL $name"; (cd "$dir" && bend "$name.bend" -o "$out_dir/$name"); exit 1; }
done
rm -rf "$out_dir"

step "package"
tests/package.sh

if [ "${SKIP_TLS:-0}" != 1 ]; then
  step "TLS and proxies"
  tests/tls.sh
fi
printf '\nall gates pass\n'
