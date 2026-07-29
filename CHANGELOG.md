# Changelog

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.0] - Unreleased

### Added
- Initial public release.
- `port-guard.sh`: static reservation checks (reverse proxy, process manager, declared registry)
  plus a runtime socket-owner check, serialised with `flock`.
- Reverse-proxy adapters for OpenLiteSpeed and nginx, plus a no-op adapter.
- `pm2-inventory.sh`: asserts each declared app is online and running from its expected directory.
- `marker-healthcheck.sh`: content-marker healthcheck driven by a config file.
- Offline test suite covering all three scripts.
