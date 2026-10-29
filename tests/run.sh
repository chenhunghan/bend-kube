#!/bin/sh
# Runs every tests/*_test.bend and compares its output with
# tests/expected/<name>.out. UPDATE=1 rewrites the expected files.
set -u
cd "$(dirname "$0")"
fail=0
diffs=$(mktemp)
for t in *_test.bend; do
  name=${t%_test.bend}
  out=$(bend "$t" 2>&1)
  if [ "${UPDATE:-0}" = 1 ]; then
    printf '%s\n' "$out" > "expected/$name.out"
    echo "updated $name"
  elif printf '%s\n' "$out" | diff -u "expected/$name.out" - > "$diffs"; then
    echo "ok   $name"
  else
    echo "FAIL $name"; cat "$diffs"; fail=1
  fi
done
rm -f "$diffs"
exit $fail
