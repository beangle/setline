# setline

`setline` is a small, Linux-only local HTTP path router written in D. It is a
lightweight user-space HTTP full proxy: one process listens on a fixed port,
matches requests by host and path prefix, and streams them to local backend
ports. It favours simple deployment and predictable HTTP streaming over
kernel-level transparent proxy techniques.

**Positioning: setline is a proxy that sits behind a proxy.** It is deployed
after HAProxy/Nginx and is never the first hop a client reaches. The front proxy
connects to setline's listen address and setline routes the request to the local
application port. It never faces untrusted clients, so TLS termination, header
size limits, client timeouts, rate limiting and access logging stay the front
proxy's job. The consequences of this boundary, the out-of-scope list and the
prerequisite for using setline as that proxy's subordinate live in
`docs/project-constraints.md`.

## Scope

- Linux only.
- Backends are local only; the listener defaults to loopback and can
  explicitly bind other interfaces.
- HTTP/1.x only; HTTP/2, HTTP/3 and TLS belong to the front proxy.
- Host-scoped path-prefix routing with longest-prefix priority.
- Local HTTP backends only.
- Multiple backends use random selection. No weight support.
- URL/path rewriting is intentionally unsupported.

## Build

```bash
dub build --config=application --compiler=ldc2   # target/setline
dub build --build=release-nobounds --compiler=ldc2
dub test --compiler=ldc2                         # unit tests
```

Needs Linux, a D compiler (LDC) and `dub`; the only dependency is `vibe-core`.
Packaging, the end-to-end harness and the benchmark live under `scripts/`; see
`scripts/README.md`.

## Run

```bash
dub run -- -f config.example.json    # service
dub run -- -c -f config.example.json # validate the config
```

`setline` is the resident data plane and reads only `setline.json`. The topology
file contains the listener, timeouts and routes; it is optional at startup, a
missing file means an empty route table so a runtime update can create routes.

## setline.json

```json
{
  "listen": "127.0.0.1:8080",
  "adminListen": "127.0.0.1:8081",
  "routes": {
    "local1.example.com": { "/api/edu": [9002, 9003], "/api": 9001 },
    "local2.example.com": { "/api": 9081 },
    "*": { "/": 9090 }
  }
}
```

Routes are chosen by the request `Host` header (port stripped, lowercased), then
by longest path prefix within that host, with `*` as the fallback namespace.
Each port maps to `127.0.0.1:<port>`: setline proxies only to local backends.
`config.example.json` shows the topology keys, and `scripts/package/setline.json`
is what the packages install.

The admin API is `/_setline/*`. It always has its own listener, `adminListen`,
defaulting to `127.0.0.1:8081`, the neighbour of the data plane port and off the
browser restricted-port lists (`10080` is blocked, so the status page would not
open there). The data plane `listen` serves exactly one endpoint,
`GET /_setline/routes`, so a local caller that only knows the service port can
read the route table; the status page, `status.json` and every write live on
`adminListen` alone. Route changes are therefore a localhost-only action. Reads
are also localhost-only; setline holds no credentials and has no reader list.
Front proxies should reject `/_setline` outright.

`http://127.0.0.1:8081/_setline/status.html` shows listeners, live counters, the
route table with per-port health, and refreshes itself every 5 seconds
(`?refresh=30`, `?refresh=0` to stop); `/_setline/status.json` is the same data
for machines.

The full reference - every field, its default, the validation errors and worked
examples - is `docs/configuration.md`.

## Documentation

- `CHANGELOG.md` - what each release changed, and the upgrade steps it needs.
- `docs/configuration.md` - every config field, defaults, validation errors, examples.
- `docs/deployment.md` - where setline sits, the file descriptor budget, systemd units, packaging, shutdown.
- `docs/haproxy-integration.md`, `docs/nginx-integration.md` - wiring setline behind a front proxy.
- `docs/runtime-routes-api.md` - runtime route API, the status page and `status.json`.
- `docs/project-constraints.md` - scope, the privilege model and the constraints behind them.
- `scripts/README.md` - packaging, end-to-end and benchmark harnesses.

## Notes

This project is deliberately narrow: host-scoped local HTTP path routing, local
backend selection, and transparent proxying. Running `setline` as root is a
requirement to avoid, not a tuning choice - see the Privilege Model in
`docs/project-constraints.md`.
