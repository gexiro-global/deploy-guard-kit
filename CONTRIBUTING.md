# Contributing

Bug reports with a reproduction are the most useful contribution. Adapters for other reverse
proxies are welcome and easy — implement `adapter_consumers <port>` and add a test.

## Ground rules

- These scripts must stay read-only. A pull request that restarts, rewrites or repairs anything
  will be closed; the value of a guard is that it cannot make the situation worse.
- `shellcheck` must pass clean.
- Every behaviour change needs an assertion in `tests/run_tests.sh`, and the suite must stay fully
  offline — no network, no PM2, no root.

## Support expectations

Maintained on a best-effort basis. No SLA and no commercial support. If these checks are
load-bearing in your release process, vendor them and pin the version.
