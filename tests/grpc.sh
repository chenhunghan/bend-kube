#!/bin/bash
# Tests grpcio.bend's gRPC server and client over a Unix socket, h2c, with
# tests/fixtures/grpc_echo.bend serving echo.proto's bendtest.Echo: Bend's
# client, and grpcurl (a grpc-go client, as containerd's is) for unary and
# server-streaming calls, error statuses, deadlines and calls at once.
# Native lane, built with sanitizers as tests/tls.sh builds them.
# grpcurl's checks are skipped when it is not installed.
set -euo pipefail
cd "$(dirname "$0")/.."
case "$(uname)" in Darwin) SANITIZE=${SANITIZE:-undefined};; *) SANITIZE=${SANITIZE:-address,undefined};; esac
work=$(mktemp -d /tmp/bkgr.XXXXXX)
trap 'exec 2>/dev/null; kill $(jobs -p) || true; wait || true; rm -rf "$work"' EXIT
fails=0
pass() { echo "ok   $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
expect() {  # expect NAME WANT GOT
  if [ "$3" = "$2" ]; then pass "$1"; else fail "$1: want '$2', got '$3'"; fi
}

echo "== build"
bend tests/fixtures/grpc_echo.bend -o "$work/echo.c" > "$work/build.log" 2>&1 || { cat "$work/build.log"; exit 1; }
clang -std=c11 -O0 -g -fno-omit-frame-pointer -fsanitize="$SANITIZE" -fno-sanitize-recover=all \
  "$work/echo.c" -lpthread -lm -o "$work/echo" > "$work/build.log" 2>&1 \
  || { grep -v "warning\|note:\|^ " "$work/build.log" | tail -20; exit 1; }
pass "native echo with -fsanitize=$SANITIZE"
E=$work/echo
S=$work/g.sock
"$E" serve "$S" > "$work/serve.log" 2>&1 &
for _ in $(seq 1 100); do grep -q listening "$work/serve.log" 2>/dev/null && break; sleep 0.05; done

echo "== Bend client"
call() { timeout 30 "$E" call "$S" "/bendtest.Echo/$1" "$2" "$3" "$4"; }
expect "unary" "[hi bob/4]" "$(call Say bob 3 0)"
expect "server streaming" "[i/0, i/1, i/2]" "$(call Count x 3 0)"
expect "an error status, its message percent-encoded" "status 3: bad: bob ✓ 100%" "$(call Fail bob 0 0)"
expect "an unknown method" "status 12: unknown method /bendtest.Echo/Nope" "$(call Nope x 0 0)"
expect "a deadline that passes" "status 4: the deadline passed" "$(call Slow x 3000 300)"
expect "a deadline that holds" "[hi x/101]" "$(call Slow x 100 5000)"

if command -v grpcurl > /dev/null; then
  echo "== grpcurl (grpc-go)"
  g() {  # g METHOD ARGS...
    local m=$1; shift
    grpcurl -plaintext -import-path tests/fixtures -proto echo.proto "$@" "unix://$S" "bendtest.Echo/$m" 2>&1 || true
  }
  got=$(g Say -d '{"text":"alice","n":41,"tags":["a","b"],"labels":{"k":"v"}}' | tr -d ' \n')
  expect "unary with every field kind" '{"text":"hialice","n":"42","tags":["b","a"],"labels":{"k":"v"}}' "$got"
  expect "server streaming, 200 messages" 200 "$(g Count -d '{"n":200}' | grep -c '"text"')"
  got=$(g Fail -d '{"text":"x"}' | tr '\n' ' ')
  case "$got" in *InvalidArgument*"bad: x ✓ 100%"*) pass "an error status";; *) fail "error status: $got";; esac
  got=$(g Slow -max-time 0.3 -d '{"n":3000}' | tr '\n' ' ')
  case "$got" in *DeadlineExceeded*) pass "a deadline that passes";; *) fail "deadline: $got";; esac
  got=$(g Say -d '{}' | tr -d ' \n')
  expect "an empty request" '{"text":"hi","n":"1"}' "$got"
  pids=()
  for i in $(seq 1 20); do g Say -d "{\"text\":\"p$i\"}" > "$work/p$i.out" & pids+=($!); done
  wait "${pids[@]}" || true
  n=0; for i in $(seq 1 20); do grep -q "\"hi p$i\"" "$work/p$i.out" && n=$((n + 1)); done
  expect "20 grpc-go clients at once" 20 "$n"
else
  echo "SKIP grpcurl is not installed"
fi
expect "the server still answers" "[hi end/1]" "$(call Say end 0 0)"

if grep -q "runtime error\|Sanitizer" "$work/serve.log"; then
  fail "sanitizer reports"; cat "$work/serve.log"
else
  pass "the server ran clean under -fsanitize=$SANITIZE"
fi
[ $fails = 0 ] && echo "all gRPC tests pass" || { echo "$fails failed"; exit 1; }
