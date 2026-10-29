#!/bin/bash
# Tests net.bend's TLS and proxy handling against local servers, on both
# lanes: openssl s_server (good, wrong CA, wrong name, expired, TLS 1.1,
# client certificates), misbehaving servers (fixtures/tls_bad.py) and a
# CONNECT proxy (fixtures/connect_proxy.py). No cluster needed.
#
# The native lane is built with sanitizers: SANITIZE (default
# address,undefined on Linux, undefined on macOS, whose ASan runtime hangs
# at start on recent releases); any sanitizer report fails the test.
# Needs bend, clang, openssl (OPENSSL to pick one) and python3.
set -euo pipefail
cd "$(dirname "$0")/.."
OPENSSL=${OPENSSL:-openssl}
case "$(uname)" in Darwin) SANITIZE=${SANITIZE:-undefined};; *) SANITIZE=${SANITIZE:-address,undefined};; esac
work=$(mktemp -d)
trap 'exec 2>/dev/null; kill $(jobs -p) || true; wait || true; rm -rf "$work"' EXIT
fails=0
pass() { echo "ok   $*"; }
fail() { echo "FAIL $*"; fails=$((fails + 1)); }

echo "== certificates"
cd "$work"
ossl() { "$OPENSSL" "$@" 2>/dev/null; }
ca() {  # ca NAME
  ossl req -x509 -newkey rsa:2048 -nodes -keyout "$1.key" -out "$1.crt" -days 2 -subj "/CN=$1" \
    -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign
}
leaf() {  # leaf NAME SAN EKU [x509 args...]
  local n=$1 san=$2 eku=$3; shift 3
  ossl req -newkey rsa:2048 -nodes -keyout "$n.key" -out "$n.csr" -subj "/CN=$n"
  printf 'subjectAltName=%s\nextendedKeyUsage=%s\n' "$san" "$eku" > "$n.ext"
  ossl x509 -req -in "$n.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -out "$n.crt" -extfile "$n.ext" "$@"
}
ca ca; ca other
leaf server "IP:127.0.0.1,DNS:bend.test" serverAuth -days 2
leaf wrongname "DNS:other.test" serverAuth -days 2
leaf expired "IP:127.0.0.1" serverAuth -not_before 20200101000000Z -not_after 20200102000000Z
leaf client "DNS:client" clientAuth -days 2
cd - >/dev/null
pass certificates

echo "== build"
sym=$(command -v llvm-symbolizer || ls /usr/bin/llvm-symbolizer* 2>/dev/null | head -1 || true)
[ -n "$sym" ] && export ASAN_SYMBOLIZER_PATH=$sym
bend tests/fixtures/tls_probe.bend -o "$work/probe.c" > "$work/build.log" 2>&1 \
  || { cat "$work/build.log"; exit 1; }
# -O0: when optimizing, Bend's runtime uses clang's preserve_none calling
# convention, which LLVM cannot combine with ASan's stack frames on x86_64.
clang -std=c11 -O0 -g -fno-omit-frame-pointer -fsanitize="$SANITIZE" -fno-sanitize-recover=all \
  "$work/probe.c" -lpthread -lm -o "$work/probe" > "$work/build.log" 2>&1 \
  || { grep -v "warning\|note:\|^ " "$work/build.log" | tail -20; exit 1; }
pass "native probe with -fsanitize=$SANITIZE"

echo "== servers"
srv() {  # srv PORT ARGS...: an s_server that answers GETs with a status page
  local p=$1; shift
  "$OPENSSL" s_server -accept "127.0.0.1:$p" -www -quiet "$@" >/dev/null 2>&1 &
}
W=$work
srv 24401 -cert $W/server.crt -key $W/server.key
srv 24402 -cert $W/wrongname.crt -key $W/wrongname.key
srv 24403 -cert $W/expired.crt -key $W/expired.key
srv 24404 -cert $W/server.crt -key $W/server.key -tls1_1 -cipher DEFAULT@SECLEVEL=0
srv 24405 -cert $W/server.crt -key $W/server.key -Verify 1 -CAfile $W/ca.crt
python3 -I tests/fixtures/tls_bad.py 24406 hangup &
python3 -I tests/fixtures/tls_bad.py 24407 plain &
python3 -I tests/fixtures/tls_bad.py 24408 silent &
python3 -I tests/fixtures/tls_bad.py 24409 truncated $W/server.crt $W/server.key &
python3 -I tests/fixtures/tls_bad.py 24410 oversized $W/server.crt $W/server.key &
python3 -I tests/fixtures/tls_bad.py 24414 drip &
python3 -I tests/fixtures/connect_proxy.py 24411 bend.test=127.0.0.1 > $W/proxy.log 2>&1 &
python3 -I tests/fixtures/tls_bad.py 24412 proxy-extra &
python3 -I tests/fixtures/tls_bad.py 24413 proxy-close &
sleep 1.5
pass "servers up"

