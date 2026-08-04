#!/bin/bash
# Offline test suite. No network, no pm2, no firewall, no privileged access.
# shellcheck disable=SC2015,SC2016,SC2181
# SC2015: the `[ cond ] && ok "..." || no "..."` shape is intentional here - `ok` cannot fail,
#         so this is a two-branch report, not a mis-written if-then-else.
# SC2016: single quotes are deliberate where a literal `$` belongs to awk, python or a stub.
# SC2181: these suites check `$?` immediately after the command under test, which is the
#         thing being asserted.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
PASS=0; FAIL=0
ok(){ echo "  ok   - $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL - $1"; FAIL=$((FAIL+1)); }
REG="$ROOT/examples/port-registry.example.yaml"

# A stub `ss` reporting no listeners. Without it these cases would be INCONCLUSIVE on any machine
# lacking iproute2 - correct behaviour, but not what they mean to test.
SSDIR=$(mktemp -d)
printf '%s\n' '#!/bin/bash' 'exit 0' > "$SSDIR/ss"
chmod +x "$SSDIR/ss"
PATH="$SSDIR:$PATH"
export PATH

echo '== port-guard =='
GUARD_LOCK=$(mktemp); export GUARD_LOCK

GUARD_REGISTRY="$REG" "$ROOT/port-guard.sh" example-web 3000 'example-web' >/dev/null 2>&1 \
  && ok 'accepts the declared owner of a port' || no 'accepts the declared owner of a port'

GUARD_REGISTRY="$REG" "$ROOT/port-guard.sh" example-api 3000 'example-api' >/dev/null 2>&1
[ $? -eq 2 ] && ok 'rejects an app claiming a port owned by another' || no 'rejects an app claiming a port owned by another'

GUARD_REGISTRY="$REG" "$ROOT/port-guard.sh" anything 3002 'anything' >/dev/null 2>&1
[ $? -eq 1 ] && ok 'UNKNOWN owner is inconclusive: not a collision, not a confirmation' \
             || no 'UNKNOWN owner is inconclusive: not a collision, not a confirmation'

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
  'for a in "$@"; do case "$a" in *:3000/*) echo "<html><title>Example Widgets Ltd</title>ok</html>"; echo 200; exit 0;; esac; done' \
  'echo "<html><title>Welcome to nginx!</title></html>"' 'echo 200' > "$STUB/curl"
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
printf '%s\n' '#!/bin/bash' 'echo "<html><title>anything</title></html>"' 'echo 200' > "$STUB2/curl"
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
[ $? -eq 1 ] && ok 'ignores a nested key that merely looks like a registry entry' \
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
[ $? -eq 1 ] && ok 'does not treat port 300 as a match for 3000' \
             || no 'does not treat port 300 as a match for 3000'

# A top-level key with no block must not absorb the next entry's owner.
printf '"3000":\n"3001":\n  app: next-one\n' > "$CRLF/empty.yaml"
GUARD_LOCK="$CRLF/l3" GUARD_REGISTRY="$CRLF/empty.yaml" \
  "$ROOT/port-guard.sh" anyapp 3000 'anyapp' >/dev/null 2>&1
[ $? -eq 1 ] && ok 'an empty registry block does not borrow the next owner' \
             || no 'an empty registry block does not borrow the next owner'
rm -rf "$CRLF"

# "No conflict found" and "this port is yours" are different claims. With no registry, no
# adapter and nothing listening, the guard knows nothing - and must say so rather than approve.
EVID=$(mktemp -d)
GUARD_LOCK="$EVID/l1" GUARD_REGISTRY="$EVID/absent.yaml" \
  "$ROOT/port-guard.sh" myapp 9999 'myapp' >/dev/null 2>&1
[ $? -eq 1 ] && ok 'reports INCONCLUSIVE when nothing confirms ownership' \
             || no 'reports INCONCLUSIVE when nothing confirms ownership'

OUT=$(GUARD_LOCK="$EVID/l2" GUARD_REGISTRY="$EVID/absent.yaml" \
      "$ROOT/port-guard.sh" myapp 9999 'myapp' 2>&1)
printf '%s' "$OUT" | grep -q 'GUARD-INCONCLUSIVE' \
  && ok 'the inconclusive verdict is named, not disguised as success' \
  || no 'the inconclusive verdict is named, not disguised as success'
printf '%s' "$OUT" | grep -q 'is reserved for' \
  && no 'never claims a reservation it did not establish' \
  || ok 'never claims a reservation it did not establish'

# A registry entry naming this app IS positive evidence.
GUARD_LOCK="$EVID/l3" GUARD_REGISTRY="$ROOT/examples/port-registry.example.yaml" \
  "$ROOT/port-guard.sh" example-web 3000 'example-web' >/dev/null 2>&1
[ $? -eq 0 ] && ok 'a matching registry entry confirms ownership' \
             || no 'a matching registry entry confirms ownership'
rm -rf "$EVID"

# A healthcheck that checks nothing must not report health.
HC=$(mktemp -d)
: > "$HC/empty.conf"
"$ROOT/marker-healthcheck.sh" "$HC/empty.conf" >/dev/null 2>&1
[ $? -eq 2 ] && ok 'an empty checks file fails instead of passing' \
             || no 'an empty checks file fails instead of passing'

