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

# The registry is hand-written YAML, so ordinary formatting variation must not silently
# disable ownership enforcement. Requiring a byte-exact quoted key and exactly two spaces
# meant a reformatted registry stopped protecting anything.
REGVAR=$(mktemp -d)
printf '3000:\n    app: "example-web"\n    cwd: /srv/x\n' > "$REGVAR/unquoted.yaml"
GUARD_LOCK="$REGVAR/l1" GUARD_REGISTRY="$REGVAR/unquoted.yaml" \
  "$ROOT/port-guard.sh" other-app 3000 'other-app' >/dev/null 2>&1
[ $? -eq 2 ] && ok 'reads an unquoted key with a four-space indent' \
             || no 'reads an unquoted key with a four-space indent'

GUARD_LOCK="$REGVAR/l2" GUARD_REGISTRY="$REGVAR/unquoted.yaml" \
  "$ROOT/port-guard.sh" example-web 3000 'example-web' >/dev/null 2>&1
[ $? -eq 0 ] && ok 'still lets the declared owner through' \
             || no 'still lets the declared owner through'

# An adapter that cannot read its config tree must fail, not report "no consumers found".
GUARD_LOCK="$REGVAR/l3" GUARD_ADAPTER=nginx NGINX_CONF_DIR="$REGVAR/does-not-exist" \
  GUARD_REGISTRY="$REG" "$ROOT/port-guard.sh" example-web 3000 'example-web' >/dev/null 2>&1
[ $? -eq 2 ] && ok 'fails when the adapter cannot read its config directory' \
             || no 'fails when the adapter cannot read its config directory'
rm -rf "$REGVAR"

# The registry parser must key off TOP-LEVEL entries only. A nested key with the same name is
# unrelated metadata; treating it as the registry entry lets the wrong thing decide ownership.
PARSE=$(mktemp -d)
printf 'services:\n  3000:\n    app: not-the-registry\n' > "$PARSE/nested.yaml"
GUARD_LOCK="$PARSE/n1" GUARD_REGISTRY="$PARSE/nested.yaml" \
  "$ROOT/port-guard.sh" anyapp 3000 'anyapp' >/dev/null 2>&1
[ $? -eq 0 ] && ok 'ignores a nested key that merely looks like a registry entry' \
             || no 'ignores a nested key that merely looks like a registry entry'

# An inline YAML comment is not part of the value.
printf '\"3000\":\n  app: example-web # the owner\n' > "$PARSE/comment.yaml"
GUARD_LOCK="$PARSE/n2" GUARD_REGISTRY="$PARSE/comment.yaml" \
  "$ROOT/port-guard.sh" example-web 3000 'example-web' >/dev/null 2>&1
[ $? -eq 0 ] && ok 'strips an inline comment from the owner value' \
             || no 'strips an inline comment from the owner value'
GUARD_LOCK="$PARSE/n3" GUARD_REGISTRY="$PARSE/comment.yaml" \
  "$ROOT/port-guard.sh" other-app 3000 'other-app' >/dev/null 2>&1
[ $? -eq 2 ] && ok 'still rejects a foreign app when the value had a comment' \
             || no 'still rejects a foreign app when the value had a comment'
rm -rf "$PARSE"

# A registry saved on Windows must still parse. CRLF left a stray carriage return on the key,
# so it never matched and ownership enforcement silently switched itself off.
CRLF=$(mktemp -d)
printf '"3000":\r\n  app: crlf-owner\r\n' > "$CRLF/reg.yaml"
GUARD_LOCK="$CRLF/l1" GUARD_REGISTRY="$CRLF/reg.yaml" \
  "$ROOT/port-guard.sh" other-app 3000 'other-app' >/dev/null 2>&1
[ $? -eq 2 ] && ok 'parses a registry with CRLF line endings' \
             || no 'parses a registry with CRLF line endings'

# A shorter port must not match a longer one, in either direction.
printf '"300":\n  app: small-app\n' > "$CRLF/prefix.yaml"
GUARD_LOCK="$CRLF/l2" GUARD_REGISTRY="$CRLF/prefix.yaml" \
  "$ROOT/port-guard.sh" myapp 3000 'myapp' >/dev/null 2>&1
[ $? -eq 0 ] && ok 'does not treat port 300 as a match for 3000' \
             || no 'does not treat port 300 as a match for 3000'

# A top-level key with no block must not absorb the next entry's owner.
printf '"3000":\n"3001":\n  app: next-one\n' > "$CRLF/empty.yaml"
GUARD_LOCK="$CRLF/l3" GUARD_REGISTRY="$CRLF/empty.yaml" \
  "$ROOT/port-guard.sh" anyapp 3000 'anyapp' >/dev/null 2>&1
[ $? -eq 0 ] && ok 'an empty registry block does not borrow the next owner' \
             || no 'an empty registry block does not borrow the next owner'
rm -rf "$CRLF"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]



