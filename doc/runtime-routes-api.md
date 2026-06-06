# Runtime Routes API

This document describes the HTTP API for updating `setline` routes at runtime.
These APIs update only in-memory routes. They do not rewrite the JSON config
file, so routes are loaded from the config file again after restart.

All write APIs require:

- caller TCP peer must be localhost: `127.0.0.1`, `::1`, or
  `::ffff:127.0.0.1`

Write APIs do not require `X-Setline-Token` because they are accepted only from
localhost. Read APIs still use the normal admin token behavior.

Do not use `Forwarded` or `X-Forwarded-For` to satisfy the localhost
requirement. The server checks the TCP peer address.

## List Routes

```http
GET /__setline/routes
X-Setline-Token: change-me
```

Example:

```bash
curl -H 'X-Setline-Token: change-me' \
  http://127.0.0.1:8080/__setline/routes
```

Response:

```json
[
  {"prefix":"/m/edu/learning","port":5173},
  {"prefix":"/api/edu","ports":[9002,9003]}
]
```

## Add Or Replace One Route

```http
PUT /__setline/routes
```

Single port:

```json
{"prefix":"/m/edu/learning","port":5173}
```

Multiple ports:

```json
{"prefix":"/api/edu","ports":[9002,9003]}
```

Example:

```bash
curl -X PUT http://127.0.0.1:8080/__setline/routes \
  -d '{"prefix":"/api/edu","ports":[9002,9003]}'
```

Response:

```json
{"prefix":"/api/edu","ports":[9002,9003]}
```

## Delete One Route

```http
DELETE /__setline/routes?prefix=/api/edu
```

Example:

```bash
curl -X DELETE 'http://127.0.0.1:8080/__setline/routes?prefix=/api/edu'
```

Response is the remaining route list:

```json
[
  {"prefix":"/m/edu/learning","port":5173}
]
```

## Clear All Routes

```http
DELETE /__setline/routes
```

Example:

```bash
curl -X DELETE http://127.0.0.1:8080/__setline/routes
```

Response:

```json
[]
```

## Replace All Routes

```http
PUT /__setline/routes/all
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
curl -X PUT http://127.0.0.1:8080/__setline/routes/all \
  -d '{"routes":{"/api/edu":[9002,9003],"/m/edu/learning":5173}}'
```

Response is the new route list:

```json
[
  {"prefix":"/m/edu/learning","port":5173},
  {"prefix":"/api/edu","ports":[9002,9003]}
]
```

## Validation Rules

- `prefix` must start with `/`.
- `prefix` must not start with `/__setline`.
- backend ports must be integers in `1..65535`.
- backend host is always `127.0.0.1`.
- route values accept either one `port` or `ports`, not both.
- write request bodies must be JSON text; `Content-Type` is not required.
- full backend URLs, `stripPrefix`, `directResponse`, and URL rewriting are not
  supported.

## Status Codes

- `200 OK`: request accepted.
- `400 Bad Request`: invalid JSON, invalid route, missing route, or unsupported
  field.
- `401 Unauthorized`: missing or invalid `X-Setline-Token` on read APIs.
- `403 Forbidden`: write request did not come from localhost.
- `404 Not Found`: unknown admin endpoint.

## Health State

After a route update, backend health state is synchronized by port:

- ports still referenced keep their current online/offline state and counters
- new ports start healthy
- ports no longer referenced by any route are removed from the health table