# A marker found inside an error page is not health.
printf '%s\n' '#!/bin/bash' 'echo "<html><title>Example Widgets Ltd</title></html>"' 'echo 500' > "$HC/curl"
chmod +x "$HC/curl"
printf '3000 | www.example.com | Example Widgets Ltd\n' > "$HC/c.conf"
OUT=$(PATH="$HC:$PATH" "$ROOT/marker-healthcheck.sh" "$HC/c.conf" 2>&1)
RC=$?
if [ "$RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'HTTP 500'; then
  ok 'a marker inside a 500 page does not count as healthy'
else
  no 'a marker inside a 500 page does not count as healthy'
fi
rm -rf "$HC"

# --- inputs are validated before they drive any decision ------------------------------------
VAL=$(mktemp -d)
printf '"3000":\n  app: example-web\n' > "$VAL/reg.yaml"

GUARD_LOCK="$VAL/l1" GUARD_REGISTRY="$VAL/reg.yaml" \
  "$ROOT/port-guard.sh" app abc 'app' >/dev/null 2>&1
[ $? -eq 2 ] && ok 'rejects a non-numeric port' || no 'rejects a non-numeric port'

GUARD_LOCK="$VAL/l2" GUARD_REGISTRY="$VAL/reg.yaml" \
  "$ROOT/port-guard.sh" app 99999 'app' >/dev/null 2>&1
[ $? -eq 2 ] && ok 'rejects a port outside 1-65535' || no 'rejects a port outside 1-65535'

# An unparseable regex makes every grep fail, which would read as "no foreign consumers".
OUT=$(GUARD_LOCK="$VAL/l3" GUARD_REGISTRY="$VAL/reg.yaml" \
      "$ROOT/port-guard.sh" app 3000 'a[' 2>&1)
printf '%s' "$OUT" | grep -q 'not a valid extended regex' \
  && ok 'rejects an invalid allowed-owner-regex' || no 'rejects an invalid allowed-owner-regex'

# A configured registry that cannot be read must not be treated as "no entry". Root ignores file
# modes, so this one only means anything when run unprivileged.
if command -v setpriv >/dev/null 2>&1 && [ "$(id -u)" = 0 ]; then
  chmod 755 "$VAL"
  cp "$ROOT/port-guard.sh" "$VAL/pg.sh"
  mkdir -p "$VAL/adapters"; cp "$ROOT"/adapters/*.sh "$VAL/adapters/"
  chmod -R a+rx "$VAL/pg.sh" "$VAL/adapters"
  chmod 000 "$VAL/reg.yaml"
  touch "$VAL/lock"; chmod 666 "$VAL/lock"
  OUT=$(setpriv --reuid=65534 --regid=65534 --clear-groups \
        env GUARD_LOCK="$VAL/lock" GUARD_REGISTRY="$VAL/reg.yaml" \
        "$VAL/pg.sh" app 3000 'app' 2>&1)
  printf '%s' "$OUT" | grep -q 'cannot be read' \
    && ok 'an unreadable registry fails instead of reading as empty' \
    || no 'an unreadable registry fails instead of reading as empty'
  chmod 644 "$VAL/reg.yaml"
else
  ok 'unreadable-registry check skipped (needs root + setpriv to drop privileges)'
fi
rm -rf "$VAL"

# --- runtime evidence must be real evidence -------------------------------------------------
# A socket nobody can attribute is not "no listener": it is a port demonstrably in use by an
# unidentifiable process, which must never be reported as confirmed.
RT=$(mktemp -d); mkdir -p "$RT/bin"
printf '%s\n' '#!/bin/bash' 'echo "LISTEN 0 511 0.0.0.0:3000 0.0.0.0:*"' > "$RT/bin/ss"
chmod +x "$RT/bin/ss"
OUT=$(PATH="$RT/bin:$PATH" GUARD_LOCK="$RT/l1" GUARD_REGISTRY="$REG" \
      "$ROOT/port-guard.sh" example-web 3000 'example-web' 2>&1)
RT_RC=$?
if [ "$RT_RC" -eq 2 ] && printf '%s' "$OUT" | grep -q 'no owning process could be identified'; then
  ok 'a socket with no attributable process fails instead of confirming'
else
  no "a socket with no attributable process fails instead of confirming (rc=$RT_RC)"
fi

# ss missing entirely: the other checks may still confirm, but the verdict cannot be a confident
# OK when nothing observed the socket.
printf '%s\n' '#!/bin/bash' 'exit 1' > "$RT/bin/ss"
chmod +x "$RT/bin/ss"
OUT=$(PATH="$RT/bin:$PATH" GUARD_LOCK="$RT/l2" GUARD_REGISTRY="$REG" \
      "$ROOT/port-guard.sh" example-web 3000 'example-web' 2>&1)
RT_RC=$?
if [ "$RT_RC" -eq 1 ] && printf '%s' "$OUT" | grep -q 'GUARD-INCONCLUSIVE'; then
  ok 'a failing ss downgrades the verdict rather than being ignored'
else
  no "a failing ss downgrades the verdict rather than being ignored (rc=$RT_RC)"
fi
rm -rf "$RT"

echo
echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]




