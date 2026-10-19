# setline

`setline` is a small, Linux-only local HTTP path router written in D. It is a
lightweight user-space HTTP full proxy: one process listens on a fixed port,
matches requests by host and path prefix, and streams them to local backend
ports. It favours simple deployment and predictable HTTP streaming over
kernel-level transparent proxy techniques.

**Positioning: setline is a proxy that sits behind a proxy.** It is deployed
after HAProxy/Nginx and is never the first hop a client reaches. Either the
front proxy connects straight to the applications and setline only renders the
routing fragments, or setline serves as the subordinate proxy for that front
proxy - in both shapes it never faces untrusted clients, so TLS termination,
header size limits, client timeouts, rate limiting and access logging stay the
front proxy's job. The consequences of this boundary, the out-of-scope list and
the prerequisite for using setline as that proxy's subordinate live in
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
dub build                                # debug binary at target/setline
dub build --build=release-nobounds       # what the packages ship
dub test                                 # unit tests
```

Needs Linux, a D compiler (LDC) and `dub`; the only dependency is `vibe-core`.
Packaging, the end-to-end harness and the benchmark live under `scripts/`; see
`scripts/README.md`.

## Run

```bash
dub run -- init ./setline.conf                 # write a local control config
dub run -- --conf ./setline.conf -f config.example.json
dub run -- --conf ./setline.conf -c -f config.example.json
dub run -- --help                              # every flag
```

Local deployment parameters live in `setline.conf` (INI). The topology file
(`setline.json`) contains only the listener and routes. The topology file is
optional at startup: a missing file means an empty route table, so a runtime
update can create the routes. Peers are local control-plane data and live in
`setline.conf`; `setline.json` rejects an `agent` field.

## setline.conf

```ini
[remote]
url = http://127.0.0.1:8082
profile = openurp.prod
token = <Profile.key>

[topology]
file = /etc/setline/setline.json

[proxy]
# Optional. haproxy -> /etc/haproxy/haproxy.cfg,
# nginx -> /etc/nginx/nginx.conf.
#file = /etc/haproxy/haproxy.cfg

[agent]
type = haproxy
output = /var/lib/setline
# Filled by `setline pull`; name=url pairs separated by commas.
peers =

[apply]
quietSeconds = 15
runtimeDir = /run
owner = setline:beangle
```

`[apply]` may also set `type`, `configs`, `fragmentDir` and `service`; they are
derived from `[agent] type` and `[agent] output` when omitted. The package installs
`/etc/setline/setline.conf` once and never overwrites it on upgrade.

Apply state (`applied.sha256` and `lastgood/`) is always placed at
`<agent.output>/apply`; it is not configurable separately.

`[proxy] file` is optional too: it defaults to `/etc/haproxy/haproxy.cfg` for
`haproxy` and `/etc/nginx/nginx.conf` for `nginx`. Set it only for a non-standard
location.

## setline.json

```json
{
  "listen": "127.0.0.1:8080",
  "adminListen": "127.0.0.1:8081",
  "peerReaders": ["10.0.1.7"],
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
is what the packages install. Any `agent` field is rejected here; `[agent] type`,
`output` and `peers` belong to `setline.conf`.

The admin API is `/_setline/*`. It always has its own listener, `adminListen`,
defaulting to `127.0.0.1:8081`, the neighbour of the data plane port and off the
browser restricted-port lists (`10080` is blocked, so the status page would not
open there). The data plane `listen` serves exactly one endpoint,
`GET /_setline/routes` (the peer protocol), so a machine that only knows the
service port can read the route table; the status page, `status.json` and every
write live on `adminListen` alone. Route changes are therefore a localhost-only
action. Reads are gated by source address: localhost, or an address listed in
`peerReaders` - setline holds no credentials. Front proxies should reject
`/_setline` outright.

`http://127.0.0.1:8081/_setline/status.html` shows listeners, live counters, the
route table with per-port health, and refreshes itself every 5 seconds
(`?refresh=30`, `?refresh=0` to stop); `/_setline/status.json` is the same data
for machines.

The full reference - every field, its default, the validation errors and worked
examples - is `docs/configuration.md`.

## Agent mode

With `[agent] type` in `setline.conf`, `setline` renders a HAProxy or Nginx **fragment** from a
route table: its own, or a set of live `setline` peers (`[agent] peers`). It
never rewrites the proxy's own
config, and a render-only machine has no listener at all: it renders one round
and exits. `setline-agent.timer` drives one round: it renders as the unprivileged
`setline` user and then runs the root-owned `setline-apply --now` to validate
and reload, hot-syncing a routes-only map change without a reload when a
HAProxy admin socket is available. A single-host deployment keeps
`setline.service` resident instead; the same timer applies its fragments but
does not render them again.

Fields and examples: `docs/configuration.md`. Wiring: `docs/haproxy-integration.md`
and `docs/nginx-integration.md`. Applying and reloading: `docs/agent-reload.md`.

## Download generated configs

`setline` can authenticate to bashub and download all machine-generated
configuration directly. URL, Profile, token and destinations all come from
`setline.conf`, so the commands need no arguments:

```bash
setline pull
```

`[remote] url` is the bashub root (do not append `/api`). The downloader sends
`Authorization: Bearer <profile>:<key>` and accepts the key already written in
that form. Writes are atomic and left untouched when the content is unchanged.
`setline pull` fetches the peer list, the proxy config selected by the Profile's
`proxyEngine`, and the Profile's HTTPS certificate pair. It rewrites only
`[agent] peers` in `setline.conf`, so the token, local agent settings,
`setline.json`, `listen` and `routes` all survive.
Certificates are written as `/etc/setline/certs/cert.pem` and
`/etc/setline/certs/key.pem` (nginx), and `/etc/setline/certs/bundle.pem`
(haproxy). The directory is fixed because the generated proxy config references
those paths. The private-key files are mode `0600`.
When the Profile has no certificate pair, a pull removes the three managed
files instead of leaving an old key behind.

## Documentation

- `CHANGELOG.md` - what each release changed, and the upgrade steps it needs.
- `docs/configuration.md` - every config field, defaults, validation errors, examples.
- `docs/deployment.md` - where setline sits, the file descriptor budget, systemd units, packaging, shutdown.
- `docs/haproxy-integration.md`, `docs/nginx-integration.md` - fragment layout and wiring.
- `docs/agent-reload.md` - rendering, applying and reloading fragments (`setline-agent`, `setline-apply`, the timer, HAProxy map hot-sync).
- `docs/runtime-routes-api.md` - runtime route API, credentials, the status page and `status.json`.
- `docs/transparent-proxy-design.md` - the streaming and connection model, including the WebSocket tunnel.
- `docs/project-constraints.md` - scope, the privilege model and the constraints behind them.
- `docs/release-note-0.0.4.md` - the latest release: highlights, upgrade steps and verification.
- `docs/d-style.md`, `docs/d-coding.md` - D code style and coding rules.
- `scripts/README.md` - packaging, end-to-end and benchmark harnesses.

## Notes

This project is deliberately narrow: host-scoped local HTTP path routing, local
backend selection, and transparent proxying. Running `setline` as root is a
requirement to avoid, not a tuning choice - see the Privilege Model in
`docs/project-constraints.md`.
