#!/bin/bash
# Adapter: OpenLiteSpeed / CyberPanel
# Prints the name of every vhost whose config proxies to 127.0.0.1:<port>.
# Override the config root with OLS_VHOST_DIR.
#
# Contract: prints one consumer name per line and returns 0 when the config tree
# was fully read (including when nothing matched). Returns 2 if any candidate file
# could not be read OR the traversal itself hit a permission error (an inaccessible
# subtree) - the caller must treat that as an error, not as "no consumers".
adapter_consumers(){
  local port="$1"
  local dir="${OLS_VHOST_DIR:-/usr/local/lsws/conf/vhosts}"
  local f errf rc=0
  errf=$(mktemp)
  while IFS= read -r f; do
    [ -r "$f" ] || { rc=2; break; }
    # -E, escaped dots, and an explicit non-digit boundary: basic grep reads \b as a
    # backspace, and port 3000 would otherwise also match a vhost pointing at 30001.
    if grep -qE "127\.0\.0\.1:${port}([^0-9]|$)" "$f" 2>/dev/null; then
      printf '%s\n' "$f" | sed "s#.*/$(basename "$dir")/##; s#/vhost.conf##"
    fi
  done < <(find "$dir" -mindepth 2 -maxdepth 2 -name vhost.conf 2>"$errf")
  [ -s "$errf" ] && rc=2
  rm -f "$errf"
  return "$rc"
}
