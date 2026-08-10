# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

- No unreleased changes.

## [0.1.1] - 2026-08-10

- Standardize the canonical test runner on an explicit Bash shebang and direct execution.

## [0.1.0]

### Security
- `port-guard.sh` locks a validated, owner-checked directory under `/run/lock` opened
  read-only, replacing a predictable `/tmp` lock file opened with `>` that a local
  user could redirect at an arbitrary root-writable file (CWE-59). Lock env var is now
  `GUARD_LOCK_DIR`. The whole lock-path **ancestor chain** is validated (no symlink or
  untrusted-owner component), not just the final directory.
- **Breaking:** the `<allowed-owner>` argument is now a `|`-separated list of LITERAL
  owner tokens matched as fixed strings, not a regex. An arbitrary regex used as an
  ownership identity could be crafted to match every process cwd (e.g. `^/[a-z]+/`)
  and confirm any listener; detecting a "too-broad" regex is undecidable, so ownership
  is matched literally and cannot be broad. Alternation via `|` still works
  (`example-web|example-api`); `GUARD_ALLOW_BROAD` is removed (no longer needed). A
  listener's working directory, proxy consumers and process-manager configs are all
  matched at **component boundaries** (separators `/ . - _` are boundaries; owner
  `foreign` matches `foreign/app` or `foreign.conf` but not `foreignstuff`), and a
  token with no alphanumeric character (e.g. `.` or `/`) is rejected as too generic.

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
