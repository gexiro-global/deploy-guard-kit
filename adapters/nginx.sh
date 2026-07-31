#!/bin/bash
# Adapter: nginx
# Prints the name of every server config that proxies to 127.0.0.1:<port>.
# Override the config root with NGINX_CONF_DIR.
adapter_consumers(){
  local port="$1"
  local dir="${NGINX_CONF_DIR:-/etc/nginx}"
  # -E, escaped dots, and an explicit non-digit boundary: basic grep reads \b as a backspace,
  # and an unescaped dot would let 127x0y0z1 match.
  grep -rlE "127\.0\.0\.1:${port}([^0-9]|$)" "$dir" --include='*.conf' 2>/dev/null \
    | sed "s#^${dir}/##"
}
