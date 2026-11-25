#!/bin/bash
# Tests zip.bend's LZ4 block compressor (src/effs/zip.c): what Zip.blocks
# and Zip.pack store is read back by a strict decoder of the block format
# and by liblz4's LZ4_decompress_safe where it is installed
# (tests/fixtures/zip_check.py): no bytes, a few bytes, bytes that do not
# compress (stored raw), a megabyte of zeros, blocks of every small size
# whose matches run to their ends, a block just under, at and over the
# block size, an offset at the format's 65535 limit and one past it,
# 64-bit offsets, and what is refused. Then a squashfs image whose data
# and metadata blocks come from them, read by unsquashfs when
# squashfs-tools is installed, and how fast the blocks are stored. Native
# lane, built with sanitizers as tests/tls.sh builds them, and once more
# with ZIP_PORTABLE for the path with no compiler builtin.
# ZIP_SPEED_MIB sets the speed check's data (128; 0 skips it).
set -euo pipefail
cd "$(dirname "$0")/.."
case "$(uname)" in Darwin) SANITIZE=${SANITIZE:-undefined};; *) SANITIZE=${SANITIZE:-address,undefined};; esac
work=$(mktemp -d /tmp/bkzip.XXXXXX)
trap 'rm -rf "$work"' EXIT
fails=0
pass() { echo "ok   $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
check=tests/fixtures/zip_check.py

echo "== build"
bend tests/fixtures/zip.bend -o "$work/zip.c" > "$work/build.log" 2>&1 || { cat "$work/build.log"; exit 1; }
clang -std=c11 -O0 -g -fno-omit-frame-pointer -fsanitize="$SANITIZE" -fno-sanitize-recover=all \
  "$work/zip.c" -lpthread -lm -ldl -o "$work/zip" > "$work/build.log" 2>&1 \
  || { grep -v "warning\|note:\|^ " "$work/build.log" | tail -20; exit 1; }
clang -std=c11 -O0 -g -fno-omit-frame-pointer -fsanitize="$SANITIZE" -fno-sanitize-recover=all -DZIP_PORTABLE \
  "$work/zip.c" -lpthread -lm -ldl -o "$work/zip-portable" > "$work/build.log" 2>&1 \
  || { grep -v "warning\|note:\|^ " "$work/build.log" | tail -20; exit 1; }
pass "native compressor with -fsanitize=$SANITIZE"
Z=$work/zip
D=$work/data.bin
python3 -I $check data "$D"
B=131072

# fx ARG...: the fixture's answer in $work/words. Fails on a sanitizer
# report, but for the one leak Bend's runtime makes on purpose (main's
# argument array, as tests/tls.sh's leaks() has it).
fx() {
  "$Z" "$@" > "$work/words" 2> "$work/err" || true
  if grep -E "ERROR: AddressSanitizer|runtime error" "$work/err" > /dev/null \
    || [ -n "$(awk '/^(Direct|Indirect) leak/ { head = $0; getline; getline; if ($0 !~ / in main /) print head }' "$work/err")" ]; then
    got="a sanitizer report: $(grep -m1 -E "ERROR|runtime error|leak" "$work/err")"
    return 1
  fi
}
# fill N: $work/out as N bytes of 0xA5, what a run must leave alone
fill() { : > "$work/out"; [ "$1" = 0 ] || head -c "$1" /dev/zero | LC_ALL=C tr '\0' '\245' > "$work/out"; }
# run SRC OFF_HI OFF_LO LEN BLOCK AT_HI AT_LO FILL [zip_check options]:
# Zip.blocks into a fresh $work/out, checked; what the check says in $got
run() {
  local src=$1 oh=$2 ol=$3 len=$4 block=$5 ah=$6 al=$7 n=$8; shift 8
  fill "$n"
  fx 5 "$src" "$oh" "$ol" 0 "$len" "$block" "$work/out" "$ah" "$al" || return 1
  got=$(python3 -I $check blocks "$src" $((oh * 4294967296 + ol)) "$len" "$block" "$work/out" $((ah * 4294967296 + al)) "$n" "$work/words" "$@" 2>&1)
}
# stored NAME OFF LEN BLOCK AT FILL [options]: that range of the test data
stored() {
  local name=$1; shift
  if run "$D" 0 "$1" "$2" "$3" 0 "$4" "$5" "${@:6}"; then pass "$name: ${got#ok }"; else fail "$name: $got"; fi
}
# sizes NAME OFF LEN BLOCK...: the range stored with each block size, one line
sizes() {
  local name=$1 off=$2 len=$3 bad=0 b; shift 3
  for b in "$@"; do
    run "$D" 0 "$off" "$len" "$b" 0 5 9 || { fail "$name, blocks of $b: $got"; bad=1; }
  done
  [ $bad = 1 ] || pass "$name"
}
# refused NAME WANT ARG...: the fixture fails, saying WANT
refused() {
  local name=$1 want=$2; shift 2
  fill 16
  fx "$@" || { fail "$name: $got"; return; }
  local said; said=$(cat "$work/words")
  case "$said" in "fail "*"$want"*) pass "$name ($said)";; *) fail "$name was not refused: ${said:0:120}";; esac
}

