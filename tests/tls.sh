#!/bin/bash
# Tests net.bend's TLS and proxy handling against local servers, on both
# lanes: openssl s_server (good, wrong CA, wrong name, expired, TLS 1.1,
# client certificates), misbehaving servers (fixtures/tls_bad.py) and a
# CONNECT proxy (fixtures/connect_proxy.py). No cluster needed. Also
# OpenSSL's loader (fixtures/tls_avail.bend: Tls.available, a failure
# retried within one process, a success kept) and, on macOS, the system's
# LibreSSL through the same checks.
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
# a certificate naming the server only in its CN, with no SAN
ossl req -newkey rsa:2048 -nodes -keyout cnonly.key -out cnonly.csr -subj "/CN=bend.test"
printf 'extendedKeyUsage=serverAuth\n' > cnonly.ext
ossl x509 -req -in cnonly.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out cnonly.crt -extfile cnonly.ext -days 2
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
bend tests/fixtures/tls_avail.bend -o "$work/avail.c" > "$work/build.log" 2>&1 \
  || { cat "$work/build.log"; exit 1; }
clang -std=c11 -O0 -g -fno-omit-frame-pointer -fsanitize="$SANITIZE" -fno-sanitize-recover=all \
  "$work/avail.c" -lpthread -lm -o "$work/avail" > "$work/build.log" 2>&1 \
  || { grep -v "warning\|note:\|^ " "$work/build.log" | tail -20; exit 1; }
pass "native probe with -fsanitize=$SANITIZE"

echo "== native: loading OpenSSL"
# avail_want NAME WANT CRYPTO SSL [VAR=VALUE...]: tls_avail's three lines,
# joined by "|", are WANT (a regex)
avail_want() {
  local name=$1 re=$2 crypto=$3 ssl=$4; shift 4
  local out; out=$(env -u BEND_KUBE_LIBCRYPTO -u BEND_KUBE_LIBSSL "$@" "$work/avail" "$crypto" "$ssl" 2>&1 || true)
  if printf '%s\n' "$out" | grep -E "ERROR: AddressSanitizer|runtime error" >/dev/null; then
    fail "native: $name: sanitizer report"; printf '%s\n' "$out" | head -20
  elif [ "$(printf '%s\n' "$out" | paste -sd'|' -)" != "" ] && printf '%s\n' "$out" | paste -sd'|' - | grep -Eq -- "$re"; then
    pass "native: $name"
  else
    fail "native: $name: wanted /$re/, got: $(printf '%s\n' "$out" | paste -sd'|' -)"
  fi
}
missing='TLS: OpenSSL not found \(set BEND_KUBE_LIBSSL and BEND_KUBE_LIBCRYPTO\)'
avail_want "Tls.available finds OpenSSL" '^1 ok\|2 ok\|3 ok$' "" ""
avail_want "Tls.available without OpenSSL says why" "^1 fail $missing\|2 fail $missing\|3 fail $missing\$" \
  /nonexistent /nonexistent BEND_KUBE_LIBCRYPTO=/nonexistent
avail_want "a failed load is retried: the search after unsetting the variable finds it" \
  "^1 fail $missing\|2 ok\|3 ok\$" "" "" BEND_KUBE_LIBCRYPTO=/nonexistent
avail_want "a load that succeeded stays, whatever the variables say later" '^1 ok\|2 ok\|3 ok$' \
  /nonexistent /nonexistent
# the same retry, to libraries named by path
case "$(uname)" in
  Darwin) d=""; for p in /opt/homebrew/opt/openssl@3/lib /usr/local/opt/openssl@3/lib; do
            [ -e "$p/libssl.3.dylib" ] && { d=$p; break; }; done
          lc=${d:+$d/libcrypto.3.dylib}; ls=${d:+$d/libssl.3.dylib};;
  *) lc=libcrypto.so.3; ls=libssl.so.3;;
esac
if [ -n "$lc" ]; then
  avail_want "a failed load is retried: variables set after it name the libraries" \
    "^1 fail $missing\|2 ok\|3 ok\$" "$lc" "$ls" BEND_KUBE_LIBCRYPTO=/nonexistent BEND_KUBE_LIBSSL=/nonexistent
