#!/bin/bash
# Adapter: nginx
# Prints the name of every server config that proxies to 127.0.0.1:<port>.
# Override the config root with NGINX_CONF_DIR.
#
# Contract: prints one consumer path per line and returns 0 when the config tree
# was fully read (including when nothing matched). Returns 2 if any candidate file
# could not be read OR the traversal itself hit a permission error (an inaccessible
# subtree) - the caller must treat that as an error, not as "no consumers".
adapter_consumers(){
  local port="$1"
  local dir="${NGINX_CONF_DIR:-/etc/nginx}"
  local f errf rc=0
  errf=$(mktemp)
  while IFS= read -r f; do
    [ -r "$f" ] || { rc=2; break; }
    # -E, escaped dots, and an explicit non-digit boundary: basic grep reads \b as a
    # backspace, and an unescaped dot would let 127x0y0z1 match.
    if grep -qE "127\.0\.0\.1:${port}([^0-9]|$)" "$f" 2>/dev/null; then
      printf '%s\n' "$f" | sed "s#^${dir}/##"
    fi
  done < <(find "$dir" -type f -name '*.conf' 2>"$errf")
  # find writes "Permission denied" for any subtree it could not enter; a silently
  # skipped subtree must not look like a clean, empty result.
  [ -s "$errf" ] && rc=2
  rm -f "$errf"
  return "$rc"
}
