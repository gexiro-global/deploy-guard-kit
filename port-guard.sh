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
#   GUARD_LOCK_DIR   lock directory (flock'd, opened read-only, never truncated)
#                    (default: /run/lock/deploy-guard as root). Must be a non-symlink
#                    directory you own.
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

# A pattern that matches everything - '.*', '.', '^' - turns the guard off without saying so:
# every foreign proxy consumer is filtered out as "ours", and any process working directory
# confirms ownership. A genuine owner pattern never matches an unrelated random string.
if [ "${GUARD_ALLOW_BROAD:-0}" != "1" ]; then
  # A legitimate owner pattern identifies ONE app; it must not match unrelated
  # strings. A FIXED probe set is always defeatable by a pattern crafted around it
  # (e.g. '^/[^ez]' dodges fixed canaries yet matches every real process cwd), so
  # generate RANDOM canaries each run - as bare tokens and as absolute paths - and
  # refuse any pattern that matches one. A pattern broad enough to match arbitrary
  # absolute paths/tokens is caught with overwhelming probability; a specific owner
  # name/path matches none of them.
  _rand(){ head -c 24 /dev/urandom 2>/dev/null | LC_ALL=C tr -dc 'A-Za-z0-9' | cut -c1-16; }
  _broad=0
  # Build a canary for '/' followed by EVERY possible first character, each with a
  # random tail: '/a<rand>', '/b<rand>', ... '/9<rand>'. Any '^/[class]' pattern (or
  # '^/', '.', '.*', '^') matches at least one of these, so it is refused; but a
  # specific owner - a name or a real path like 'app' or '/srv/app' - matches none of
  # them (each canary is a single letter plus 16 random chars, not a real word).
  for _c in a b c d e f g h i j k l m n o p q r s t u v w x y z 0 1 2 3 4 5 6 7 8 9; do
    _r=$(_rand); [ -n "$_r" ] || _r="fb${RANDOM}${RANDOM}"
    for _probe in "$_r" "/${_c}${_r}"; do
      if printf '%s' "$_probe" | grep -qE "$ALLOW" 2>/dev/null; then _broad=1; break 2; fi
    done
  done
  if [ "$_broad" = "1" ]; then
    echo "GUARD-FAIL: allowed-owner-regex '$ALLOW' matches unrelated random strings, so it"
    echo "  would confirm any process and hide every foreign consumer. Name the app/path,"
    echo "  or set GUARD_ALLOW_BROAD=1 if you really mean it."
    exit 2
  fi
fi

ADAPTER="${GUARD_ADAPTER:-none}"
REGISTRY="${GUARD_REGISTRY:-./port-registry.yaml}"
ECOSYSTEM="${GUARD_ECOSYSTEM:-}"
# Lock on a validated, owner-checked directory opened READ-ONLY. A fixed /tmp lock
# file opened with `>` let a local user pre-plant a symlink and make root truncate
# an arbitrary file (CWE-59); a directory cannot be truncated.
MY_UID=$(id -u)
if [ -n "${GUARD_LOCK_DIR:-}" ]; then LOCK_DIR="$GUARD_LOCK_DIR"
elif [ "$MY_UID" = "0" ]; then LOCK_DIR=/run/lock/deploy-guard
else LOCK_DIR="${TMPDIR:-/tmp}/deploy-guard-$MY_UID"; fi
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

mkdir -p "$LOCK_DIR" 2>/dev/null
if [ -L "$LOCK_DIR" ] || [ ! -d "$LOCK_DIR" ] || [ "$(stat -c %u "$LOCK_DIR" 2>/dev/null)" != "$MY_UID" ]; then
  echo "GUARD-FAIL: unsafe lock dir $LOCK_DIR (must be a non-symlink directory owned by uid $MY_UID)"; exit 3
fi
exec 9<"$LOCK_DIR" || { echo "GUARD-FAIL: cannot open lock dir $LOCK_DIR"; exit 3; }
flock -n 9 || { echo "GUARD-FAIL: another deploy holds the lock ($LOCK_DIR)"; exit 3; }

fail(){ echo "GUARD-FAIL: $*"; exit 2; }