else
  echo "skip native: no OpenSSL 3 found by path"
fi

echo "== servers"
srv() {  # srv PORT ARGS...: an s_server that answers GETs with a status page
  local p=$1; shift
  "$OPENSSL" s_server -accept "127.0.0.1:$p" -www -quiet "$@" >/dev/null 2>&1 &
}
W=$work
srv 24401 -cert $W/server.crt -key $W/server.key
srv 24415 -cert $W/cnonly.crt -key $W/cnonly.key
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
  want $lane "tls-server-name verifies instead of the host" '^ok HTTP/1.0 200' 127.0.0.1 24401 "PROBE_SERVER_NAME=bend.test"
  want $lane "tls-server-name must match" 'server certificate rejected' 127.0.0.1 24401 "PROBE_SERVER_NAME=other.test"
  want $lane "a name only in the CN is not taken" '^error' 127.0.0.1 24415 "PROBE_SERVER_NAME=bend.test"
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

# macOS's own LibreSSL (private to Apple, but dlopen-able): with
# SSL_CTX_set_options optional, the loader takes it, and it must verify as
# strictly as OpenSSL
LIBRE=(BEND_KUBE_LIBCRYPTO=/usr/lib/libcrypto.46.dylib BEND_KUBE_LIBSSL=/usr/lib/libssl.48.dylib)
if [ "$(uname)" = Darwin ] && [ "$(env "${LIBRE[@]}" "$work/avail" "" "" 2>/dev/null | head -1)" = "1 ok" ]; then
  echo "== native: macOS's LibreSSL"
  want native "LibreSSL: verified server" '^ok HTTP/1.0 200' 127.0.0.1 24401 "${LIBRE[@]}"
  want native "LibreSSL: unknown CA rejected" 'server certificate rejected' 127.0.0.1 24401 "$OTHER" "${LIBRE[@]}"
  want native "LibreSSL: wrong name rejected" 'server certificate rejected' 127.0.0.1 24402 "${LIBRE[@]}"
  want native "LibreSSL: a name only in the CN is not taken" '^error' 127.0.0.1 24415 "PROBE_SERVER_NAME=bend.test" "${LIBRE[@]}"
  want native "LibreSSL: expired certificate rejected" 'server certificate rejected' 127.0.0.1 24403 "${LIBRE[@]}"
  want native "LibreSSL: TLS 1.1 refused" '^error: TLS' 127.0.0.1 24404 "${LIBRE[@]}"
  want native "LibreSSL: client certificate accepted" '^ok HTTP/1.0 200' 127.0.0.1 24405 "$CERT" "$KEY" "${LIBRE[@]}"
else
  echo "skip native: macOS's LibreSSL (not macOS, or /usr/lib/libssl.48.dylib does not load)"
fi

echo "== native: TLS server (webhooks)"
bend examples/webhook.bend -o "$work/webhook.c" > "$work/build.log" 2>&1 || { cat "$work/build.log"; exit 1; }
clang -std=c11 -O0 -g -fno-omit-frame-pointer -fsanitize="$SANITIZE" -fno-sanitize-recover=all \
  "$work/webhook.c" -lpthread -lm -o "$work/webhook" > "$work/build.log" 2>&1 \
  || { grep -v "warning\|note:\|^ " "$work/build.log" | tail -20; exit 1; }
