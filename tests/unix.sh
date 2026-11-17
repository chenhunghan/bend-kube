#!/bin/bash
# Tests sys.bend's Unix sockets (Sys.unix_listen, Sys.unix_connect) on the
# native lane, built with sanitizers as tests/tls.sh builds them, and the
# JS lane's refusal. Sockets live in /tmp: macOS caps a socket path at
# 103 bytes, which a deep temporary directory can pass.
set -euo pipefail
cd "$(dirname "$0")/.."
case "$(uname)" in Darwin) SANITIZE=${SANITIZE:-undefined};; *) SANITIZE=${SANITIZE:-address,undefined};; esac
work=$(mktemp -d /tmp/bkux.XXXXXX)
trap 'exec 2>/dev/null; kill $(jobs -p) || true; wait || true; rm -rf "$work"' EXIT
fails=0
pass() { echo "ok   $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
expect() {  # expect NAME WANT GOT
  if [ "$3" = "$2" ]; then pass "$1"; else fail "$1: want '$2', got '$3'"; fi
}

echo "== build"
bend tests/fixtures/unix_echo.bend -o "$work/echo.c" > "$work/build.log" 2>&1 || { cat "$work/build.log"; exit 1; }
clang -std=c11 -O0 -g -fno-omit-frame-pointer -fsanitize="$SANITIZE" -fno-sanitize-recover=all \
  "$work/echo.c" -lpthread -lm -o "$work/echo" > "$work/build.log" 2>&1 \
  || { grep -v "warning\|note:\|^ " "$work/build.log" | tail -20; exit 1; }
pass "native echo with -fsanitize=$SANITIZE"
E=$work/echo
S=$work/s.sock

wait_for() {  # wait_for FILE: until the server says it listens
  for _ in $(seq 1 100); do grep -q listening "$1" 2>/dev/null && return 0; sleep 0.05; done
  return 1
}

echo "== native"
"$E" serve "$S" > "$work/serve.log" 2>&1 &
srv=$!
wait_for "$work/serve.log" || { cat "$work/serve.log"; exit 1; }
expect "a call gets its echo" "reply hello" "$("$E" call "$S" hello)"
expect "a second call too" "reply again" "$("$E" call "$S" again)"
mode=$(ls -l "$S" | cut -c1-10)
expect "the socket file is the owner's only" "srw-------" "$mode"
got=$("$E" listen "$S")
case "$got" in "fail "*) pass "a live socket is not taken over ($got)";; *) fail "a live socket was taken over: $got";; esac
expect "the first server still answers" "reply still" "$("$E" call "$S" still)"
kill -9 $srv; wait $srv 2>/dev/null || true
[ -S "$S" ] && pass "a killed server leaves its socket file" || fail "no socket file left"
"$E" serve "$S" > "$work/serve2.log" 2>&1 &
srv=$!
wait_for "$work/serve2.log" || { fail "a stale socket file blocks a new server"; cat "$work/serve2.log"; }
expect "a new server replaces the stale socket" "reply new" "$("$E" call "$S" new)"
pids=()
for i in $(seq 1 20); do "$E" call "$S" "c$i" > "$work/c$i.out" & pids+=($!); done
wait "${pids[@]}" || true
n=0; for i in $(seq 1 20); do [ "$(cat "$work/c$i.out")" = "reply c$i" ] && n=$((n + 1)); done
expect "20 calls at once, each answered" 20 "$n"
kill $srv; wait $srv 2>/dev/null || true
echo keep > "$work/file"
got=$("$E" listen "$work/file")
case "$got" in "fail "*) pass "a regular file is refused ($got)";; *) fail "a regular file was replaced: $got";; esac
expect "and left as it was" "keep" "$(cat "$work/file")"
long=$work/$(printf 'x%.0s' $(seq 1 120)).sock
got=$("$E" listen "$long")
case "$got" in "fail "*"too long"*) pass "a path past sun_path is refused";; *) fail "long path: $got";; esac
got=$("$E" call "$work/missing.sock" x)
case "$got" in "fail "*) pass "a call to no socket fails ($got)";; *) fail "missing socket: $got";; esac
if grep -q "runtime error\|Sanitizer" "$work"/serve*.log; then
  fail "sanitizer reports"; cat "$work"/serve*.log
else
  pass "the servers ran clean under -fsanitize=$SANITIZE"
fi

echo "== js"
got=$(bend tests/fixtures/unix_echo.bend listen "$work/js.sock" 2>&1)
case "$got" in *"native lane"*) pass "js: Unix sockets say they need the native lane";; *) fail "js: $got";; esac

[ $fails = 0 ] && echo "all Unix socket tests pass" || { echo "$fails failed"; exit 1; }
