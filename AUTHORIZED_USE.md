# Authorized Use

This kit inspects the configuration and running processes of the host it executes on, and issues
HTTP requests to addresses you configure — by default `127.0.0.1`.

Run it only on systems you own or are explicitly authorized to administer.

Do not point `marker-healthcheck` at third-party hosts. It is a self-check for your own backends,
not a probe for someone else's.
