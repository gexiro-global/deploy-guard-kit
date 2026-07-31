#!/bin/bash
# Offline test suite. No network, no pm2, no firewall, no privileged access.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
PASS=0; FAIL=0
ok(){ echo "  ok   - $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL - $1"; FAIL=$((FAIL+1)); }
REG="$ROOT/examples/port-registry.example.yaml"

echo '== port-guard =='
GUARD_LOCK=$(mktemp); export GUARD_LOCK

GUARD_REGISTRY="$REG" "$ROOT/port-guard.sh" example-web 3000 'example-web' >/dev/null 2>&1 \
  && ok 'accepts the declared owner of a port' || no 'accepts the declared owner of a port'

GUARD_REGISTRY="$REG" "$ROOT/port-guard.sh" example-api 3000 'example-api' >/dev/null 2>&1
[ $? -eq 2 ] && ok 'rejects an app claiming a port owned by another' || no 'rejects an app claiming a port owned by another'

GUARD_REGISTRY="$REG" "$ROOT/port-guard.sh" anything 3002 'anything' >/dev/null 2>&1 \
  && ok 'UNKNOWN owner never blocks a deploy' || no 'UNKNOWN owner never blocks a deploy'

RC_FILE=$(mktemp)
( flock -n 9 || exit 1
  GUARD_REGISTRY="$REG" "$ROOT/port-guard.sh" example-web 3000 'example-web' >/dev/null 2>&1
  echo $? > "$RC_FILE" ) 9>"$GUARD_LOCK"
[ "$(cat "$RC_FILE" 2>/dev/null)" = "3" ] \
  && ok 'refuses to run while another deploy holds the lock' \
  || no 'refuses to run while another deploy holds the lock'
rm -f "$GUARD_LOCK" "$RC_FILE"

echo '== pm2-inventory =='
INV="$ROOT/examples/pm2-inventory.example.yaml"

PM2_JLIST_FILE="$HERE/fixtures/pm2-jlist-ok.json" "$ROOT/pm2-inventory.sh" "$INV" >/dev/null 2>&1 \
  && ok 'passes when every app runs from its declared cwd' || no 'passes when every app runs from its declared cwd'

OUT=$(PM2_JLIST_FILE="$HERE/fixtures/pm2-jlist-wrong-cwd.json" "$ROOT/pm2-inventory.sh" "$INV" 2>&1)
RC=$?
if [ $RC -ne 0 ] && printf '%s' "$OUT" | grep -q 'WRONG CWD'; then
  ok 'detects right-name/wrong-cwd drift'
else
  no 'detects right-name/wrong-cwd drift'
fi

echo '== marker-healthcheck =='
STUB=$(mktemp -d)
printf '%s\n' '#!/bin/bash' \
  'for a in "$@"; do case "$a" in *:3000/*) echo "<html><title>Example Widgets Ltd</title>ok</html>"; exit 0;; esac; done' \
  'echo "<html><title>Welcome to nginx!</title></html>"' > "$STUB/curl"
chmod +x "$STUB/curl"
printf '3000 | www.example.com | Example Widgets Ltd\n' > "$STUB/checks.conf"
printf '3009 | www.example.com | Example Widgets Ltd\n' > "$STUB/checks-bad.conf"

PATH="$STUB:$PATH" "$ROOT/marker-healthcheck.sh" "$STUB/checks.conf" >/dev/null 2>&1 \
  && ok 'passes when the expected marker is present' || no 'passes when the expected marker is present'

OUT=$(PATH="$STUB:$PATH" "$ROOT/marker-healthcheck.sh" "$STUB/checks-bad.conf" 2>&1)
RC=$?
if [ $RC -ne 0 ] && printf '%s' "$OUT" | grep -q 'ALERT'; then
  ok 'alerts when a foreign site is served on the port'
else
  no 'alerts when a foreign site is served on the port'
fi
rm -rf "$STUB"

echo '== regressions =='
# The adapter name is sourced as shell code, so a traversal value must be refused outright.
GUARD_ADAPTER='../../etc/passwd' GUARD_REGISTRY="$REG" \
  "$ROOT/port-guard.sh" example-web 3000 'example-web' >/dev/null 2>&1
[ $? -eq 2 ] && ok 'refuses an adapter name outside the allowlist' \
             || no 'refuses an adapter name outside the allowlist'

# An empty marker would make grep match every response and pass any backend.
STUB2=$(mktemp -d)
printf '%s\n' '#!/bin/bash' 'echo "<html><title>anything</title></html>"' > "$STUB2/curl"
chmod +x "$STUB2/curl"
printf '3000 | www.example.com |\n' > "$STUB2/empty.conf"
OUT=$(PATH="$STUB2:$PATH" "$ROOT/marker-healthcheck.sh" "$STUB2/empty.conf" 2>&1)
RC=$?
if [ $RC -ne 0 ] && printf '%s' "$OUT" | grep -q 'no expected marker'; then
  ok 'refuses a check line with an empty marker'
else
  no 'refuses a check line with an empty marker'
fi
rm -rf "$STUB2"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
