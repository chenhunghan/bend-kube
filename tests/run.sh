#!/bin/sh
# Runs every tests/*_test.bend and compares its output with
# tests/expected/<name>.out. UPDATE=1 rewrites the expected files. A test
# whose first line is "# native" is compiled and run natively: the
# interpreter's stack is too small for its lists.
set -u
cd "$(dirname "$0")"
fail=0
diffs=$(mktemp)
for t in *_test.bend; do
  name=${t%_test.bend}
  if [ "$(head -1 "$t")" = "# native" ]; then
    bin=$(mktemp -d)/$name
    out=$(bend "$t" -o "$bin" > /dev/null 2>&1 && "$bin" 2>&1 || echo "build or run failed: $(bend "$t" -o "$bin" 2>&1 | tail -5)")
    rm -rf "$(dirname "$bin")"
  else
    out=$(bend "$t" 2>&1)
  fi
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
