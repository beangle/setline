# setline

`setline` is a small Linux-only local HTTP path router written in D.

It listens on a local address, matches requests by host and path prefix, and
forwards them to local backend services.

`setline` is a lightweight user-space HTTP full proxy that listens on a fixed
port and dispatches requests to local backend ports by host and URI prefix. It
favors simple deployment and predictable HTTP streaming over kernel-level
transparent proxy techniques.

## Scope

- Linux only.
- Backends are local only; the listener defaults to loopback and can
  explicitly bind other interfaces.
- HTTP/1.x only in this first version.
- Host-scoped path-prefix routing with longest-prefix priority.
- Local HTTP backends only.
- Multiple backends use random selection. No weight support.
- URL/path rewriting is intentionally unsupported.

## Build

```bash
dub build
```

## Run

```bash
dub run -- -f config.example.json
```

Check a config file without starting the listener:

```bash
dub run -- -c -f config.example.json
```

## Config

The fields below are the short version; `docs/configuration.md` has the full
reference with examples, including how `adminToken` does and does not apply.

```json
{
  "listen": 8080,
  "adminToken": "change-me",
  "connectTimeoutMillis": 3000,
  "healthCheck": {
    "intervalMillis": 5000,
    "timeoutMillis": 1000,
    "unhealthyThreshold": 2,
    "healthyThreshold": 1
  },
  "agent": {
    "type": "haproxy",
    "output": "/var/lib/setline/haproxy/setline.cfg"
  },
  "routes": {
    "local1.example.com": {
      "/api/edu": [9002, 9003],
      "/m/edu/learning": 5173,
      "/api": 9001
    },
    "local2.example.com": {
      "/api": 9081
    },
    "*": {
      "/": 9090
    }
  }
}
```

Top-level fields:

- `listen`: listen port or address, default `127.0.0.1:8080`; accepts `8080`,
  `"8080"`, `"*:8080"`, or `"127.0.0.1:8080"`.
- `adminToken`: credential for the **read** side of the `__setline` API
  (`GET /__setline/routes` and the status page/JSON) when the caller is **not**
  localhost. Localhost callers need no credential, exactly like route writes,
  which is why a co-located tool can inspect routes without storing anything.
  Empty means open to everyone, which is fine while the listener is bound to
  loopback. Route **writes** never use this token: they are accepted only from
  localhost.
- `connectTimeoutMillis`: backend TCP connect timeout, default `3000`.
- `maxConnections`: active client connection limit, default `65535`.
- `healthCheck`: TCP connect health check tuning; health checks are always
  enabled and run on a fixed background interval.
- `agent.type`: optional render target; accepts `haproxy` or `nginx`. Together
  with `agent.output` only, `setline` keeps proxying locally **and** renders its
  own route table into a fragment (proxy, setline and basctl on one machine).
  Adding `agent.peers` or `agent.remote` turns it into a render-only agent that
  does not listen at all; see Agent Mode below.
- `agent.peers`: remote setline instances whose route tables are merged into the
  rendered fragment; see Agent Mode below.
- `agent.output`: fragment path; empty prints the fragment to stdout.
- `agent.bind`: fragment listener; HAProxy `bind`, Nginx listen port.
- `agent.sync`: `once` or `interval` plus `intervalMillis`.
- `agent.remote`: optional registry manifest URL or local file path, as an
  alternative to `agent.peers`.
- `agent.workDir`: local directory for downloaded bundles and extracted
  releases, default `/tmp/setline-agent`.
- `routes`: object mapping host names to URL path prefixes, then to a local
  port or a list of local ports. Each port maps to `127.0.0.1:<port>`. Route
  host names do not include a port. Host `*` is the fallback route namespace.

Routes are first selected by the request `Host` header after removing its port
and lowercasing it. Within that host, routes are indexed by path segment with
longest-prefix priority, so `/api/edu` wins over `/api`. If the request host has
no matching route for the requested path, setline tries `*`.

## Agent Mode

`setline` can render a HAProxy or Nginx config fragment from a route table. It
never rewrites the proxy's own config file, so the custom content in that file
stays intact. There are three data sources:

- **Single host** (no `peers`, no `remote`): proxy, setline and basctl run on
  one machine; setline keeps listening as the local proxy and re-renders the
  fragment whenever its route table changes through the admin API.
