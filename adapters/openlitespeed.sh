#!/bin/bash
# Adapter: OpenLiteSpeed / CyberPanel
# Prints the name of every vhost whose config proxies to 127.0.0.1:<port>.
# Override the config root with OLS_VHOST_DIR.
adapter_consumers(){
  local port="$1"
  local dir="${OLS_VHOST_DIR:-/usr/local/lsws/conf/vhosts}"
  grep -rl "127.0.0.1:${port}\b" "$dir"/*/vhost.conf 2>/dev/null \
    | sed "s#.*/$(basename "$dir")/##; s#/vhost.conf##"
}
