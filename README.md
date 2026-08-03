# deploy-guard-kit

[![CI](https://github.com/dzeusking-dev/deploy-guard-kit/actions/workflows/ci.yml/badge.svg)](https://github.com/dzeusking-dev/deploy-guard-kit/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/license-Apache--2.0-blue.svg)](LICENSE)

Three pre-flight checks for single-host deploys, aimed at the failures that green status
indicators do not catch.

Each one exists because of a specific outage shape:

| Script | The failure it catches |
|---|---|
| `port-guard.sh` | You deploy onto a port that is free *right now* only because its rightful owner is down. |
| `pm2-inventory.sh` | PM2 shows your app `online` under the right name — from the wrong directory. |
| `marker-healthcheck.sh` | The port answers, returns 200, and serves someone else's site. |

They are independent. Use one, use all three.

## Why not just check if the port is open

Because "is anything listening?" and "does this port belong to me?" are different questions,
and only the second one is safe to deploy against.

A port that is free during your deploy window may be statically reserved somewhere you did
not look: a reverse-proxy vhost that still points at it, a process-manager config that will
claim it on the next boot, or a registry entry that says another service owns it. `port-guard`
checks all three of those *plus* the live socket, and holds a `flock` so two deploys cannot
race each other into the same conclusion.

## Install

```bash
git clone https://github.com/dzeusking-dev/deploy-guard-kit.git
cd deploy-guard-kit
cp examples/port-registry.example.yaml port-registry.yaml
cp examples/pm2-inventory.example.yaml pm2-inventory.yaml
cp examples/checks.example.conf checks.conf
```

Edit the three config files to describe your host, then commit them. They are meant to record
what *should* be true, which is why they are hand-written and never generated from runtime.

Requirements: `bash`, `flock`, `grep`, `awk`. `port-guard` also uses `ss`; `pm2-inventory` uses
`python3` for JSON parsing; `marker-healthcheck` uses `curl`.

## Usage

```bash
# Refuse the deploy unless port 3000 is reserved for example-web
GUARD_ADAPTER=nginx GUARD_REGISTRY=./port-registry.yaml \
  ./port-guard.sh example-web 3000 'example-web'

# Assert every declared app runs from its expected directory
./pm2-inventory.sh pm2-inventory.yaml

# Assert each backend serves the site it is supposed to
./marker-healthcheck.sh checks.conf
```

Wire the guard into a deploy script:

```bash
./port-guard.sh "$APP" "$PORT" "$APP" || exit 1
# ... build and restart ...
./pm2-inventory.sh && ./marker-healthcheck.sh
```

### Reverse-proxy adapters

`port-guard` reads proxy configs through a small adapter that only has to implement
`adapter_consumers <port>`. Shipped: `openlitespeed`, `nginx`, `none` (default).

```bash
GUARD_ADAPTER=openlitespeed OLS_VHOST_DIR=/usr/local/lsws/conf/vhosts ./port-guard.sh ...
GUARD_ADAPTER=nginx        NGINX_CONF_DIR=/etc/nginx              ./port-guard.sh ...
```

Writing one for Caddy or Apache is about five lines — see [`adapters/`](adapters/).

### Environment

| Variable | Used by | Default |
|---|---|---|
| `GUARD_ADAPTER` | port-guard | `none` |
| `GUARD_REGISTRY` | port-guard | `./port-registry.yaml` |
| `GUARD_LOCK` | port-guard | `/tmp/deploy-guard.lock` |
| `GUARD_ECOSYSTEM` | port-guard | unset (glob of process-manager configs to scan) |
| `PM2_JLIST_FILE` | pm2-inventory | unset (reads a saved `pm2 jlist` instead of calling pm2) |
| `HC_TARGET` | marker-healthcheck | `127.0.0.1` |
| `HC_TIMEOUT` | marker-healthcheck | `8` |

### Outcomes

`port-guard` reports one of three things, because "I found no conflict" and "this port is yours"
are different claims:

| Verdict | Exit | Meaning |
|---|---|---|
| `GUARD-OK` | `0` | At least one source positively confirms the port belongs to this app - a registry entry, a proxy consumer, or a running process with a matching working directory. |
| `GUARD-INCONCLUSIVE` | `1` | Nothing else claims the port, but nothing confirms it is yours either. Declare it somewhere, then re-run. |
| `GUARD-FAIL` | `2` | Something else owns or consumes it. |
| — | `3` | Another deploy holds the lock. |

If you use this as a hard gate, treat anything other than `0` as a stop. An earlier version
reported success whenever it simply failed to find a conflict, which is the failure mode this
three-state split exists to remove.

`pm2-inventory` and `marker-healthcheck` use `0` pass · `2` fail.

## What this kit does NOT do

- It does not deploy anything, restart anything, or modify any configuration. Every script is
  read-only against your system.
- It does not discover your topology. The registry and inventory are hand-maintained on purpose;
  a file generated from runtime state can only ever agree with runtime state.
- It is not a monitoring system. These are pre- and post-deploy assertions, not a daemon.
- `marker-healthcheck` proves a marker string is present. It does not prove the app is correct.

## Limitations

`port-guard`'s static checks are text searches over configuration files. An unusual config layout,
an include chain, or a templated port number can hide a reservation from it. Treat a `GUARD-OK`
as "no conflict found in the places I know how to look", not as proof of exclusivity.

## Testing

```bash
./tests/run_tests.sh
```

Fully offline: no network, no PM2, no firewall, no privileged access. The PM2 check runs against
JSON fixtures; the healthcheck runs against a stubbed `curl`; the registry parser is exercised with
the YAML variations people actually write.

## License

Apache-2.0. See [LICENSE](LICENSE).

Built and maintained by Gexiro Global Enterprises Ltd.