- **`agent.peers`**: an edge machine merges the route tables of several remote
  `setline` instances.
- **`agent.remote`**: an edge machine downloads a registry manifest bundle
  instead of reading peers.

Single-host agent, the simplest deployment:

```json
{
  "listen": "127.0.0.1:8080",
  "agent": {
    "type": "haproxy",
    "output": "/var/lib/setline/haproxy/setline.cfg"
  },
  "routes": { "app.example.com": { "/api/edu": [9002, 9003] } }
}
```

Aggregating several machines (`agent.peers`); this one does not listen, so
`listen` and `routes` are not used:

```json
"agent": {
  "type": "nginx",
  "output": "/var/lib/setline/nginx/setline.conf",
  "token": "change-me",
  "sync": { "mode": "once", "intervalMillis": 30000 },
  "peers": [
    { "name": "app1", "url": "http://10.0.1.10:8080" },
    { "name": "app2", "url": "http://10.0.1.11:8080", "token": "app2-token" }
  ]
}
```

- `agent.type`: render target, `haproxy` or `nginx`.
- Single-host mode: omit `agent.peers` and `agent.remote`. `agent.output` is
  then required, `agent.sync` is unused, backends come from the local route
  table (host `127.0.0.1`) and the fragment is re-rendered on every route
  change.
- `agent.output`: fragment path. In peers/remote mode leaving it empty prints
  to stdout instead; single-host mode requires it.
- `agent.bind`: leave it empty (recommended) and the fragment carries only rules
  and backends, so the proxy's own config keeps the listener; set it (for
  example `*:80`) and the fragment becomes self-contained with its own
  `bind`/`listen`.
- `agent.token`: default `X-Setline-Token` for peers.
- `agent.peers[]`: remote setline instances. `url` is the peer's base address
  (setline appends `/__setline/routes`); `name` only shapes readable service
  names; `token` overrides `agent.token` for that peer. The peer's host in `url`
  is also the address the edge proxy connects back to, so a peer `url` must
  carry a host (`file://` and bare paths cannot be peers).
- `agent.sync.mode`: `once` renders one round and exits (drive it from cron or a
  systemd timer); `interval` keeps running and repeats every `intervalMillis`
  (this needs `agent.output`; without it the agent prints once and exits).
- `agent.remote`: registry manifest URL or local path, as an alternative source
  of backends. It is mutually exclusive with `agent.peers`.

Each peer is read through `GET /__setline/routes`, and its local ports are
rewritten to `<url host>:<port>`. Routes with the same host and path prefix are
merged into one backend group, so several machines serving `/api/edu` become
multiple servers of the same upstream. Longest prefixes are emitted first.
Peer tokens are handed to `curl` as a request header, so keep the agent host
trusted.

### Wiring the fragment

The generated files are fragments, never a full config, and the proxy keeps its
listener, TLS and custom content. What you write once depends on the mode:

- Rules mode (`agent.bind` empty): HAProxy gets `<output>` (backends) plus
  `<stem>.map`, and you add three `map_beg()` lines to your own `frontend`;
  Nginx gets `<output>` (upstreams, included in `http {}`) plus one
  `<stem>.<host>.conf` per host, included inside that vhost's `server {}`.
- Self-contained mode (`agent.bind` set): one file that also owns the listener.
  Nginx includes it in `http {}`; HAProxy loads it via `-f <dir>` (`-f <dir>`
  loads only `*.cfg`, and a directory cannot be added by extending `CFGDIR`, so
  the unit's `ExecStart` has to be overridden —
  `scripts/package/haproxy-setline-cfgdir.conf.example`).

Step-by-step recipes live in `docs/haproxy-integration.md` and
`docs/nginx-integration.md`.

`agent.output` is written atomically and only when its content changed.

Reloading is a separate, privileged step: an unprivileged `setline` cannot
write `/etc/nginx`, cannot pass `nginx -t`, and cannot signal a root-owned
master. The package ships `setline-apply`, a root oneshot that validates,
reloads via `systemctl reload`, and rolls the whole fragment directory back on
failure. One `setline-apply.timer` is enough: it runs `setline-apply auto`, which
asks the binary (`setline --agent-type`) what `agent.type` says and only then
touches that proxy. The action is idempotent by content hash and defers until
the fragment has been stable for a quiet window. See
`docs/agent-reload.md` for why `-sf`, `-x`, and `SIGHUP` are the wrong tools
here, and why a timer is used instead of a `systemd.path` unit.

