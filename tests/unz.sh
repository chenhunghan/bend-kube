#!/bin/bash
# Tests unz.bend's gzip (zlib) and zstd (libzstd) decoders, and
# gzip.bend's pure one, on files the gzip and zstd tools make: a 2 MB
# stream decompressed 64 KiB at a time (into a list, or straight into a
# file), a file decompressed to a file, concatenated members and frames,
# corrupt and cut-short input, and a bomb past the output limit; and
# Unz.file_sha256's digest of what it wrote, against shasum. Native
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
bend tests/fixtures/unz_file.bend -o "$work/file.c" > "$work/build.log" 2>&1 || { cat "$work/build.log"; exit 1; }
clang -std=c11 -O0 -g -fno-omit-frame-pointer -fsanitize="$SANITIZE" -fno-sanitize-recover=all \
  "$work/file.c" -lpthread -lm -ldl -o "$work/file" > "$work/build.log" 2>&1 \
  || { grep -v "warning\|note:\|^ " "$work/build.log" | tail -20; exit 1; }
# where clang targets the ARMv8 SHA-2 instructions, a second build without
# them checks unz.c's portable SHA-256 too
if clang -dM -E - < /dev/null | grep -q __ARM_FEATURE_SHA2; then
  clang -std=c11 -O0 -g -fno-omit-frame-pointer -fsanitize="$SANITIZE" -fno-sanitize-recover=all -U__ARM_FEATURE_SHA2 \
    "$work/file.c" -lpthread -lm -ldl -o "$work/file-portable" > "$work/build.log" 2>&1 \
    || { grep -v "warning\|note:\|^ " "$work/build.log" | tail -20; exit 1; }
fi
pass "native decoders with -fsanitize=$SANITIZE"
C=$work/cat
F=$work/file
# half text that compresses, half random bytes that do not
python3 -I -c 'import random, sys; r = random.Random(7); w = ["layer", "tar", "usr", "bin", "lib", "etc", "share"]
sys.stdout.write(" ".join(r.choice(w) for _ in range(180000)))' > "$work/data.bin"
head -c 1000000 /dev/urandom >> "$work/data.bin"
size=$(wc -c < "$work/data.bin" | tr -d ' ')
digest=$(shasum -a 256 "$work/data.bin" | cut -d' ' -f1)

