# setline

`setline` is a small Linux-only local HTTP path router written in D.

It listens on a local address, matches requests by path prefix, and forwards
them to local backend services. A route can also return a prebuilt direct
response for fast local endpoints such as health checks.

## Scope

- Linux only.
- Local only: the listener must bind to loopback or localhost.
- HTTP/1.x only in this first version.
- Path-prefix routing with longest-prefix priority.
- Local HTTP backends only.
- Multiple backends use simple round-robin selection. No weight support.
- Direct responses are supported for fast local short-circuit paths.
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
  "routes": [
    {
      "prefix": "/healthz",
      "directResponse": {
        "status": 200,
        "contentType": "application/json",
        "body": "{\"status\":\"ok\"}"
      }
    },
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

Every route must define exactly one action:

- `backend`: forward to one local backend.
- `backends`: forward to multiple local backends with round-robin selection.
- `directResponse`: return a prepared local response.

Because routes are sorted by longest prefix first, `/api/edu` wins over `/api`.

Direct response fields:

- `status`: HTTP status code, default `200`.
- `contentType`: response content type, default `text/plain; charset=utf-8`.
- `body`: response body, default empty.
- `headers`: optional extra response headers.

For direct responses, the complete HTTP response is built when the config is
loaded or when a route is registered.

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
selection, transparent proxying, and optional direct responses.

See also:

- `doc/transparent-proxy-design.md`
- `doc/project-constraints.md`
