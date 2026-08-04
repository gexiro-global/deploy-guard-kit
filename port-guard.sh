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
# Outcomes:
#   GUARD-OK            at least one source positively confirms this port belongs to <app-name>
#   GUARD-INCONCLUSIVE  no conflict was found, but nothing confirmed ownership either
#   GUARD-FAIL          something else owns or consumes this port
#
# The distinction matters: "I found no conflict" and "this port is yours" are different claims,
# and a guard that reports the first as the second is a guard you should not trust.
#
# Exit: 0 confirmed | 1 inconclusive | 2 collision | 3 another deploy holds the lock
set -uo pipefail

APP="${1:?usage: port-guard.sh <app-name> <port> <allowed-owner-regex>}"
PORT="${2:?missing port}"
ALLOW="${3:?missing allowed-owner-regex}"

case "$PORT" in
  ''|*[!0-9]*) echo "GUARD-FAIL: port must be a number, got '$PORT'"; exit 2 ;;
esac
if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
  echo "GUARD-FAIL: port out of range: $PORT"; exit 2
fi
# ALLOW is used as an extended regex. grep exits 2 on an invalid pattern; without this check an
# unparseable regex would make every match fail, which reads as "no foreign consumers found".
if echo x | grep -qE "$ALLOW" 2>/dev/null; then :; elif [ $? -gt 1 ]; then
  echo "GUARD-FAIL: allowed-owner-regex is not a valid extended regex: $ALLOW"; exit 2
fi

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

# Positive evidence that the port belongs to this app, as opposed to merely an absence of
# evidence that it belongs to someone else.
CONFIRMED=""
confirm(){ CONFIRMED="${CONFIRMED}${CONFIRMED:+, }$1"; }

# 1) STATIC - reverse proxy: does a foreign vhost already point at this port?
# An adapter that cannot read its config tree must not look like "no consumers found" - that
# would turn an unreadable proxy configuration into a GUARD-OK.
if [ "$ADAPTER" != "none" ]; then
  adapter_dir="${OLS_VHOST_DIR:-${NGINX_CONF_DIR:-}}"
  case "$ADAPTER" in
    openlitespeed) adapter_dir="${OLS_VHOST_DIR:-/usr/local/lsws/conf/vhosts}" ;;
    nginx)         adapter_dir="${NGINX_CONF_DIR:-/etc/nginx}" ;;
  esac
  [ -d "$adapter_dir" ] || fail "adapter '$ADAPTER' cannot read its config directory: $adapter_dir"
  [ -r "$adapter_dir" ] || fail "adapter '$ADAPTER' cannot read its config directory: $adapter_dir"
fi
if foreign=$(adapter_consumers "$PORT" 2>/dev/null | grep -viE "$ALLOW" || true); [ -n "${foreign:-}" ]; then
  fail "port $PORT is consumed by foreign proxy config(s): $(printf '%s' "$foreign" | tr '\n' ' ') (allowed: $ALLOW)"
fi
if [ "$ADAPTER" != "none" ]; then
  mine=$(adapter_consumers "$PORT" 2>/dev/null | grep -iE "$ALLOW" || true)
  [ -n "${mine:-}" ] && confirm "proxy config"
fi

# 2) STATIC - process manager: is the port hardcoded in someone else's config?
if [ -n "$ECOSYSTEM" ]; then
  # A path that was configured but cannot be read is not the same as one with no match in it.
  for _e in $ECOSYSTEM; do
    if [ -e "$_e" ] && [ ! -r "$_e" ]; then
      fail "process-manager config $_e exists but cannot be read"
    fi
  done
  # shellcheck disable=SC2086
  bad_eco=$(grep -rlE "PORT[^0-9]{0,10}${PORT}([^0-9]|$)" $ECOSYSTEM 2>/dev/null | grep -viE "$ALLOW" || true)
  [ -n "$bad_eco" ] && fail "port $PORT is statically reserved in another app's config: $(printf '%s' "$bad_eco" | tr '\n' ' ')"
fi

# 3) REGISTRY - declared owner must be this app, UNKNOWN, or absent
if [ -e "$REGISTRY" ] && [ ! -r "$REGISTRY" ]; then
  fail "registry $REGISTRY exists but cannot be read - refusing to treat that as 'no entry'"
fi
if [ -f "$REGISTRY" ]; then
  # Tolerate ordinary YAML variation - an unquoted key, a quoted value, a different indent,
  # an inline comment - while still requiring the port to be a TOP-LEVEL key. Matching a
  # nested key of the same name would let unrelated metadata decide who owns a port.
  owner=$(awk -v port="$PORT" '
    {
      line = $0
      sub(/\r$/, "", line)   # a registry saved with CRLF must still parse
      sub(/[ \t]+$/, "", line)
      if (line ~ /^[ \t]/) {
        if (f && line ~ /^[ \t]+app:[ \t]*/) {
          sub(/^[ \t]+app:[ \t]*/, "", line)
          sub(/[ \t]+#.*$/, "", line)
          gsub(/["'"'"']/, "", line)
          sub(/[ \t]+$/, "", line)
          print line
          exit
        }
        next
      }
      # a new top-level key ends the previous block
      if (f) exit
      key = line
      sub(/:.*$/, "", key)
      gsub(/["'"'"' \t]/, "", key)
      if (key == port && line ~ /:[ \t]*(#.*)?$/) f = 1
    }' "$REGISTRY" 2>/dev/null)
  if [ -n "${owner:-}" ] && [ "$owner" != "$APP" ] && [ "$owner" != "UNKNOWN" ]; then
    fail "registry says port $PORT belongs to '$owner', not '$APP'"
  fi
  [ "${owner:-}" = "$APP" ] && confirm "registry"
fi

# 4) RUNTIME - if something is listening, its working directory must match
# Every listener on this port, not just the first: a process bound to one specific address can
# sit alongside another, and checking only the first hides the second.
listeners=$(ss -lntpH 2>/dev/null | awk -v p=":$PORT" '
  { split($4, a, "%"); addr = a[1]
    n = length(addr) - length(p)
    if (n > 0 && substr(addr, n + 1) == p) print $0 }' | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)

if [ -n "${listeners:-}" ]; then
  for lpid in $listeners; do
    lcwd=$(readlink "/proc/$lpid/cwd" 2>/dev/null || echo '')
    echo "$lcwd" | grep -qiE "$ALLOW" \
      || fail "port $PORT is bound by PID $lpid (cwd=$lcwd), which does not match /$ALLOW/"
  done
  confirm "running process"
fi

if [ -n "$CONFIRMED" ]; then
  echo "GUARD-OK: port $PORT is confirmed for '$APP' by: $CONFIRMED (no foreign consumers or reservations)"
  exit 0
fi

# Nothing claimed the port - but nothing confirmed it is yours either. Saying "reserved for you"
# here would be inventing a fact. Callers that want a hard gate should treat exit 1 as a stop.
echo "GUARD-INCONCLUSIVE: no conflict found for port $PORT, but nothing confirms it belongs to '$APP'."
echo "  Add it to the registry, wire a proxy consumer, or start the process - then re-run."
exit 1
