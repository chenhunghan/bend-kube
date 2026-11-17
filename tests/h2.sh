#!/bin/bash
# Tests h2io.bend's HTTP/2 server and client (h2c) over a Unix socket and
# TCP: Bend's client against Bend's server, one call and many at once on
# one connection; curl (nghttp2) against Bend's server, small and large
# bodies both ways; and a client that does not speak HTTP/2, which must
# not take the server down. Native lane, built with sanitizers as
# tests/tls.sh builds them. curl's checks are skipped when its build lacks
# HTTP/2.
set -euo pipefail
cd "$(dirname "$0")/.."
case "$(uname)" in Darwin) SANITIZE=${SANITIZE:-undefined};; *) SANITIZE=${SANITIZE:-address,undefined};; esac
work=$(mktemp -d /tmp/bkh2.XXXXXX)
trap 'exec 2>/dev/null; kill $(jobs -p) || true; wait || true; rm -rf "$work"' EXIT
fails=0
pass() { echo "ok   $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }
expect() {  # expect NAME WANT GOT
  if [ "$3" = "$2" ]; then pass "$1"; else fail "$1: want '$2', got '$3'"; fi
}

echo "== build"
bend tests/fixtures/h2_echo.bend -o "$work/echo.c" > "$work/build.log" 2>&1 || { cat "$work/build.log"; exit 1; }
clang -std=c11 -O0 -g -fno-omit-frame-pointer -fsanitize="$SANITIZE" -fno-sanitize-recover=all \
  "$work/echo.c" -lpthread -lm -o "$work/echo" > "$work/build.log" 2>&1 \
  || { grep -v "warning\|note:\|^ " "$work/build.log" | tail -20; exit 1; }
pass "native echo with -fsanitize=$SANITIZE"
E=$work/echo
S=$work/s.sock
PORT=${H2_PORT:-24431}

wait_for() {
  for _ in $(seq 1 100); do grep -q listening "$1" 2>/dev/null && return 0; sleep 0.05; done
  cat "$1"; return 1
}
"$E" serve-unix "$S" > "$work/unix.log" 2>&1 &
"$E" serve-tcp "$PORT" > "$work/tcp.log" 2>&1 &
wait_for "$work/unix.log"; wait_for "$work/tcp.log"

echo "== Bend client"
expect "a call" "200 hi0 [x-done=yes]" "$(timeout 20 "$E" call-unix "$S" /x hi)"
n=$(timeout 60 "$E" call-unix "$S" /many c 20 | grep -c "^200 c[0-9]* \[x-done=yes\]$" || true)
expect "20 calls at once on one connection" 20 "$n"

if curl -V | grep -q HTTP2; then
  echo "== curl"
  c() { curl -sS --max-time 30 --http2-prior-knowledge "$@"; }
  expect "curl GET over the Unix socket" "hello /hello" "$(c --unix-socket "$S" http://localhost/hello)"
  expect "curl sees HTTP/2 and the headers" "2 200 /h" \
    "$(c --unix-socket "$S" http://localhost/h -o /dev/null -w '%{http_version} %{http_code} ' -D "$work/h.txt"; grep -i '^x-path' "$work/h.txt" | cut -d' ' -f2 | tr -d '\r')"
  expect "curl GET over TCP" "hello /tcp" "$(c "http://127.0.0.1:$PORT/tcp")"
  # 1.5 MB: past our 1 MiB stream window, which must be given back
  head -c 1500000 /dev/urandom > "$work/big.bin"
  c --max-time 300 --unix-socket "$S" http://localhost/big --data-binary @"$work/big.bin" -o "$work/big.back"
  cmp -s "$work/big.bin" "$work/big.back" && pass "1.5 MB up and back, past our windows" || fail "1.5 MB came back different"
  pids=()
  for i in $(seq 1 10); do c --unix-socket "$S" "http://localhost/p$i" > "$work/p$i.out" & pids+=($!); done
  wait "${pids[@]}" || true
  n=0; for i in $(seq 1 10); do [ "$(cat "$work/p$i.out")" = "hello /p$i" ] && n=$((n + 1)); done
  expect "10 curl connections at once" 10 "$n"
else
  echo "SKIP curl lacks HTTP/2"
fi

echo "== misbehaving clients"
printf 'GET / HTTP/1.1\r\nHost: x\r\n\r\n' | timeout 5 python3 -I -c '
import socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1]); s.sendall(sys.stdin.buffer.read())
s.settimeout(5); data = b""
while True:
    b = s.recv(4096)
    if not b: break
    data += b
sys.exit(0 if b"\x00\x00\x00\x00" in data or data[3:4] == b"\x07" or b"\x07\x00\x00\x00\x00\x00" in data else 1)
' "$S" && pass "an HTTP/1.1 client gets a GOAWAY and the close" || fail "an HTTP/1.1 client was not refused"
timeout 5 python3 -I -c '
import socket, sys
s = socket.socket(socket.AF_UNIX); s.connect(sys.argv[1])
s.sendall(b"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n" + b"\x00\x00\x00\x04\x00\x00\x00\x00\x00" + b"\x00\x40\x01\x00\x00\x00\x00\x00\x01")
s.close()
' "$S" && pass "a client that sends an oversized frame and leaves"
expect "the server still answers" "200 after0 [x-done=yes]" "$(timeout 20 "$E" call-unix "$S" /x after)"

if grep -q "runtime error\|Sanitizer" "$work"/unix.log "$work"/tcp.log; then
  fail "sanitizer reports"; cat "$work"/unix.log "$work"/tcp.log
else
  pass "the servers ran clean under -fsanitize=$SANITIZE"
fi
[ $fails = 0 ] && echo "all HTTP/2 tests pass" || { echo "$fails failed"; exit 1; }
