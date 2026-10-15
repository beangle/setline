# Runtime Routes API

This document describes the HTTP API for updating `setline` routes at runtime.
These APIs update the in-memory route table and write the `routes` field back
to the JSON config file. Other config fields are preserved.

Every endpoint lives under `/_setline/`, split across two listeners. The data
plane (`listen`) carries exactly one of them - `GET /_setline/routes`, the peer
protocol - so a machine that only knows the service port can read the route
table. Everything else is on `adminListen` (`127.0.0.1:10080` by default): the
status views and every write (`PUT` / `DELETE`). The data plane answers anything
else under `/_setline` with `404`, including `status.json`. Examples below use
the admin listener.

All write APIs require:

- caller TCP peer must be localhost: `127.0.0.1`, `::1`, or
  `::ffff:127.0.0.1`

Write APIs do not require `X-Setline-Token` because they are accepted only from
localhost — a route change redirects traffic, so this side is never exposed.

Read APIs follow the same door: a **localhost caller needs no credential**, so a
co-located tool (basctl) can inspect the route table without storing anything.
For callers from other hosts the read stays open by design — the route table is
meant to be read from other machines on the same network (for example an agent
that renders it into a haproxy or nginx config) — and that path is guarded by
`adminToken`.

Do not use `Forwarded` or `X-Forwarded-For` to satisfy the localhost
requirement. The server checks the TCP peer address.

## Who reads, and with what

| Operation | Listener | Allowed source | Credential |
|---|---|---|---|
| `GET /_setline/routes` | `listen`, `adminListen` | local | none |
| `GET /_setline/routes` | `listen`, `adminListen` | everything else | `X-Setline-Token` (empty token = open) |
| status page / `status.json` | `adminListen` only | local | none |
| status page / `status.json` | `adminListen` only | everything else | `X-Setline-Token` (empty token = open) |
| `PUT` / `DELETE` routes | `adminListen` only | local only | none |

Reads have exactly one credential: the `X-Setline-Token` header. There is no
Basic Auth path, and no read endpoint is exempt from the rule.

"Local" requires both a loopback TCP peer (`127.0.0.1` / `::1` / `::ffff:127.0.0.1`)
and a loopback request host (`Host` or `X-Forwarded-Host` naming `127.0.0.1`,
`::1`, or `localhost`, port ignored). Requests without a `Host` are never local.
The host dimension targets local proxies: in `remote client -> local
haproxy/nginx -> setline` the forwarded request carries the public host name, so
it is treated as remote - the write gate answers `403` and reads need the token.
A proxy can rewrite `Host` to evade that, so treat this as defense in depth and
keep rejecting the admin path at the proxy (`http-request deny if { path_beg
/_setline }`, `location ^~ /_setline { return 404; }`, or a rule matching just
`/_setline/routes`): that route-table read is served by `listen`, so a proxy that
forwards `/_setline` turns it into a public read unless `adminToken` is set. The
gate also does not distinguish local users or processes, so do not share a host
or network namespace with untrusted ones.

An empty `adminToken` leaves reads open: the route table read rides `listen`, so
anything that can reach the data plane (directly, or through a proxy that does
not reject the path) can read it. Set `adminToken` for one shared credential,
reject `/_setline` at the proxy, or keep `listen` on loopback. The status views
are unaffected - they are served by `adminListen` alone, which defaults to
`127.0.0.1:10080` - and so are writes, which always require a local caller.

Admin request bodies are capped at a 4 MiB defensive limit and oversized ones get
`413`.

## List Routes

```http
GET /_setline/routes
```

Example (from localhost no credential is needed):

```bash
curl http://127.0.0.1:10080/_setline/routes
```

From another host, present the token:

```bash
curl -H 'X-Setline-Token: change-me' \
  http://setline.internal:10080/_setline/routes
```

Response:

```json
{
  "local1.example.com": [
    {"prefix":"/m/edu/learning","port":5173},
    {"prefix":"/api/edu","ports":[9002,9003]}
  ],
  "local2.example.com": [
    {"prefix":"/api","port":9081}
  ],
  "*": [
    {"prefix":"/","port":9090}
  ]
}
```

## Add Or Replace One Route

```http
PUT /_setline/routes?host=local1.example.com
```

Single port:

```json
{"/m/edu/learning":5173}
```

Multiple ports:

```json
{"/api/edu":[9002,9003]}
```

Example:

```bash
curl -X PUT 'http://127.0.0.1:10080/_setline/routes?host=local1.example.com' \
  -d '{"/api/edu":[9002,9003]}'
```

Response:

```json
{"prefix":"/api/edu","ports":[9002,9003]}
```

## Delete One Route

```http
DELETE /_setline/routes?host=local1.example.com&prefix=/api/edu
```

Example:

```bash
curl -X DELETE 'http://127.0.0.1:10080/_setline/routes?host=local1.example.com&prefix=/api/edu'
```

Response is the remaining route list:

```json
{
  "local1.example.com": [
    {"prefix":"/m/edu/learning","port":5173}
  ]
}
```

## Clear Routes For One Host

```http
DELETE /_setline/routes?host=local1.example.com
```

Example:

```bash
curl -X DELETE 'http://127.0.0.1:10080/_setline/routes?host=local1.example.com'
```

Response:

```json
{}
```

## Replace Routes For One Host

```http
PUT /_setline/routes/all?host=local1.example.com
```

Body:

```json
{
  "routes": {
    "/api/edu": [9002, 9003],
    "/m/edu/learning": 5173
  }
}
```

Example:

```bash
curl -X PUT 'http://127.0.0.1:10080/_setline/routes/all?host=local1.example.com' \
  -d '{"routes":{"/api/edu":[9002,9003],"/m/edu/learning":5173}}'
```

Response is the new route list:

```json
{
  "local1.example.com": [
    {"prefix":"/m/edu/learning","port":5173},
    {"prefix":"/api/edu","ports":[9002,9003]}
  ]
}
```

## Validation Rules

- `prefix` must start with `/`.
- write operations must include a `host` query parameter.
- route host names are lowercased and must not include a port.
- `host=*` is allowed and updates the fallback route namespace, not all hosts.
- trailing slashes are ignored except for root `/`; `/m/edu/learning/` is
  normalized to `/m/edu/learning`.
- `prefix` must not start with `/_setline`.
- ports must be integers in `1..65535`.
- each port maps to `127.0.0.1:<port>`; full upstream URLs are not part of the
  route model.
- route object values are either one port integer or a non-empty array of ports.
- write request bodies must be JSON text; `Content-Type` is not required.
- URL rewriting is not supported.

## Status Codes

- `200 OK`: request accepted.
- `400 Bad Request`: invalid JSON, invalid host, invalid route, missing route,
  or unsupported field.
- `401 Unauthorized`: missing or invalid `X-Setline-Token` on any read API
  (routes and status alike).
- `403 Forbidden`: a route change whose peer or `Host` is not loopback.
- `403 Forbidden`: write request did not come from localhost.
- `404 Not Found`: unknown admin endpoint.

## Status View

```http
GET /_setline/status.json
```

The status views live on the admin listener (`adminListen`, `127.0.0.1:10080` by
default) only. They carry listener addresses, timeouts, `maxConnections`,
health-check tuning, counters and the whole route table, and no other machine
needs them, so the data plane does not serve them: a `GET /_setline/status.json`
sent to `listen` gets `404`, as does anything else under `/_setline` except the
peer-protocol `GET /_setline/routes`. Same credential on both doors
(`X-Setline-Token` for non-local callers), but not the same reach.

Returns listener info, active/max connections, timeouts, health-check tuning, the
route table with per-port health, and cumulative counters. The admin listen
address is deliberately absent - it belongs to the HTML status page (and the
startup log), not to the machine-readable view:

```json
{
  "listen": {"host": "127.0.0.1", "port": 8080},
  "activeConnections": 0,
  "activeRequests": 0,
  "activeWebSockets": 0,
  "maxConnections": 65535,
  "connectTimeoutMillis": 3000,
  "accessLog": false,
  "counters": {
    "poolHits": 128,
    "upstreamConnects": 4,
    "upstreamLeased": 2,
    "upstreamIdle": 1,
    "upstreamTimeouts": 0,
    "unhealthyTransitions": 0,
    "portRequests": {"9002": 96, "9003": 32},
    "webSocketTunnels": 1,
    "webSocketIdleTimeouts": 0,
    "webSocketBytesToUpstream": 40,
    "webSocketBytesToClient": 512
  },
  "routes": {"local1.example.com": [{"prefix": "/api", "ports": [{"port": 9002, "healthy": true}]}]}
}
```

Counters are cumulative since process start and are not persisted. `activeRequests`
counts requests currently being processed, but not WebSocket tunnels: after the 101
the connection is a long-lived tube, so it is tracked by `activeWebSockets` and does
not hold up a graceful shutdown. `webSocketBytes*` exclude the 101 handshake itself.
`upstreamLeased` (upstream connections currently attached to client connections) and
`upstreamIdle` (upstream connections sitting in the idle pool) are gauges rather than
totals, and `poolHits` counts every upstream connection reuse, whether it came from
the idle pool or from the client connection's own affinity.
`GET /_setline/status` (or `/_setline/status.html`) serves the same data as an
HTML page.

## Health State

After a route update, port health state is refreshed:

- ports still referenced keep their current online/offline state and counters
- new ports start healthy
- ports no longer referenced by any route are removed from the health table

## Persistence

Runtime route updates are persisted by default. `setline` rewrites only the
top-level `routes` field in the config file that was used at startup. Listener,
The admin request body is capped at 4 MiB (`413` beyond that). token, timeout,
health-check, and connection-limit settings are preserved.

The write happens before the in-memory route table is swapped. If the config
file cannot be written, the API returns an error and the current in-memory
routes remain unchanged.