# Positive evidence that the port belongs to this app, as opposed to merely an absence of
# evidence that it belongs to someone else.
CONFIRMED=""
RUNTIME_UNKNOWN=0
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
if [ "$ADAPTER" != "none" ]; then
  # Enumerate consumers ONCE and check the adapter's exit status. A traversal error
  # (an unreadable config file, exit >=2) must fail, not be flattened into an empty
  # consumer set that reads as "no foreign consumers found".
  consumers=$(adapter_consumers "$PORT"); ac_rc=$?
  [ "$ac_rc" -ge 2 ] && fail "adapter '$ADAPTER' could not fully read its config tree (exit $ac_rc); refusing to treat that as 'no consumers'"
  foreign=$(printf '%s\n' "$consumers" | grep -viE "$ALLOW" | grep -v '^[[:space:]]*$' || true)
  [ -n "${foreign:-}" ] && fail "port $PORT is consumed by foreign proxy config(s): $(printf '%s' "$foreign" | tr '\n' ' ') (allowed: $ALLOW)"
  mine=$(printf '%s\n' "$consumers" | grep -iE "$ALLOW" || true)
  [ -n "${mine:-}" ] && confirm "proxy config"
fi

# 2) STATIC - process manager: is the port hardcoded in someone else's config?
if [ -n "$ECOSYSTEM" ]; then
  # A path that was configured but cannot be read is not the same as one with no match in it.
  # Neither is a glob that matches nothing: the operator named something, and silently
  # checking zero files looks identical to checking them and finding no conflict.
  _eco_seen=0
  for _e in $ECOSYSTEM; do
    if [ -e "$_e" ]; then
      _eco_seen=$((_eco_seen + 1))
      [ -r "$_e" ] || fail "process-manager config $_e exists but cannot be read"
    fi
  done
  if [ "$_eco_seen" -eq 0 ]; then
    fail "GUARD_ECOSYSTEM was set but matched no files: $ECOSYSTEM"
  fi
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
if ! command -v ss >/dev/null 2>&1; then
  # Without ss there is no runtime evidence at all. Say so rather than let the other checks
  # produce a GUARD-OK that implies the socket was inspected.
  echo "NOTE: ss is not available; the runtime check did not run" >&2
  RUNTIME_UNKNOWN=1
else
  ss_out=$(ss -lntpH 2>/dev/null)
  ss_rc=$?
  if [ "$ss_rc" -ne 0 ]; then
    echo "NOTE: ss failed (exit $ss_rc); the runtime check did not run" >&2
    RUNTIME_UNKNOWN=1
  else
    # Sockets on this port, whatever address they are bound to.
    socket_lines=$(printf '%s\n' "$ss_out" | awk -v p=":$PORT" '
      { split($4, a, "%"); addr = a[1]
        n = length(addr) - length(p)
        if (n > 0 && substr(addr, n + 1) == p) print $0 }')

    if [ -n "${socket_lines:-}" ]; then
      listeners=$(printf '%s\n' "$socket_lines" | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u)
      if [ -z "${listeners:-}" ]; then
        # Something holds the port but ss could not attribute it - usually insufficient
        # privileges. Treating that as "no listener" would confirm a port that is demonstrably
        # in use by an unidentifiable process.
        fail "port $PORT is in use but no owning process could be identified (run with more privilege)"
      fi
      for lpid in $listeners; do
        lcwd=$(readlink "/proc/$lpid/cwd" 2>/dev/null || echo '')
        if [ -z "$lcwd" ]; then
          fail "port $PORT is bound by PID $lpid whose working directory cannot be read"
        fi
        echo "$lcwd" | grep -qiE "$ALLOW" \
          || fail "port $PORT is bound by PID $lpid (cwd=$lcwd), which does not match /$ALLOW/"
      done
      confirm "running process"
    fi
  fi
fi

if [ -n "$CONFIRMED" ] && [ "$RUNTIME_UNKNOWN" = "0" ]; then
  echo "GUARD-OK: port $PORT is confirmed for '$APP' by: $CONFIRMED (no foreign consumers or reservations)"
  exit 0
fi

if [ -n "$CONFIRMED" ]; then
  echo "GUARD-INCONCLUSIVE: $CONFIRMED confirms port $PORT for '$APP', but the runtime check could"
  echo "  not run, so nothing rules out another process already holding it."
  exit 1
fi

# Nothing claimed the port - but nothing confirmed it is yours either. Saying "reserved for you"
# here would be inventing a fact. Callers that want a hard gate should treat exit 1 as a stop.
echo "GUARD-INCONCLUSIVE: no conflict found for port $PORT, but nothing confirms it belongs to '$APP'."
echo "  Add it to the registry, wire a proxy consumer, or start the process - then re-run."
exit 1