echo "== blocks"
stored "words, random bytes, zeros and repeats, 128 KiB blocks" 0 3518910 $B 96 96
stored "the same at 4 KiB" 0 3518910 4096 96 96
stored "the same at 1 MiB, inside a larger file" 0 3518910 1048576 1000 5000000
stored "no bytes: no block, nothing written" 0 0 $B 10 50 --raw 0
stored "1 byte, raw" 0 1 $B 10 50 --raw 1
stored "random bytes stay raw" 1200000 1000000 $B 0 0 --raw 8
stored "random bytes then words, a short last block" 2000000 300000 $B 0 0
stored "64 KiB of literals before a match" 2134464 $B $B 0 0 --raw 0
stored "a megabyte of zeros in one block" 2200000 1048576 1048576 7 3 --raw 0
stored "one byte under a block" 0 $((B - 1)) $B 0 0 --raw 0
stored "one block" 0 $B $B 0 0 --raw 0
stored "one byte over a block: a raw block of 1" 0 $((B + 1)) $B 0 0 --raw 1
stored "a copy 65535 bytes back is found" 3248576 131070 1048576 0 0 --raw 0
stored "a copy 65536 bytes back is too far: raw" 3379646 131072 1048576 0 0 --raw 1
small=$(seq 1 48)
sizes "zeros in blocks of 1 to 48 bytes (12 is the least that holds a match), and more" 2200000 1000 $small 255 256 270 271 272 273 274 275 4096
sizes "two letters at random in blocks of 1 to 48 bytes: matches up to each block's end" 3510718 2000 $small
sizes "the same in blocks of 100 to 8192 bytes" 3510718 8192 100 255 256 257 1000 4095 4096 8191 8192
sizes "words in blocks of 13 to 8192 bytes" 0 20000 13 14 15 16 17 18 19 20 31 32 33 64 127 1000 4096 8192
python3 -I -c 'import sys
with open(sys.argv[1], "rb") as f, open(sys.argv[2], "wb") as g:
    g.truncate(4294967296 + 4096); g.seek(4294967296 + 4096); g.write(f.read(300000))' "$D" "$work/far.bin"
if run "$work/far.bin" 1 4096 300000 $B 1 12345 0; then pass "offsets past 4 GiB in both files: ${got#ok }"; else fail "offsets past 4 GiB: $got"; fi
rm -f "$work/far.bin"
Z=$work/zip-portable
stored "ZIP_PORTABLE: words, random bytes, zeros and repeats" 0 3518910 $B 96 96
sizes "ZIP_PORTABLE: two letters at random in blocks of 1 to 48 bytes" 3510718 2000 $small
Z=$work/zip

