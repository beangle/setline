# Project Constraints

This document records the constraints that keep `setline` small, fast, and
predictable.

## Product Scope

- Linux only.
- Backends are local only; listeners default to loopback but may explicitly bind
  all IPv4 addresses with `*:port`.
- HTTP/1.x path-prefix routing.
- Local HTTP backends only, configured by port number.
- Longest-prefix route matching.
- Optional random selection across local backends.
- Runtime route management through the local admin API.
- Clients explicitly access the `setline` listen address.

## Transparent Proxy Boundary

For normal backend routes, `setline` is a transparent path router:

- Do route matching from the request URL path.
- Forward the original request head.
- Do not rewrite URLs.
- Do not strip or add path prefixes.
- Do not rewrite `Host`.
- Do not rewrite `Connection`.
- Preserve existing proxy headers from a trusted upstream, such as HAProxy.
- Add proxy headers when no upstream proxy identity is present.
- Do not cache.
- Do not inspect request body content.
- Do not buffer full request bodies.
- Do not implement application-level request or response transformations.

Only HTTP framing is interpreted, so the proxy knows when to stop streaming a
request or response.

Backends see `setline` as their TCP peer. Original browser-facing client IP,
scheme, host, and port are communicated through `Forwarded` and
`X-Forwarded-*` headers. Existing trusted upstream values are preserved; direct
browser-to-setline requests are annotated by `setline`.

## Unsupported Features

These are intentionally out of scope unless the project goal changes:

- `stripPrefix`
- URL rewrite rules
- reverse-proxy header rewriting
- response caching
- direct local responses
- compression/decompression
- TLS termination
- non-local backends
- weighted load balancing
- generic middleware chains
- full HTTP framework behavior
- Linux TPROXY or other kernel traffic interception

## Implementation Constraints

- Keep the route model simple: prefix plus exactly one action.
- Keep route configuration as `path prefix -> port or ports`; backend host is
  fixed to `127.0.0.1`.
- Normalize route prefixes at input boundaries. Except for root `/`, trailing
  slashes are removed so `/m/edu/learning/` and `/m/edu/learning` identify the
  same route.
- Keep route lookup indexed by URI path segment instead of scanning every route
  for each request.
- Runtime route changes must build the next route set and route tree first,
  then swap them into state once. Request routing should never observe a
  partially changed route table.
- Prefer `vibe-core` TCP streams and fibers for proxy traffic.
- Keep protocol helpers in the existing `http`, `proxy`, and `server` modules
  unless a real boundary appears.
- Add abstractions only when they remove real duplication or isolate a real
  protocol rule.
- Preserve admin API behavior, but do not let admin needs force normal proxy
  traffic to buffer request bodies.
- Do not add kernel-level transparent proxying for the current explicit-proxy
  deployment model.
- Do not overwrite existing `Forwarded` or `X-Forwarded-For` values. Their
  presence means upstream proxy identity has already been established.
- Do not track every active client connection just to silence Ctrl+C shutdown
  warnings. Avoid adding hot-path global synchronization unless it protects
  normal proxy correctness.

## Runtime Route Management

The admin API can update the runtime route table:

- add or replace a single route
- delete a single route
- clear all routes
- replace all routes

Runtime route changes write the top-level `routes` field back to the startup
config file by default. They never change listener, token, timeout,
health-check, or connection-limit settings.

All route-changing requests must come from localhost and must still pass the
admin token check. The localhost decision is based on the TCP peer address, not
on `Forwarded` or `X-Forwarded-*` headers.

The new routes are written to disk before the in-memory route table is swapped.
If persistence fails, the existing runtime routes remain active.

Health state is synchronized after successful route changes. Existing backend
ports keep their current health counters and online/offline state; newly
introduced ports start healthy; ports that are no longer referenced by any
route are removed from the health table.

## Technology Selection

Use `vibe-core` for user-space TCP concurrency and stream I/O. It matches the
project goal: a fast local HTTP path router that users access directly through
the configured listen address.

Do not introduce Linux TPROXY for the current project scope. The reasons are:

- The user-facing model is explicit proxy access, not hidden traffic
  interception.
- TPROXY operates at IP/port level and cannot route by HTTP URL path.
- URL path routing still requires reading the HTTP request head in user space.
- TPROXY requires root or `CAP_NET_ADMIN`, packet-mark rules, policy routing,
  and local route configuration.
- It would increase deployment and debugging complexity without improving the
  current Vite/local-backend proxy workload.

Reconsider TPROXY only if the product goal changes to system-level transparent
interception where clients no longer connect to the `setline` listen address
directly.

## Compatibility Requirements

The proxy must keep working for common development-server traffic:

- many concurrent module requests
- Vite HMR WebSocket upgrades
- `Content-Length` responses over keep-alive
- chunked responses over keep-alive
- browser conditional requests returning `304`
- large `Content-Length` request bodies
- chunked request bodies

Before changing proxy behavior, validate at least:

- `dub build`
- `dub test --config=unittest`
- concurrent frontend resource requests
- concurrent `304` conditional requests
- WebSocket echo through the proxy
- `Content-Length` and chunked request-body passthrough
