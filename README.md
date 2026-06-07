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
- `adminToken`: optional token for `__setline` management APIs.
- `connectTimeoutMillis`: backend TCP connect timeout, default `3000`.
- `maxConnections`: active client connection limit, default `65535`.
- `healthCheck`: TCP connect health check tuning; health checks are always
  enabled and run on a fixed background interval.
- `routes`: object mapping host names to URL path prefixes, then to a local
  port or a list of local ports. Each port maps to `127.0.0.1:<port>`. Route
  host names do not include a port. Host `*` is the fallback route namespace.

Routes are first selected by the request `Host` header after removing its port
and lowercasing it. Within that host, routes are indexed by path segment with
longest-prefix priority, so `/api/edu` wins over `/api`. If the request host has
no matching route for the requested path, setline tries `*`.

## Runtime Route Management

Runtime route updates are accepted only from localhost. They update the current
in-memory routes and write the `routes` field back to the JSON config file.

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

List routes:

```bash
curl -H 'X-Setline-Token: change-me' http://127.0.0.1:8080/__setline/routes
```

## Status

Status endpoints use HTTP Basic authentication. The username is `setline`; the
password is `adminToken`. If `adminToken` is empty, status access is open for
local development.

```bash
curl -u setline:change-me http://127.0.0.1:8080/__setline/status.json
```

Open the HTML view in a browser:

```text
http://127.0.0.1:8080/__setline/status.html
```

## Notes

This project is deliberately narrow: host-scoped local HTTP path routing, local
backend selection, and transparent proxying.

See also:

- `doc/transparent-proxy-design.md`
- `doc/project-constraints.md`
- `doc/deployment.md`
- `doc/runtime-routes-api.md`