## Agent Bundle Mode (registry manifest)

Instead of reading live `setline` peers, `agent.remote` can point at a manifest
owned by a registry system, and the referenced bundle describes the backends.
Use this when the service topology is packaged and versioned centrally rather
than discovered from running instances.

```bash
setline -f setline.json > haproxy.cfg
```

`agent.remote` points to a manifest:

```json
{
  "version": "2026.06.08.001",
  "bundleUrl": "bundles/2026.06.08.001.tar.gz",
  "sha256": "..."
}
```

The bundle is a `.tar.gz` archive. It must contain `backends.json` at its root;
certificates and keys can be shipped beside it for proxy TLS rendering:

```text
backends.json
certs/
  www.example.com/
    fullchain.pem
    privkey.pem
```

`backends.json` can use either `services` or `backends` as the top-level list:

```json
{
  "services": [
    {
      "name": "edu-learning",
      "host": "www.example.com",
      "contentPath": "/m/edu/learning",
      "healthPath": "/health",
      "instances": [
        { "host": "10.0.1.10", "port": 18001 },
        { "host": "10.0.1.11", "port": 18002 }
      ]
    }
  ]
}
```

`content_path`, `health_path`, and instance `ip` are also accepted for existing
registry payloads.

## Runtime Route Management

Runtime route updates are accepted only from localhost. They update the current
in-memory routes and write the `routes` field back to the JSON config file.
They do not use `adminToken`: writes are gated by the TCP peer address instead,
because a route change redirects traffic. Reads from localhost are gated the same
way (no credential); only reads from other hosts need `adminToken`.

Add or replace one route:

```bash
curl -X PUT 'http://127.0.0.1:8080/__setline/routes?host=local1.example.com' \
  -d '{"/api/edu":[9002,9003]}'
```

Delete one route:

```bash
curl -X DELETE 'http://127.0.0.1:8080/__setline/routes?host=local1.example.com&prefix=/api/edu'
```

Clear routes for one host:

```bash
curl -X DELETE 'http://127.0.0.1:8080/__setline/routes?host=local1.example.com'
```

Replace routes for one host:

```bash
curl -X PUT 'http://127.0.0.1:8080/__setline/routes/all?host=local1.example.com' \
  -d '{"routes":{"/api":9001,"/m/edu/learning":5173}}'
```

List routes (localhost needs no credential):

```bash
curl http://127.0.0.1:8080/__setline/routes
```

## Status

Status endpoints use HTTP Basic authentication. The username is `setline`; the
password is `adminToken`. From localhost the credential is not required (the same
door as route writes); from other hosts it is, and an empty `adminToken` leaves
status open for local development.

```bash
curl http://127.0.0.1:8080/__setline/status.json
curl -u setline:change-me http://setline.internal:8080/__setline/status.json
```

Open the HTML view in a browser:

```text
http://127.0.0.1:8080/__setline/status.html
```

### Why reads keep a token

Reads (`GET /__setline/routes`, status page/JSON) are deliberately **not**
restricted to localhost: they are meant to be consumed later from other hosts on
the same network, for example an agent that renders the route table into an
haproxy or nginx config. `adminToken` is that path's credential.

Localhost, on the other hand, is trusted the same way for reads and writes: a
co-located tool (basctl) reads routes through the same local door it writes them
through, so it never has to store a credential.

- bound to loopback, an empty token is fine — nothing else can reach the API;
- bound to `*`, set `adminToken`, otherwise the route table is readable by any
  non-localhost caller.

## Notes

This project is deliberately narrow: host-scoped local HTTP path routing, local
backend selection, and transparent proxying.

See also:

- `docs/transparent-proxy-design.md`
- `docs/project-constraints.md`
- `docs/deployment.md`
- `docs/runtime-routes-api.md`
- `docs/configuration.md`
- `docs/agent-reload.md`
- `docs/haproxy-integration.md`
- `docs/nginx-integration.md`
