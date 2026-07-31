#!/bin/bash
# port-guard - refuse to deploy onto a port that belongs to something else.
#
# The check most deploy scripts do is "is the port free right now?". That misses the
# case this tool exists for: the rightful owner of the port is DOWN, the port looks
# free, your app binds it, and now two services fight over it on the next restart.
#
# port-guard answers a different question: "is this port RESERVED for me?" It looks at
# static reservations (reverse-proxy configs, process-manager configs, a declared
# registry) as well as the live socket, and it holds a lock so two deploys cannot race.
#
# Usage: port-guard.sh <app-name> <port> <allowed-owner-regex>
#
# Environment:
#   GUARD_ADAPTER    openlitespeed | nginx | none   (default: none)
#   GUARD_REGISTRY   path to port registry YAML     (default: ./port-registry.yaml)
#   GUARD_LOCK       lock file                      (default: /tmp/deploy-guard.lock)
#   GUARD_ECOSYSTEM  glob(s) of process-manager configs to scan for static PORT= entries
#
# Exit: 0 reserved for you | 2 collision | 3 another deploy holds the lock
set -uo pipefail

APP="${1:?usage: port-guard.sh <app-name> <port> <allowed-owner-regex>}"
PORT="${2:?missing port}"
ALLOW="${3:?missing allowed-owner-regex}"

ADAPTER="${GUARD_ADAPTER:-none}"
REGISTRY="${GUARD_REGISTRY:-./port-registry.yaml}"
LOCK="${GUARD_LOCK:-/tmp/deploy-guard.lock}"
ECOSYSTEM="${GUARD_ECOSYSTEM:-}"
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# The adapter name is used to build a path that gets sourced as shell code, so it is matched
# against a fixed list rather than sanitised - otherwise GUARD_ADAPTER=../../anything becomes
# arbitrary code execution.
case "$ADAPTER" in
  openlitespeed|nginx|none) ;;
  *) echo "GUARD-FAIL: unknown adapter '$ADAPTER' (expected: openlitespeed, nginx, none)"; exit 2 ;;
esac
# shellcheck source=/dev/null
. "$HERE/adapters/${ADAPTER}.sh" || { echo "GUARD-FAIL: cannot load adapter '$ADAPTER'"; exit 2; }

exec 9>"$LOCK" || { echo "GUARD-FAIL: cannot open lock $LOCK"; exit 3; }
flock -n 9 || { echo "GUARD-FAIL: another deploy holds the lock ($LOCK)"; exit 3; }

fail(){ echo "GUARD-FAIL: $*"; exit 2; }

# 1) STATIC - reverse proxy: does a foreign vhost already point at this port?
if foreign=$(adapter_consumers "$PORT" 2>/dev/null | grep -viE "$ALLOW" || true); [ -n "${foreign:-}" ]; then
  fail "port $PORT is consumed by foreign proxy config(s): $(echo $foreign) (allowed: $ALLOW)"
fi

# 2) STATIC - process manager: is the port hardcoded in someone else's config?
if [ -n "$ECOSYSTEM" ]; then
  # shellcheck disable=SC2086
  bad_eco=$(grep -rlE "PORT[^0-9]{0,10}${PORT}([^0-9]|$)" $ECOSYSTEM 2>/dev/null | grep -viE "$ALLOW" || true)
  [ -n "$bad_eco" ] && fail "port $PORT is statically reserved in another app's config: $(echo $bad_eco)"
fi

# 3) REGISTRY - declared owner must be this app, UNKNOWN, or absent
if [ -f "$REGISTRY" ]; then
  owner=$(awk -v k="\"$PORT\":" '$0==k{f=1;next} f&&/^  app:/{print $2; exit}' "$REGISTRY" 2>/dev/null)
  if [ -n "${owner:-}" ] && [ "$owner" != "$APP" ] && [ "$owner" != "UNKNOWN" ]; then
    fail "registry says port $PORT belongs to '$owner', not '$APP'"
  fi
fi

# 4) RUNTIME - if something is listening, its working directory must match
pid=$(ss -lntpH 2>/dev/null \
  | grep -E "(127\.0\.0\.1|0\.0\.0\.0|\*|\[::\]):${PORT} " \
  | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2 || true)
if [ -n "${pid:-}" ]; then
  cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null || echo '')
  echo "$cwd" | grep -qiE "$ALLOW" || fail "port $PORT is bound by PID $pid (cwd=$cwd), which does not match /$ALLOW/"
fi

echo "GUARD-OK: port $PORT is reserved for '$APP' (allow=/$ALLOW/); no foreign consumers or reservations"
exit 0
