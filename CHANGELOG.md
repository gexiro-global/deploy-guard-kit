# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] - Unreleased

### Security
- `port-guard.sh` locks a validated, owner-checked directory under `/run/lock` opened
  read-only, replacing a predictable `/tmp` lock file opened with `>` that a local
  user could redirect at an arbitrary root-writable file (CWE-59). Lock env var is now
  `GUARD_LOCK_DIR`.
- The over-broad owner-pattern guard now probes several structurally different
  canaries, so `^/` (and other absolute-path-anchored patterns that matched every
  process cwd) are refused, not just literal `.*`/`.`/`^`.

### Fixed
- A reverse-proxy adapter that hits an unreadable config file now fails (exit 2)
  instead of flattening into an empty "no consumers" result.
- `pm2-inventory.sh`: a declared app with no `cwd` now fails instead of being
  silently skipped while the inventory still reported PASS.

### Added
- Initial public release.
- `port-guard.sh`: static reservation checks (reverse proxy, process manager, declared registry)
  plus a runtime socket-owner check, serialised with `flock`.
- Reverse-proxy adapters for OpenLiteSpeed and nginx, plus a no-op adapter.
- `pm2-inventory.sh`: asserts each declared app is online and running from its expected directory.
- `marker-healthcheck.sh`: content-marker healthcheck driven by a config file.
- Offline test suite covering all three scripts.