# run LANE HOST PORT [VAR=VALUE...]: the probe's output (stdout and
# stderr), bounded to 20s. CA is ca.crt unless PROBE_CA is given.
run() {
  local lane=$1 host=$2 port=$3; shift 3
  local cmd=("$work/probe")
  [ "$lane" = js ] && cmd=(bend tests/fixtures/tls_probe.bend)
  env -u HTTPS_PROXY -u https_proxy -u NO_PROXY -u no_proxy PROBE_CA="$(cat $W/ca.crt)" "$@" \
    perl -e 'alarm shift; exec @ARGV' 20 "${cmd[@]}" "$host" "$port" 2>&1 || true
}
# The leaks LeakSanitizer reports, but for the one Bend's runtime makes on
# purpose: main's argument array, allocated by main itself, kept for the
# process's life.
leaks() {
  awk '/^(Direct|Indirect) leak/ { head = $0; getline; getline; if ($0 !~ / in main /) print head }'
}
# want LANE NAME REGEX HOST PORT [VAR=VALUE...]
want() {
  local lane=$1 name=$2 re=$3; shift 3
  local out; out=$(run "$lane" "$@")
  if printf '%s\n' "$out" | grep -E "ERROR: AddressSanitizer|runtime error" >/dev/null \
    || [ -n "$(printf '%s\n' "$out" | leaks)" ]; then
    fail "$lane: $name: sanitizer report"; printf '%s\n' "$out" | grep -v WARNING | head -30
  elif printf '%s\n' "$out" | grep -E '^(ok|error)' | tail -1 | grep -E -- "$re" >/dev/null; then
    pass "$lane: $name"
  else
    fail "$lane: $name: wanted /$re/, got: $(printf '%s\n' "$out" | grep -E '^(ok|error)' | tail -1)"
  fi
}

CERT="PROBE_CERT=$(cat $W/client.crt)"; KEY="PROBE_KEY=$(cat $W/client.key)"
OTHER="PROBE_CA=$(cat $W/other.crt)"
PROXY="HTTPS_PROXY=http://user:s3cret@127.0.0.1:24411"
for lane in native js; do
  echo "== $lane: TLS"
  want $lane "verified server" '^ok HTTP/1.0 200' 127.0.0.1 24401
  want $lane "unknown CA rejected" 'server certificate rejected' 127.0.0.1 24401 "$OTHER"
  want $lane "wrong name rejected" 'server certificate rejected' 127.0.0.1 24402
  want $lane "expired certificate rejected" 'server certificate rejected' 127.0.0.1 24403
  want $lane "TLS 1.1 refused" '^error: TLS' 127.0.0.1 24404
  want $lane "missing client certificate refused" '^error' 127.0.0.1 24405
  want $lane "client certificate accepted" '^ok HTTP/1.0 200' 127.0.0.1 24405 "$CERT" "$KEY"
  want $lane "bad client key refused" '^error: TLS' 127.0.0.1 24405 "$CERT" "PROBE_KEY=junk"
  want $lane "empty CA bundle refused" '^error: TLS' 127.0.0.1 24401 "PROBE_CA=junk"
  echo "== $lane: hostile servers"
  want $lane "hangup" '^error: TLS' 127.0.0.1 24406
  want $lane "plain HTTP on the TLS port" '^error: TLS' 127.0.0.1 24407
  want $lane "silent server times out" "^error: TLS: handshake timed out" 127.0.0.1 24408
  t0=$(date +%s)
  want $lane "a byte a second still times out" "^error: TLS: handshake timed out" 127.0.0.1 24414
  [ $(( $(date +%s) - t0 )) -le 8 ] && pass "$lane: the handshake deadline is total" || fail "$lane: slow loris held the handshake"
  want $lane "truncated record" '^error' 127.0.0.1 24409
  want $lane "oversized record" '^error' 127.0.0.1 24410
  want $lane "nothing listening" '^error: connect' 127.0.0.1 24499
  want $lane "unresolvable name" '^error: (connect|resolve)' no-such-host.invalid 24401
  echo "== $lane: proxy"
  before=$(grep -c CONNECT $W/proxy.log || true)
  want $lane "CONNECT tunnel, verified end to end" '^ok HTTP/1.0 200' bend.test 24401 "$PROXY"
  [ "$(grep -c 'CONNECT bend.test:24401 auth-ok' $W/proxy.log)" -gt 0 ] \
    && pass "$lane: proxy saw the CONNECT with credentials" || fail "$lane: proxy log"
  want $lane "tunnel to a wrong name rejected" 'server certificate rejected' bend.test 24402 "$PROXY"
  want $lane "lowercase https_proxy" '^ok HTTP/1.0 200' bend.test 24401 "https_proxy=http://user:s3cret@127.0.0.1:24411"
  want $lane "percent-encoded credentials" '^ok HTTP/1.0 200' bend.test 24401 "HTTPS_PROXY=http://us%65r:s3cr%65t@127.0.0.1:24411"
  want $lane "407 reported" '407' bend.test 24401 "HTTPS_PROXY=http://user:wrong@127.0.0.1:24411"
  want $lane "502 reported" '502' nowhere.invalid 24401 "$PROXY"
  n=$(grep -c CONNECT $W/proxy.log)
  want $lane "loopback bypasses the proxy" '^ok HTTP/1.0 200' 127.0.0.1 24401 "$PROXY"
  want $lane "NO_PROXY bypasses the proxy" '^error: (connect|resolve)' bend.test 24401 "$PROXY" "NO_PROXY=.example,bend.test"
  [ "$(grep -c CONNECT $W/proxy.log)" = "$n" ] && pass "$lane: bypasses never reached the proxy" || fail "$lane: bypass used the proxy"
  want $lane "https:// proxy refused, not bypassed" 'only http:// proxies' bend.test 24401 "HTTPS_PROXY=https://127.0.0.1:24411"
  want $lane "bytes after the CONNECT answer" 'bytes before the TLS handshake' bend.test 24401 "HTTPS_PROXY=127.0.0.1:24412"
  want $lane "proxy closes before answering" 'closed the connection before answering' bend.test 24401 "HTTPS_PROXY=127.0.0.1:24413"
  want $lane "proxy down" '^error: proxy: ' bend.test 24401 "HTTPS_PROXY=127.0.0.1:24498"
done

echo
[ $fails = 0 ] && echo "all TLS tests pass" || { echo "$fails TLS tests failed"; exit 1; }
