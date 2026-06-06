# setline

`setline` is a small Linux-only local HTTP path router written in D.

It listens on a local address, matches requests by path prefix, and forwards
them to local backend services.

## Scope

- Linux only.
- Local only: the listener must bind to loopback or localhost.
- HTTP/1.x only in this first version.
- Path-prefix routing with longest-prefix priority.
- Local HTTP backends only.
- Multiple backends use simple round-robin selection. No weight support.
- `stripPrefix` is intentionally unsupported.

## Build

```bash
dub build
```

## Run

```bash
dub run -- --config config.example.json
```

## Config

```json
{
  "listen": 8080,
  "adminToken": "change-me",
  "connectTimeoutMillis": 3000,
  "routes": {
    "/api/edu": [9002, 9003],
    "/m/edu/learning": 5173,
    "/api": 9001
  }
}
```

Top-level fields:

- `listen`: listen port or address, default `127.0.0.1:8080`; accepts `8080`,
  `"8080"`, `"*:8080"`, or `"127.0.0.1:8080"`.
- `adminToken`: optional token for `__setline` management APIs.
- `connectTimeoutMillis`: backend TCP connect timeout, default `3000`.
- `maxConnections`: active client connection limit, default `65535`.
- `routes`: object mapping URL path prefixes to a local backend port or a list
  of local backend ports.

Routes are indexed by path segment with longest-prefix priority, so `/api/edu`
wins over `/api`.

## Runtime Route Registration

```bash
curl -X PUT http://127.0.0.1:8080/__setline/routes \
  -H 'Content-Type: application/json' \
  -H 'X-Setline-Token: change-me' \
  -d '{"prefix":"/api/edu","ports":[9002,9003]}'
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

This project is deliberately narrow: local-only HTTP path routing, local backend
selection, and transparent proxying.

See also:

- `doc/transparent-proxy-design.md`
- `doc/project-constraints.md`
- `doc/deployment.md`
