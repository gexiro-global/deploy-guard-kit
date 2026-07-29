# The three failures this kit is built around

## 1. Port squatting by a dead process

**Shape.** Service B owns port 3000 but has been down since a failed release. You deploy service A,
your script checks `ss -lnt`, sees 3000 free, and binds it. Days later B is restarted — or the host
reboots and both come up — and you get an intermittent outage that reproduces only on restart.

**Why the usual check misses it.** Liveness checks describe the present. Ownership is a property of
the configuration, not of the current process table.

**What `port-guard` does.** Looks for the port in reverse-proxy configs, process-manager configs and
a declared registry *before* looking at the socket. Any of those naming a different owner is a hard
fail.

## 2. Right name, wrong directory

**Shape.** You move an app to a new release path. PM2 still has the old process registered under the
same name. `pm2 list` is green, the port answers, and your changes are nowhere to be seen. Teams lose
hours here because every signal they trust says the deploy worked.

**Why the usual check misses it.** `pm2 list` matches on name and status. Neither changes when the
working directory is stale.

**What `pm2-inventory` does.** Compares `pm_cwd` against a declared expected path, per app, and fails
on any difference.

## 3. The port answers with someone else's site

**Shape.** A vhost edit, a default-server fallback, or a proxy_pass typo sends a domain to the wrong
backend. HTTP 200. TLS valid. Wrong site.

**Why the usual check misses it.** A status-code healthcheck cannot tell your site from any other
site that also returns 200.

**What `marker-healthcheck` does.** Requires a string that only your application emits. Pick something
specific — a product name, a build identifier, a JSON field. "Welcome to nginx" is not a marker.
