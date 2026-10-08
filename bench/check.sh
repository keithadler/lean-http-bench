#!/usr/bin/env bash
# Check that a server answers the three endpoints correctly: bodies, status codes and framing.
#   bench/check.sh 127.0.0.1:8080
set -euo pipefail
A=$1
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "  ok    $1"; }
bad() { echo "  FAIL  $1"; fail=1; }
[ "$(curl -s "http://$A/plaintext")" = "Hello, World!" ] && ok "GET /plaintext" || bad "GET /plaintext"
for n in 0 1 4096 100000; do
  if [ $n -eq 0 ]; then : > "$T/in"; else head -c $n /dev/urandom > "$T/in"; fi
  curl -s --data-binary @"$T/in" "http://$A/echo" > "$T/out"
  cmp -s "$T/in" "$T/out" && ok "POST /echo, $n bytes" || bad "POST /echo, $n bytes"
done
python3 -c 'import sys; sys.stdout.buffer.write(bytes(i % 251 for i in range(256*1024)))' > "$T/big"
curl -s "http://$A/big" > "$T/got"; cmp -s "$T/big" "$T/got" && ok "GET /big, 256 KiB" || bad "GET /big"
[ "$(curl -s -o /dev/null -w '%{http_code}' "http://$A/nope")" = 404 ] && ok "unknown path is 404" || bad "unknown path"
# Many requests on one keep-alive connection, as the benchmark sends them.
n=$(curl -s $(for i in $(seq 1 300); do printf "http://$A/plaintext "; done) | grep -o "Hello, World!" | wc -l | tr -d ' ')
[ "$n" = 300 ] && ok "300 requests in a row" || bad "300 requests in a row ($n)"
exit $fail
