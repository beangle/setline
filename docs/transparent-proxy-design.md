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

The admin API is the exception: `/_setline` handlers need a JSON body for
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

Backend connections are handed out per client connection, not per request. A
client connection gets one dedicated upstream connection and keeps it for the
requests that follow, as long as they still route to the same backend port; the
front proxy already serializes requests on a connection, so this is the same
granularity it works at. Keeping the connection is conditional: the response
body boundary must be complete, both HTTP versions and `Connection` headers must
permit reuse, and a closed/EOF check runs before the next request goes out.

Connections left over when a client connection goes away go back into a small
per-port idle pool rather than being closed immediately; the pool is sized from
recent concurrency (4..32 per port) and expires idle entries. That keeps
connection churn proportional to client-connection turnover instead of request
rate, which matters because every closed upstream connection parks an ephemeral
port of this host in `TIME_WAIT` (see `docs/roadmap.md` P1-7).

## WebSocket

WebSocket requests are detected from the request head. The proxy forwards the
original upgrade request head, forwards any already buffered bytes, waits for
the backend handshake response, and then tunnels both directions.

`vibe-core` fibers are used for the tunnel directions, avoiding one OS thread
per long-lived connection.

The tunnel itself is byte-transparent: frame layout, masking and ping/pong stay
the backend's business. Two details are worth knowing:

- The handshake is passed through, not generated. HAProxy validates it (a valid
  `Sec-WebSocket-Key` in the request, a matching `Sec-WebSocket-Accept` in the
  101), so a backend that hand-rolls a fake 101 shows up as a `502` from the
  front proxy rather than any setline error.
- `webSocketIdleTimeoutMillis` (default `0`, disabled) closes a tunnel only when
  **both** directions have been silent for that long. A direction that has been
  quiet is re-checked against the other direction's last activity before any
  close, so a server-push-only stream is not mistaken for an idle connection.

Once the 101 is sent, the connection is no longer counted as an in-flight
request: it is a long-lived tube, so a graceful shutdown stops listening and
drains real requests without waiting for tunnels to end. Active tunnels are
visible as `activeWebSockets` in `status.json` and are dropped when the process
exits.

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

These operations are available under the `_setline` admin namespace and are
accepted only from localhost. Write operations carry no credential, but they
must specify the route host. The localhost check uses the TCP peer address
because proxy headers are user-controlled input at this security boundary.

Read operations (`GET` routes and the status page) sit on the other side of the
boundary: they stay reachable from other hosts, because the route table is read
by same-network peers - the agent that renders `agent.peers` into a haproxy or
nginx config. Their gate is the source address (localhost, or an address listed
in `peerReaders`), so setline holds no credential at all.

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

`setline` installs its own SIGTERM/SIGINT handlers instead of letting
`vibe-core` end the event loop directly. The handler only bumps an atomic
counter; a drain task polls it, stops the listener, waits until
`activeRequests` reaches zero, and then exits the event loop. A second signal
skips the wait, and `TimeoutStopSec` remains the last resort. SIGPIPE is set
back to `SIG_IGN` because `disableDefaultSignalHandlers()` removed the
`vibe-core` handler that used to absorb it.

Only requests still being processed are waited for. An idle keep-alive
connection is not one, and neither is a WebSocket tunnel once the 101 is sent:
tunnels are long-lived by nature, so `activeWebSockets` tracks them and the
process exit drops them.

It intentionally does not keep a global registry of every active client
connection. Such a registry would add synchronization to the normal connection
lifecycle and, worse, its stored copies keep eventcore handles alive until
process exit, which leaks file descriptors instead of saving them.

One shutdown trap is worth recording: the listener must be stopped exactly
once. `TCPListener` copies carry their own `m_socket`, so letting both the drain
task and the post-loop cleanup call `stopListening()` releases the same
eventcore handle twice and dereferences freed `userData` (SIGSEGV, exit 139).
The drain task now holds a pointer to the single listener owned by `serve()`
and invalidates it for everyone.

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

Normal `setline` proxy mode does not generate HAProxy/Nginx configuration and
does not push route updates to external proxies.

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

When `agent.type` is configured, `setline -f` is a separate agent-style helper
for that deployment tooling boundary. It renders proxy configuration text for
an edge proxy machine, without touching the normal local transparent proxy route
model.

The helper reads live peers: `agent.peers` lists remote setline instances, and
`setline -f` aggregates their `GET /_setline/routes` tables into one HAProxy or
Nginx fragment. With no `peers` it renders the local route table instead. This
is a rendered fragment, not a full config, so the edge proxy keeps owning its
own `global`/`defaults`/`http` content.