check() {  # check NAME KIND IN: decompresses IN with KIND and compares
  local got; got=$("$C" "$2" "$3" "$work/out" 2>&1 || true)
  if [ "$got" = "ok $size" ] && cmp -s "$work/data.bin" "$work/out"; then pass "$1"; else fail "$1: $got"; fi
}
# to-file: fcheck NAME sink|file KIND IN, and frefused NAME sink|file KIND IN [MAX],
# which also wants a failed Unz.file to leave no output behind
fcheck() {
  rm -f "$work/out"; local got; got=$("$F" "$2" "$3" "$4" "$work/out" 2>&1 || true)
  if [ "$got" = "ok $size" ] && cmp -s "$work/data.bin" "$work/out"; then pass "$1"; else fail "$1: $got"; fi
}
frefused() {
  rm -f "$work/out"; local got; got=$("$F" "$2" "$3" "$4" "$work/out" ${5:-} 2>&1 || true)
  case "$got" in "fail "*) ;; *) fail "$1 was not refused: $got"; return;; esac
  if [ "$2" != sink ] && [ -e "$work/out" ]; then fail "$1 left its output"; else pass "$1 ($got)"; fi
}
# Unz.file_sha256: scheck NAME KIND IN [WANT_SIZE WANT_HEX]: the size and
# digest it answers are data.bin's (or the ones given), and so is the file
scheck() {
  rm -f "$work/out"; local got; got=$("$F" sha "$2" "$3" "$work/out" 2>&1 || true)
  local want="ok ${4:-$size} ${5:-$digest}"
  if [ "$got" = "$want" ] && [ -f "$work/out" ] && [ "$(shasum -a 256 "$work/out" | cut -d' ' -f1)" = "${5:-$digest}" ]; then
    pass "$1"
  else
    fail "$1: wanted '$want', got '$got'"
  fi
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
fcheck "zlib into a file, 64 KiB at a time" sink gzip "$work/d.gz"
fcheck "zlib, file to file" file gzip "$work/two.gz"
frefused "zlib into a file, corrupt" sink gzip "$work/bad.gz"
frefused "zlib, file to file, cut short" file gzip "$work/cut.gz"
frefused "zlib into a file, a bomb past 10 MB a write" sink gzip "$work/bomb.gz" 10000000
frefused "zlib, file to file, a bomb past 10 MiB" file gzip "$work/bomb.gz" 10
frefused "zlib, file to file, no input" file gzip "$work/missing.gz"
scheck "zlib, file to file, hashed" gzip "$work/d.gz"
scheck "zlib, two members, hashed" gzip "$work/two.gz"
# known answers: "abc" (FIPS 180-4's example) and nothing at all
printf abc | gzip -c > "$work/abc.gz"
scheck "zlib, hashed, FIPS 180-4's abc" gzip "$work/abc.gz" 3 ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
printf '' | gzip -c > "$work/nothing.gz"
scheck "zlib, hashed, a member of no bytes" gzip "$work/nothing.gz" 0 e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
# 1 MB of "a" in 333-byte members: the hash crosses every block boundary
python3 -I -c 'import gzip, sys; d = b"a" * 1000000; sys.stdout.buffer.write(b"".join(gzip.compress(d[i:i + 333]) for i in range(0, len(d), 333)))' > "$work/many.gz"
scheck "zlib, hashed, 3004 members" gzip "$work/many.gz" 1000000 cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0
# past unz.c's 4 MiB write buffer, so the hash spans several writes
{ cat "$work/data.bin" "$work/data.bin" "$work/data.bin"; head -c 3000000 /dev/urandom; } > "$work/big.bin"
gzip -1 -c "$work/big.bin" > "$work/big.gz"
scheck "zlib, hashed, 9 MB in several writes" gzip "$work/big.gz" "$(wc -c < "$work/big.bin" | tr -d ' ')" \
  "$(shasum -a 256 "$work/big.bin" | cut -d' ' -f1)"
if [ -x "$work/file-portable" ]; then
  F=$work/file-portable
  scheck "portable SHA-256: zlib, hashed" gzip "$work/d.gz"
  scheck "portable SHA-256: abc" gzip "$work/abc.gz" 3 ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
  scheck "portable SHA-256: 3004 members" gzip "$work/many.gz" 1000000 cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0
  F=$work/file
fi
frefused "zlib, hashed, cut short" sha gzip "$work/cut.gz"
frefused "zlib, hashed, corrupt" sha gzip "$work/bad.gz"
frefused "zlib, hashed, a bomb past 10 MiB" sha gzip "$work/bomb.gz" 10
: > "$work/empty.gz"
frefused "zlib, hashed, an empty file" sha gzip "$work/empty.gz"
frefused "zlib, hashed, no input" sha gzip "$work/missing.gz"

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
fcheck "libzstd into a file, 64 KiB at a time" sink zstd "$work/two.zst"
fcheck "libzstd, file to file" file zstd "$work/d.zst"
frefused "libzstd, file to file, cut short" file zstd "$work/cut.zst"
frefused "libzstd, file to file, a bomb past 10 MiB" file zstd "$work/bomb.zst" 10
scheck "libzstd, two frames, hashed" zstd "$work/two.zst"
frefused "libzstd, hashed, cut short" sha zstd "$work/cut.zst"
else
  echo "SKIP zstd is not installed"
fi
[ $fails = 0 ] && echo "all decompression tests pass" || { echo "$fails failed"; exit 1; }
