## Summary

Describe the change and why it is needed.

## Verification

- [ ] `shellcheck port-guard.sh pm2-inventory.sh marker-healthcheck.sh adapters/*.sh tests/run_tests.sh` is clean
- [ ] `./tests/run_tests.sh` passes
- [ ] Any new fail-open path (an unverified condition reported as GUARD-OK / PASS) has a regression test

## Safety

These are read-only pre-deploy checks: they inspect and report, and change no system state.

- [ ] The change keeps the tools read-only (no writes to firewall, config, or process state).
- [ ] "No conflict found" and "confirmed owned" stay distinct verdicts; ownership is matched
      at path-component boundaries, never as a broad regex/substring.
- [ ] `Signed-off-by:` (DCO) present.
