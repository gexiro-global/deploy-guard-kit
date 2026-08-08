# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] - Unreleased

### Security
- `port-guard.sh` locks a validated, owner-checked directory under `/run/lock` opened
  read-only, replacing a predictable `/tmp` lock file opened with `>` that a local
  user could redirect at an arbitrary root-writable file (CWE-59). Lock env var is now
  `GUARD_LOCK_DIR`.
- The over-broad owner-pattern guard now probes a complete set of canaries - `/`
  followed by every possible first character plus a random tail - so `^/` and every
  `^/[class]`-style pattern (which match arbitrary process cwds) are refused, while
  a specific owner name or path is not. `GUARD_ALLOW_BROAD=1` remains the explicit
  opt-out.

### Fixed
- A reverse-proxy adapter that hits an unreadable config file OR an inaccessible
  subtree (a `find` traversal error) now fails (exit 2) instead of flattening into
  an empty "no consumers" result.
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