WEBHOOK_PORT=24420 WEBHOOK_CERT=$W/server.crt WEBHOOK_KEY=$W/server.key "$work/webhook" > "$work/webhook.log" 2>&1 &
wh_pid=$!
for _ in $(seq 1 50); do grep -q '"webhooks serving"' "$work/webhook.log" && break; sleep 0.1; done
review() { printf '{"apiVersion":"admission.k8s.io/v1","kind":"AdmissionReview","request":{"uid":"%s","object":{"metadata":{"name":"c"},"data":{"%s":"x"}}}}' "$1" "$2"; }
post() { curl -s -m 10 --cacert $W/ca.crt --resolve bend.test:24420:127.0.0.1 https://bend.test:24420/validate --data-binary @-; }
review u1 forbidden | post | grep -q '"uid":"u1","allowed":false' && pass "native: a verified client gets the review's answer" || fail "native: webhook answer"
if python3 -I -c "import socket; s = socket.socket(socket.AF_INET6); s.bind(('::1', 0))" 2>/dev/null; then
  review u6 plain | curl -s -m 10 --cacert $W/ca.crt --resolve "bend.test:24420:[::1]" https://bend.test:24420/validate --data-binary @- \
    | grep -q '"uid":"u6","allowed":true' && pass "native: the webhook answers on IPv6 too (dual-stack)" || fail "native: IPv6"
else
  echo "skip native: IPv6 (no ::1 here)"
fi
echo | "$OPENSSL" s_client -connect 127.0.0.1:24420 -tls1_1 >/dev/null 2>&1 && fail "native: webhook took TLS 1.1" || pass "native: webhook refuses TLS 1.1"
# renego PORT: s_client asks to renegotiate (R) over TLS 1.2, then GETs
renego() {
  { printf 'R\n'; sleep 1.5; printf 'GET / HTTP/1.0\r\n\r\n'; sleep 1; } \
    | "$OPENSSL" s_client -connect "127.0.0.1:$1" -tls1_2 -servername bend.test -CAfile $W/ca.crt 2>&1 || true
}
renego 24420 | grep -q "no renegotiation" && pass "native: webhook refuses renegotiation" || fail "native: webhook renegotiated"
[ "$(curl -s -m 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:24420/validate || true)" = 000 ] \
  && pass "native: plain HTTP on the webhook's port gets no answer" || fail "native: plain HTTP answered"
python3 -I -c "import socket; s = socket.create_connection(('127.0.0.1', 24420)); s.send(b'\x16\x03\x01\x00\xff'); s.close()"
ok=0; for i in $(seq 1 20); do (review "c$i" plain | post | grep -q "\"uid\":\"c$i\",\"allowed\":true" && touch "$work/wh-ok-$i") & done; wait_n=0
for _ in $(seq 1 100); do [ "$(ls "$work" | grep -c '^wh-ok-')" = 20 ] && break; sleep 0.1; done
[ "$(ls "$work" | grep -c '^wh-ok-')" = 20 ] && pass "native: 20 clients at once, each answered" || fail "native: concurrent: $(ls "$work" | grep -c '^wh-ok-')/20"
# The sanitized -O0 build is slow on a large body (the optimized one takes
# about a second for 2 MB), so this client waits longer.
python3 -I -c "import json; print(json.dumps({'apiVersion':'admission.k8s.io/v1','kind':'AdmissionReview','request':{'uid':'big','object':{'data':{'k':'x'*2000000}}}}))" \
  | curl -s -m 120 --cacert $W/ca.crt --resolve bend.test:24420:127.0.0.1 https://bend.test:24420/validate --data-binary @- \
  | grep -q '"uid":"big","allowed":true' && pass "native: a 2 MB review" || fail "native: big review"
# A client that handshakes, sends half a request and closes cleanly
# (close_notify) must cost nothing afterwards: no spinning read.
cpu() {  # the server's CPU time so far, in hundredths of a second
  if [ -r "/proc/$wh_pid/stat" ]; then awk '{ print $14 + $15 }' "/proc/$wh_pid/stat"  # clock ticks (100/s)
  else ps -o time= -p "$wh_pid" | awk -F'[:.]' '{ print ($1 * 60 + $2) * 100 + $3 }'; fi
}
python3 -I - "$W" <<'PY'
import socket, ssl, sys
w = sys.argv[1]
ctx = ssl.create_default_context(cafile=w + "/ca.crt")
ctx.verify_flags &= ~getattr(ssl, "VERIFY_X509_STRICT", 0)  # the test CA's leaves lack an AKI
for _ in range(5):
    s = ctx.wrap_socket(socket.create_connection(("127.0.0.1", 24420)), server_hostname="bend.test")
    s.sendall(b"POST /validate HTTP/1.1\r\nContent-Length: 100\r\n\r\n{")
    s = s.unwrap()
    s.close()
PY
sleep 1; c0=$(cpu); sleep 3; c1=$(cpu)
[ $((c1 - c0)) -lt 50 ] && review u2 plain | post | grep -q '"uid":"u2"' \
  && pass "native: a client that closes mid-request costs nothing after" || fail "native: early close: cpu +$((c1 - c0))cs"
python3 -I - "$W" > "$work/wh-big.txt" <<'PY'
import socket, ssl, sys
w = sys.argv[1]
ctx = ssl.create_default_context(cafile=w + "/ca.crt")
ctx.verify_flags &= ~getattr(ssl, "VERIFY_X509_STRICT", 0)  # the test CA's leaves lack an AKI
s = ctx.wrap_socket(socket.create_connection(("127.0.0.1", 24420), timeout=5), server_hostname="bend.test")
s.sendall(b"POST /validate HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n")
print(s.recv(200).decode(errors="replace"))
PY
grep -q "^HTTP/1.1 413" "$work/wh-big.txt" && pass "native: a Content-Length over the cap is refused before its body" || fail "native: declared size: $(head -1 "$work/wh-big.txt")"
kill "$wh_pid"; wait "$wh_pid" 2>/dev/null || true
if grep -E "ERROR: AddressSanitizer|runtime error" "$work/webhook.log" >/dev/null; then
  fail "native: webhook: sanitizer report"; grep -v WARNING "$work/webhook.log" | head -30
else
  pass "native: webhook server ran clean under -fsanitize=$SANITIZE"
fi
if [ "$(uname)" = Darwin ] && [ "$(env "${LIBRE[@]}" "$work/avail" "" "" 2>/dev/null | head -1)" = "1 ok" ]; then
  env "${LIBRE[@]}" WEBHOOK_PORT=24422 WEBHOOK_CERT=$W/server.crt WEBHOOK_KEY=$W/server.key "$work/webhook" > "$work/webhook-libre.log" 2>&1 &
  wl_pid=$!
  for _ in $(seq 1 50); do grep -q '"webhooks serving"' "$work/webhook-libre.log" && break; sleep 0.1; done
  review l1 forbidden | curl -s -m 10 --cacert $W/ca.crt --resolve bend.test:24422:127.0.0.1 https://bend.test:24422/validate --data-binary @- \
    | grep -q '"uid":"l1","allowed":false' && pass "native: LibreSSL: the webhook answers" || fail "native: LibreSSL: webhook answer"
  echo | "$OPENSSL" s_client -connect 127.0.0.1:24422 -tls1_1 >/dev/null 2>&1 && fail "native: LibreSSL: webhook took TLS 1.1" \
    || pass "native: LibreSSL: webhook refuses TLS 1.1"
  renego 24422 | grep -q "no renegotiation" && pass "native: LibreSSL: webhook refuses renegotiation" \
    || fail "native: LibreSSL: webhook renegotiated"
  kill "$wl_pid"; wait "$wl_pid" 2>/dev/null || true
  grep -E "ERROR: AddressSanitizer|runtime error" "$work/webhook-libre.log" >/dev/null \
    && fail "native: LibreSSL: webhook: sanitizer report" || pass "native: LibreSSL: webhook ran clean"
fi
echo "== js: TLS server"
WEBHOOK_PORT=24421 WEBHOOK_CERT=$W/server.crt WEBHOOK_KEY=$W/server.key bend examples/webhook.bend > "$work/webhook-js.log" 2>&1 &
for _ in $(seq 1 100); do grep -q '"webhooks serving"' "$work/webhook-js.log" && break; sleep 0.1; done
review j plain | curl -s -m 5 --cacert $W/ca.crt --resolve bend.test:24421:127.0.0.1 https://bend.test:24421/validate --data-binary @- >/dev/null || true
for _ in $(seq 1 30); do grep -q 'serving TLS needs the native lane' "$work/webhook-js.log" && break; sleep 0.1; done
grep -q 'serving TLS needs the native lane' "$work/webhook-js.log" && pass "js: serving TLS says it needs the native lane" || fail "js: $(tail -3 "$work/webhook-js.log")"

echo
[ $fails = 0 ] && echo "all TLS tests pass" || { echo "$fails TLS tests failed"; exit 1; }
