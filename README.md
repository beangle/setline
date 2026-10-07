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
    "remote": "https://registry.example.com/proxy/prod/latest.json",
    "workDir": "/var/lib/setline-agent"
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
- `agent.type`: optional render target; accepts `haproxy` or `nginx`. When set,
  `setline -f` runs in agent render mode instead of starting the local proxy.
- `agent.remote`: optional manifest URL or local file path used by proxy config
  rendering.
- `agent.workDir`: local directory for downloaded bundles and extracted
  releases, default `/tmp/setline-agent`.
- `routes`: object mapping host names to URL path prefixes, then to a local
  port or a list of local ports. Each port maps to `127.0.0.1:<port>`. Route
  host names do not include a port. Host `*` is the fallback route namespace.

Routes are first selected by the request `Host` header after removing its port
and lowercasing it. Within that host, routes are indexed by path segment with
longest-prefix priority, so `/api/edu` wins over `/api`. If the request host has
no matching route for the requested path, setline tries `*`.

## Remote Proxy Rendering

`setline` can render HAProxy or Nginx config from a remote manifest and bundle.
This is an agent-style helper for edge proxy machines; it does not change the
normal transparent proxy behavior.

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

- `doc/transparent-proxy-design.md`
- `doc/project-constraints.md`
- `doc/deployment.md`
- `doc/runtime-routes-api.md`
