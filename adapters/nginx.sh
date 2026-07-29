#!/bin/bash
# Adapter: nginx
# Prints the name of every server config that proxies to 127.0.0.1:<port>.
# Override the config root with NGINX_CONF_DIR.
adapter_consumers(){
  local port="$1"
  local dir="${NGINX_CONF_DIR:-/etc/nginx}"
  grep -rl "127\.0\.0\.1:${port}\b" "$dir" --include='*.conf' 2>/dev/null \
    | sed "s#^${dir}/##"
}
