#!/bin/bash
# pm2-inventory - assert every declared app runs from the exact expected directory.
#
# "pm2 list" shows a green "online" for an app whose name is right and whose working
# directory is wrong. That is the failure this catches: you deploy to a new path, PM2
# is still serving the old one, and every status check you own says everything is fine.
#
# Usage: pm2-inventory.sh [inventory.yaml]
#
# Environment:
#   PM2_JLIST_FILE   read "pm2 jlist" output from a file instead of running pm2 (testing)
#
# Exit: 0 all declared apps match | 2 at least one mismatch
set -uo pipefail

INV="${1:-${PM2_INVENTORY:-./pm2-inventory.yaml}}"
[ -f "$INV" ] || { echo "inventory not found: $INV"; exit 2; }

if [ -n "${PM2_JLIST_FILE:-}" ]; then
  J=$(cat "$PM2_JLIST_FILE")
else
  J=$(pm2 jlist 2>/dev/null | grep -m1 '^\[')
fi
[ -n "${J:-}" ] || { echo "could not read pm2 process list"; exit 2; }

# App names are the top-level keys of the inventory file.
APPS=$(grep -E '^[A-Za-z0-9._-]+:' "$INV" | sed 's/:.*//')
[ -n "$APPS" ] || { echo "no apps declared in $INV"; exit 2; }

FAIL=0
for app in $APPS; do
  exp_cwd=$(awk -v a="${app}:" '$0==a{f=1;next} f&&/^  cwd:/{print $2;exit} f&&/^[A-Za-z0-9._-]+:/{exit}' "$INV")
  # A declared app with no cwd cannot be verified. Skipping it and still exiting 0
  # made an incomplete inventory look identical to a fully verified one, so treat a
  # missing cwd as a configuration failure.
  if [ -z "$exp_cwd" ]; then echo "  FAIL $app has no cwd declared (cannot verify)"; FAIL=1; continue; fi

  read -r act_cwd act_st <<<"$(printf '%s' "$J" | python3 -c "
import sys, json
name = sys.argv[1]
try:
    procs = json.load(sys.stdin)
except Exception:
    print('PARSE-ERROR MISSING'); raise SystemExit
env = {p.get('name'): p.get('pm2_env', {}) for p in procs}.get(name)
if env is None:
    print('MISSING MISSING')
else:
    print((env.get('pm_cwd') or 'UNKNOWN'), (env.get('status') or 'UNKNOWN'))
" "$app")"

  if [ "$act_st" != "online" ]; then
    echo "  FAIL $app is not online (status=$act_st)"; FAIL=1; continue
  fi
  if [ "$act_cwd" != "$exp_cwd" ]; then
    echo "  FAIL $app WRONG CWD"
    echo "       expected: $exp_cwd"
    echo "       actual:   $act_cwd"
    FAIL=1
  else
    echo "  OK   $app cwd=$act_cwd"
  fi
done

if [ "$FAIL" = "0" ]; then echo 'INVENTORY: PASS'; exit 0; else echo 'INVENTORY: FAIL'; exit 2; fi
