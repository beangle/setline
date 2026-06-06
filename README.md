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
  "listen": "127.0.0.1:8080",
  "adminToken": "change-me",
  "connectTimeoutMillis": 3000,
  "maxConnections": 65535,
  "routes": [
    {
      "prefix": "/api/edu",
      "backends": [
        "http://127.0.0.1:9002",
        "http://127.0.0.1:9003"
      ]
    },
    {
      "prefix": "/api",
      "backend": "http://127.0.0.1:9001"
    }
  ]
}
```

Top-level fields:

- `listen`: local listen address, default `127.0.0.1:8080`.
- `adminToken`: optional token for `__setline` management APIs.
- `connectTimeoutMillis`: backend TCP connect timeout, default `3000`.
- `maxConnections`: active client connection limit, default `65535`.

Every route must define exactly one action:

- `backend`: forward to one local backend.
- `backends`: forward to multiple local backends with round-robin selection.

Routes are indexed by path segment with longest-prefix priority, so `/api/edu`
wins over `/api`.

## Runtime Route Registration

```bash
curl -X PUT http://127.0.0.1:8080/__setline/routes \
  -H 'Content-Type: application/json' \
  -H 'X-Setline-Token: change-me' \
  -d '{"prefix":"/api/edu","backends":["http://127.0.0.1:9002","http://127.0.0.1:9003"]}'
```

List routes:

```bash
curl -H 'X-Setline-Token: change-me' http://127.0.0.1:8080/__setline/routes
```

## Notes

This project is deliberately narrow: local-only HTTP path routing, local backend
selection, and transparent proxying.

See also:

- `doc/transparent-proxy-design.md`
- `doc/project-constraints.md`
- `doc/deployment.md`
