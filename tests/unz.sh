#!/bin/bash
# Tests unz.bend's gzip (zlib) and zstd (libzstd) decoders, and
# gzip.bend's pure one, on files the gzip and zstd tools make: a 2 MB
# stream decompressed 64 KiB at a time, concatenated members and frames,
# corrupt and cut-short input, and a bomb past the output limit. Native
# lane, built with sanitizers as tests/tls.sh builds them. zstd's checks
# are skipped when the zstd tool is not installed.
set -euo pipefail
cd "$(dirname "$0")/.."
case "$(uname)" in Darwin) SANITIZE=${SANITIZE:-undefined};; *) SANITIZE=${SANITIZE:-address,undefined};; esac
work=$(mktemp -d /tmp/bkunz.XXXXXX)
trap 'rm -rf "$work"' EXIT
fails=0
pass() { echo "ok   $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }

echo "== build"
bend tests/fixtures/unz_cat.bend -o "$work/cat.c" > "$work/build.log" 2>&1 || { cat "$work/build.log"; exit 1; }
clang -std=c11 -O0 -g -fno-omit-frame-pointer -fsanitize="$SANITIZE" -fno-sanitize-recover=all \
  "$work/cat.c" -lpthread -lm -ldl -o "$work/cat" > "$work/build.log" 2>&1 \
  || { grep -v "warning\|note:\|^ " "$work/build.log" | tail -20; exit 1; }
pass "native decoder with -fsanitize=$SANITIZE"
C=$work/cat
# half text that compresses, half random bytes that do not
python3 -I -c 'import random, sys; r = random.Random(7); w = ["layer", "tar", "usr", "bin", "lib", "etc", "share"]
sys.stdout.write(" ".join(r.choice(w) for _ in range(180000)))' > "$work/data.bin"
head -c 1000000 /dev/urandom >> "$work/data.bin"
size=$(wc -c < "$work/data.bin" | tr -d ' ')

check() {  # check NAME KIND IN: decompresses IN with KIND and compares
  local got; got=$("$C" "$2" "$3" "$work/out" 2>&1 || true)
  if [ "$got" = "ok $size" ] && cmp -s "$work/data.bin" "$work/out"; then pass "$1"; else fail "$1: $got"; fi
}
refused() {  # refused NAME KIND IN [MAX]
  local got; got=$("$C" "$2" "$3" "$work/out" ${4:-} 2>&1 || true)
  case "$got" in "fail "*) pass "$1 ($got)";; *) fail "$1 was not refused: $got";; esac
}

echo "== gzip"
gzip -6 -c "$work/data.bin" > "$work/d.gz"
check "zlib, 64 KiB at a time" gzip "$work/d.gz"
check "pure Bend" pure "$work/d.gz"
head -c 600000 "$work/data.bin" | gzip -1 -c > "$work/two.gz"
tail -c +600001 "$work/data.bin" | gzip -9 -c >> "$work/two.gz"
check "zlib, two members" gzip "$work/two.gz"
check "pure Bend, two members" pure "$work/two.gz"
head -c 100000 "$work/d.gz" > "$work/cut.gz"
refused "zlib, cut short" gzip "$work/cut.gz"
refused "pure Bend, cut short" pure "$work/cut.gz"
python3 -I -c 'import sys; b = bytearray(open(sys.argv[1], "rb").read()); b[5000] ^= 0xff; open(sys.argv[2], "wb").write(b)' \
  "$work/d.gz" "$work/bad.gz"
refused "zlib, corrupt" gzip "$work/bad.gz"
refused "pure Bend, corrupt" pure "$work/bad.gz"
head -c 50000000 /dev/zero | gzip -1 -c > "$work/bomb.gz"
refused "zlib, a bomb past a 10 MB limit" gzip "$work/bomb.gz" 10000000

if command -v zstd > /dev/null; then
  echo "== zstd"
  zstd -q -3 -c "$work/data.bin" > "$work/d.zst"
  check "libzstd, 64 KiB at a time" zstd "$work/d.zst"
  head -c 600000 "$work/data.bin" | zstd -q -1 -c > "$work/two.zst"
  tail -c +600001 "$work/data.bin" | zstd -q -19 -c >> "$work/two.zst"
  check "libzstd, two frames" zstd "$work/two.zst"
  head -c 100000 "$work/d.zst" > "$work/cut.zst"
  refused "libzstd, cut short" zstd "$work/cut.zst"
  refused "libzstd, gzip data" zstd "$work/d.gz"
  head -c 50000000 /dev/zero | zstd -q -1 -c > "$work/bomb.zst"
  refused "libzstd, a bomb past a 10 MB limit" zstd "$work/bomb.zst" 10000000
else
  echo "SKIP zstd is not installed"
fi
[ $fails = 0 ] && echo "all decompression tests pass" || { echo "$fails failed"; exit 1; }
