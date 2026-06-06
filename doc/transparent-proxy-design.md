# Transparent Proxy Design

`setline` is a local path router and transparent HTTP proxy. It uses the
request URL only to select a route, then forwards the request to the selected
local backend with minimal interference.

The client explicitly connects to the `setline` listen address, such as
`http://127.0.0.1:8080/...`. Transparency means application-layer passthrough:
headers and bodies are streamed without URL rewriting or caching, while backend
applications can still recover the browser-facing client IP, scheme, host, and
port from proxy identity headers.

## Goals

- Route by URL path prefix with longest-prefix priority.
- Keep proxying fast under browser-style concurrent resource loading.
- Preserve request headers and body semantics as much as possible.
- Avoid buffering large request bodies in memory.
- Support Vite-style development traffic, including many module requests,
  conditional requests, chunked responses, and WebSocket upgrades.

## Request Flow

For proxied routes, the server reads only the HTTP request head up to
`\r\n\r\n`. That head is enough to parse:

- request method
- request target URL
- path used for route matching
- WebSocket upgrade headers
- request body framing headers

The proxy forwards the request head to the backend without URL rewriting,
`Host` rewriting, `Connection` rewriting, or cache handling.

Proxy identity headers are conditional:

- If `Forwarded` or `X-Forwarded-For` is already present, `setline` assumes a
  trusted upstream proxy such as HAProxy has supplied proxy identity and leaves
  those headers unchanged.
- If no proxy identity header is present, `setline` is the browser-facing
  proxy and adds `Forwarded`, `X-Forwarded-For`, `X-Forwarded-Proto`,
  `X-Forwarded-Host`, and `X-Forwarded-Port`.

The backend's TCP peer address is still the `setline` to backend connection
address, usually `127.0.0.1`. Backend applications should use the proxy
identity headers to recover the browser-facing client IP, scheme, host, and
port.

If the socket read that found the header boundary also read some request body
bytes, those bytes are immediately forwarded to the backend before the proxy
continues streaming the rest of the body.

## Request Body

The proxy does not parse request body content.

- `Content-Length`: forward the already buffered bytes, then stream the
  remaining byte count from client to backend.
- `Transfer-Encoding: chunked`: forward the already buffered bytes, then stream
  chunks until the terminating chunk is observed.
- no body framing header: do not read a request body.

This keeps POST/PUT/upload requests transparent and avoids loading full request
bodies into memory.

The admin API is the exception: `/__setline` handlers need a JSON body for
route registration, so the server completes the request body before handing it
to admin code.

## Response Flow

The response head is read first and forwarded to the client. The proxy then
uses HTTP framing to know when the response is complete:

- `Content-Length`: stream the remaining byte count.
- `Transfer-Encoding: chunked`: stream chunks until the terminating chunk is
  observed.
- `HEAD`, `1xx`, `204`, `304`: treat as no-body responses.
- otherwise: stream until the backend closes the response.

These response-boundary checks are required because local development servers
often keep connections alive. Waiting for backend close on a `Content-Length`,
chunked, or `304` response can leave browser resources pending.

## WebSocket

WebSocket requests are detected from the request head. The proxy forwards the
original upgrade request head, forwards any already buffered bytes, waits for
the backend handshake response, and then tunnels both directions.

`vibe-core` fibers are used for the tunnel directions, avoiding one OS thread
per long-lived connection.

## Concurrency Model

`setline` uses `vibe-core` for TCP listening, connections, and task scheduling.
Each accepted connection is handled in a lightweight fiber. Blocking-style
stream reads and writes are kept in the code, but they yield through
`vibe-core` instead of consuming an OS thread per request.

This model was chosen after browser refreshes and concurrent Vite resource
loads exposed limitations in a thread-per-request implementation. The
transparent proxy path should stay fiber/event-loop based unless there is a
measured reason to change it.

## TPROXY Decision

Linux TPROXY is intentionally not part of the current design.

TPROXY is useful when clients should be unaware of the proxy and the kernel
must intercept traffic that was originally addressed to another IP and port.
That is not the `setline` deployment model. Users explicitly access the
`setline` listen address, and `setline` routes by HTTP URL path.

TPROXY would not remove the need to parse HTTP request heads, because URL path
routing is application-layer behavior. It would add kernel routing rules,
packet marks, elevated privileges, and operational failure modes without
improving the core proxy path.

Keep the default architecture as user-space HTTP proxying with `vibe-core`.
