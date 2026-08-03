#!/bin/bash
# marker-healthcheck - check that a backend serves YOUR site, not just any response.
#
# An open port proves a process is listening. A 200 proves something answered. Neither
# proves the vhost is still wired to the right application - the classic symptom being
# one of your domains quietly serving a different site after a config change.
#
# This checks for a string that only your application would emit.
#
# Usage: marker-healthcheck.sh [checks.conf]
#
# Config format, one check per line, pipe-separated, '#' comments allowed:
#   port|Host header|expected marker (regex)
#
# Exit: 0 all markers found | 2 at least one mismatch
set -uo pipefail

CONF="${1:-${HC_CONF:-./checks.conf}}"
TIMEOUT="${HC_TIMEOUT:-8}"
TARGET="${HC_TARGET:-127.0.0.1}"
[ -f "$CONF" ] || { echo "config not found: $CONF"; exit 2; }

FAIL=0
CHECKED=0
while IFS='|' read -r port host want; do
  case "${port// /}" in ''|\#*) continue ;; esac
  port=$(echo "$port" | tr -d ' '); host=$(echo "$host" | tr -d ' ')
  want=$(echo "$want" | sed 's/^ *//; s/ *$//')

  # An empty marker becomes an empty regex, which grep matches in every response - a malformed
  # config line would silently report every backend as healthy.
  if [ -z "$want" ]; then
    echo "  ALERT :$port ($host) no expected marker configured - refusing to pass this check"
    FAIL=1
    continue
  fi

  CHECKED=$((CHECKED+1))
  # No -L: a redirect to some other host means this backend did not serve the marker, and
  # following it would let an unrelated page satisfy the check. Capture the status separately so
  # a marker found inside a 500 error page cannot pass as healthy.
  resp=$(curl -s --max-time "$TIMEOUT" -H "Host: $host" -w '\n%{http_code}' \
         "http://${TARGET}:${port}/" 2>/dev/null || true)
  code=$(printf '%s' "$resp" | tail -n1)
  body=$(printf '%s' "$resp" | sed '$d')
  title=$(printf '%s' "$body" | grep -oiE '<title>[^<]{0,60}' | head -1 | sed 's/<title>//I')

  case "$code" in
    2*) ;;
    '')  echo "  ALERT :$port ($host) no response"; FAIL=1; continue ;;
    3*)  echo "  ALERT :$port ($host) redirected ($code) - the backend did not serve this itself"; FAIL=1; continue ;;
    *)   echo "  ALERT :$port ($host) HTTP $code"; FAIL=1; continue ;;
  esac

  if printf '%s' "$body" | grep -qiE "$want"; then
    echo "  OK    :$port ($host) -> ${title:-no-title}"
  else
    echo "  ALERT :$port ($host) expected /$want/, got '${title:-no-title}'"
    FAIL=1
  fi
done < "$CONF"

if [ "$CHECKED" -eq 0 ]; then
  # An empty or comment-only config used to report PASS - a healthcheck that checked nothing and
  # called it healthy, which is the most dangerous answer this script could give.
  echo "HEALTHCHECK: NO CHECKS - $CONF defines nothing to verify" >&2
  exit 2
fi
if [ "$FAIL" = "0" ]; then
  echo "HEALTHCHECK: PASS ($CHECKED check(s))"
  exit 0
fi
echo 'HEALTHCHECK: FAIL'
exit 2
