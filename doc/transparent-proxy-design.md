# Transparent Proxy Design

`setline` is a local path router and transparent HTTP proxy. It uses the
request URL only to select a route, then forwards the request to the selected
local backend with minimal interference.

The client explicitly connects to the `setline` listen address, such as
`http://127.0.0.1:8080/...`. Transparency means application-layer passthrough:
headers and bodies are streamed without URL rewriting, proxy identity header
injection, or caching.

## Goals

- Route by request host and URL path prefix with longest-prefix priority.
- Build a path-segment route tree after loading or updating routes, so request
  matching depends on URI depth rather than total route count.
- Keep proxying fast under browser-style concurrent resource loading.
- Preserve request headers and body semantics as much as possible.
- Avoid buffering large request bodies in memory.
- Support Vite-style development traffic, including many module requests,
  conditional requests, chunked responses, and WebSocket upgrades.

## Request Flow

For proxied routes, the server reads only the HTTP request head up to
`\r\n\r\n`. `readHttpHead` then builds an `HttpHead` value and parses the
fields used by the hot path once:

- request method
- request target URL
- request host
- path used for route matching
- WebSocket upgrade headers
- request body framing headers

The request `Host` header is normalized by removing the port and lowercasing
the host name. That value selects a host-specific route tree; if that tree has
no matching path route, the `*` fallback tree is tried. If the exact host has a
matching route but no healthy port, fallback is not used. The proxy then
forwards the request head to the backend without URL rewriting,
`Host` rewriting, `Connection` rewriting, or cache handling.

`setline` does not add `Forwarded` or `X-Forwarded-*` headers. If backend
applications need browser-facing client IP, scheme, host, or port, a front
proxy such as HAProxy should add those headers before traffic reaches setline.
When such headers are already present, setline forwards them unchanged as part
of the original request head. If the browser connects to setline directly, the
backend will see setline as the TCP peer and will not receive extra proxy
identity headers from setline.

If the socket read that found the header boundary also read some request body
bytes, those bytes are immediately forwarded to the backend before the proxy
continues streaming the rest of the body.

The proxy hot path should use the parsed `HttpHead` fields instead of repeatedly
scanning the raw header string. Raw header lookup helpers remain for admin
requests and tests, but they are not part of normal proxy routing or body
framing decisions.

## Request Body

The proxy does not parse request body content.

- `Content-Length`: forward the already buffered bytes, then stream the
  remaining byte count from client to backend.
- `Transfer-Encoding: chunked`: forward the already buffered bytes, then stream
  chunks until the terminating chunk is observed. The chunk parser keeps only
  boundary state and never accumulates the full body.
- no body framing header: do not read a request body.

This keeps POST/PUT/upload requests transparent and avoids loading full request
bodies into memory.

The admin API is the exception: `/__setline` handlers need a JSON body for
runtime route management, so the server completes the request body before
handing it to admin code.

## Response Flow

The response head is read first and forwarded to the client. The proxy then
uses HTTP framing to know when the response is complete:

- `Content-Length`: stream the remaining byte count.
- `Transfer-Encoding: chunked`: stream chunks until the terminating chunk is
  observed using the same small boundary-state tracker.
- `HEAD`, `1xx`, `204`, `304`: treat as no-body responses.
- otherwise: stream until the backend closes the response.

These response-boundary checks are required because local development servers
often keep connections alive. Waiting for backend close on a `Content-Length`,
chunked, or `304` response can leave browser resources pending.

## Connection Lifetime

`setline` supports sequential keep-alive on the client side of the proxy: an
upstream proxy or browser may reuse one TCP connection to `setline` for
multiple HTTP/1.x requests when the previous response has fully completed.

The connection is not reused when the request or response declares
`Connection: close`, when the response body has no explicit boundary, when a
WebSocket upgrade takes over the connection, or when `setline` generates an
admin/error response itself.

HTTP pipelining is intentionally not supported. `setline` processes one request
and its response at a time on each client connection; the next request must wait
until the previous response is complete. This matches common upstream
keep-alive behavior while avoiding cross-request buffering and response-order
complexity.

Backend connections are intentionally not pooled or kept alive. Each proxied
request opens a fresh local TCP connection to the selected backend port and
closes it after the response is relayed. This keeps routing, health retry, and
failure handling simple, and avoids adding shared backend connection state to
the hot path.

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

Runtime route state and port health state are intentionally read without
`synchronized` in production code. Route updates are localhost-only and low
frequency; they build complete replacement route trees before assigning them to
runtime state. Connection limiting is the hot-path mutable counter and remains
implemented with atomics.

## Runtime Routes

Runtime route management is deliberately narrow. It supports four operations:

- add or replace one route
- delete one route
- clear routes for one host
- replace routes for one host

These operations are available under the `__setline` admin namespace and are
accepted only from localhost. Write operations do not require the admin token,
but they must specify the route host. The localhost check uses the TCP peer
address because proxy headers are user-controlled input at this security
boundary.

Route updates rebuild a complete runtime snapshot and then replace the current
state:

1. Read the current route snapshot.
2. Build the next host route set and fresh route trees.
3. Rewrite only the top-level `routes` field in the startup config file.
4. Assign the new routes and route trees to runtime state.
5. Refresh port health state from the new routes.

The proxy request path always reads from the current route tree. It never sees
a half-mutated tree in normal `vibe-core` task scheduling because route trees
are built before assignment and assignment does not perform I/O. If config-file
persistence fails, the current in-memory routes remain active.

Health state is preserved by port. If a port remains referenced after a route
change, its current online/offline state and counters are kept. New ports start
healthy so they can receive traffic before the next health-check cycle.
Ports no longer referenced by any route are removed from the health table.

## Port Selection

When a route has multiple healthy ports, selection is random. The route tree
does not store a round-robin cursor. This avoids mutating routing state for
each request and keeps the request hot path read-oriented apart from normal
connection accounting.

If connecting to a selected port fails before any request bytes are sent, the
current request may try another healthy port from the same route. This retry
uses only request-local state and does not update the shared health table; port
health remains owned by the background health-check loop.

## Shutdown

On event-loop shutdown, `setline` stops the TCP listener and stops the
background health-check task. It intentionally does not keep a global registry
of every active client connection. Such a registry would add synchronization to
the normal connection lifecycle and was judged not worth the cost only to
silence shutdown warnings.

The tradeoff is that pressing Ctrl+C while long-lived or half-open client
connections are active may still produce an eventcore `streamSocket` leak
warning during process exit. This is treated as a shutdown diagnostic, not a
normal proxy-path correctness issue.

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

## External Proxy Integration Decision

`setline` does not generate HAProxy/Nginx configuration and does not push route
updates to external proxies.

The route table inside one setline process is a local-machine view:
`host + path prefix -> 127.0.0.1:<port>`. External proxies usually need a
global service view across multiple machines. For example, `/api/edu` may be
served by the same local port on two or more hosts; one setline instance cannot
know whether another machine also serves that URI prefix, nor can it know the
global balancing, failover, TLS, ACL, or rollout policy.

Keep the boundary simple:

- setline manages routing from its own listen address to local backend ports.
- HAProxy/Nginx or other edge proxies manage cross-machine routing and global
  entry policies.
- Any external proxy configuration should be owned by deployment tooling that
  has the complete service topology, not by a single setline instance.
