# Security Policy

## Supported Versions

`deploy-guard-kit` v0.x is maintained on the latest v0.x release line.

## Reporting a Vulnerability

Use GitHub private vulnerability reporting if enabled on this repository, otherwise email
`admin@gexiro.com`.

Include a minimal reproduction built from the synthetic fixtures in `examples/` and `tests/`.
Do not send real configuration files, hostnames, or port maps.

## Threat model

All three scripts are read-only with respect to system state: they inspect configuration files,
the process list and HTTP responses, and change nothing.

They do consume files you point them at. `port-guard` and `pm2-inventory` parse YAML-shaped input
with `awk` and `grep`, and `pm2-inventory` passes a process list through `python3`. Treat the
registry, the inventory and the checks file as trusted input owned by the operator — do not point
these scripts at files that an untrusted party can write.

`marker-healthcheck` sends a `Host` header you supply to an address you supply. Do not feed it
untrusted hostnames.