echo "== refused"
refused "a range past the source's end" "ends inside the range" 5 "$D" 0 3500000 0 100000 $B "$work/out" 0 0
refused "a block of no bytes" "from 1 to 1048576" 5 "$D" 0 0 0 100 0 "$work/out" 0 0
refused "a block past 1 MiB" "from 1 to 1048576" 5 "$D" 0 0 0 100 1048577 "$work/out" 0 0
refused "another compressor (zlib, 1)" "no such compressor" 1 "$D" 0 0 0 100 $B "$work/out" 0 0
refused "a range past 2^63" "passes 2^63" 5 "$D" 2147483648 0 0 100 $B "$work/out" 0 0

echo "== pack"
# packed NAME OFF LEN [options]: Zip.pack of that range of the test data
packed() {
  local name=$1 off=$2 len=$3; shift 3
  python3 -I -c 'import sys
with open(sys.argv[1], "rb") as f:
    f.seek(int(sys.argv[2])); open(sys.argv[4], "wb").write(f.read(int(sys.argv[3])))' "$D" "$off" "$len" "$work/in"
  fx 5 "$work/in" "$work/out" || { fail "$name: $got"; return; }
  if got=$(python3 -I $check pack "$work/in" "$work/out" "$work/words" "$@" 2>&1); then pass "$name: ${got#ok }"; else fail "$name: $got"; fi
}
packed "no bytes: raw and empty" 0 0 --raw 1
[ "$(cat "$work/words")" = "ok 16777216" ] && pass "no bytes answer the word 16777216" || fail "no bytes: $(cat "$work/words")"
packed "1 byte, raw" 0 1 --raw 1
packed "12 zeros, raw" 2200000 12 --raw 1
packed "13 zeros" 2200000 13 --raw 0
packed "a metadata block of words (8192 bytes)" 0 8192 --raw 0
packed "8192 random bytes, raw" 1200000 8192 --raw 1
packed "a megabyte of zeros" 2200000 1048576 --raw 0
python3 -I -c 'import sys; open(sys.argv[1], "wb").write(bytes(1048577))' "$work/in"
refused "a block past 1 MiB" "at most 1048576" 5 "$work/in" "$work/out"
refused "another compressor (zstd, 6)" "no such compressor" 6 "$work/in" "$work/out"

echo "== squashfs"
if command -v unsquashfs > /dev/null; then
  if said=$(python3 -I tests/fixtures/zip_sqfs.py "$Z" "$D" "$work/img.sqfs" "$work/in" 2>&1) \
     && unsquashfs -cat "$work/img.sqfs" data 2> "$work/build.log" | cmp -s - "$D"; then
    pass "unsquashfs reads an lz4 image made of these blocks (${said#ok })"
  else
    fail "the squashfs image: $said $(tail -3 "$work/build.log")"
  fi
  rm -f "$work/img.sqfs"
else
  echo "SKIP squashfs-tools is not installed"
fi

mib=${ZIP_SPEED_MIB:-128}
if [ "$mib" != 0 ]; then
  echo "== speed"
  # as a program built by bend runs it; files of /usr in 128 KiB blocks
  bend tests/fixtures/zip.bend -o "$work/zip-fast" > "$work/build.log" 2>&1 || { cat "$work/build.log"; exit 1; }
  python3 -I $check corpus "$work/corpus.bin" "$mib"
  fill 96
  said=$(python3 -I $check speed "$work/words" $((mib * 1048576)) 3 \
    "$work/zip-fast" 5 "$work/corpus.bin" 0 0 0 $((mib * 1048576)) $B "$work/out" 0 96)
  if got=$(python3 -I $check blocks "$work/corpus.bin" 0 $((mib * 1048576)) $B "$work/out" 96 96 "$work/words" --quick 2>&1); then
    pass "$said; ${got#ok }"
  else
    fail "the speed check's blocks: $got"
  fi
fi
[ $fails = 0 ] && echo "all compression tests pass" || { echo "$fails failed"; exit 1; }
