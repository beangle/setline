# Project Constraints

This document records the constraints that keep `setline` small, fast, and
predictable.

## Product Scope

- Linux only.
- Backends are local only; listeners default to loopback but may explicitly bind
  all IPv4 addresses with `*:port`.
- HTTP/1.x host-scoped path-prefix routing.
- Sequential keep-alive from an upstream proxy or browser to `setline`.
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
- Do not add `Forwarded` or `X-Forwarded-*` headers.
- Do not cache.
- Do not inspect request body content.
- Do not buffer full request bodies.
- Do not implement application-level request or response transformations.

Only HTTP framing is interpreted, so the proxy knows when to stop streaming a
request or response.

Backends see `setline` as their TCP peer. If applications need original
browser-facing client IP, scheme, host, or port, an upstream proxy such as
HAProxy must add `Forwarded` or `X-Forwarded-*` before traffic reaches setline.
Direct browser-to-setline requests are not annotated by setline.

Positioning: `setline` is never the first hop. It either renders fragments for
an edge proxy, or serves as that edge proxy's subordinate. The subordinate shape
has two prerequisites: the data-plane `listen` binds loopback only, and the
front proxy denies `/_setline` (at least `/_setline/routes`). Reads are admitted
by source address, and a relayed request arrives from loopback, so without that
`deny` any client of the front proxy can read the route table. Binding `listen`
to `*` publishes the data plane past the front proxy and voids every assumption
above.

This file is the authoritative statement of that boundary. A short version of
it also belongs in `README.md`, `docs/configuration.md`,
`docs/haproxy-integration.md` and `docs/nginx-integration.md`.

## Unsupported Features

These are intentionally out of scope unless the project goal changes:

- URL/path rewriting
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
- HTTP pipelining
- HTTP/2, HTTP/3, h2c
- client-side timeouts, slowloris/slow-request protection, connection shedding
- authentication, authorization, rate limiting, WAF
- access logging: only the front proxy sees the whole request, so setline keeps
  no access log of its own and reports per-port counters instead
- unix-socket backends
- scheduling algorithms beyond random port selection: no weighted, consistent
  hash or sticky sessions

## Privilege Model

- `setline` must not run as root. This is a hard requirement, not a deployment
  preference: the daemon is the network-facing data plane. It accepts arbitrary
  client HTTP, parses request heads, and tunnels WebSocket frames, so running it
  as root would turn any bug on that path into a root compromise.
- The daemon enforces that itself: starting the proxy or the render agent with
  effective uid 0 prints a refusal and exits with code 2, which the shipped unit
  maps to `RestartPreventExitStatus=2` so systemd does not loop. `setline-apply`
  is not gated, and neither are the exits it invokes as root
  (`setline --agent-type`, `setline --sync-map`) or `-c` and `--help`.
- Privileged work belongs only to `setline-apply`, the short-lived root oneshot:
  validating fragments, running `systemctl reload`, rolling the fragment
  directory back, and talking to a proxy admin socket.
- The shipped `setline.service` enforces the split with `User=setline` and
  `Group=beangle`. Do not remove those lines, and do not add a replacement unit
  or a manual command that starts `setline` as root.
- `setline` needs write access only to its own fragment directory
  (`/var/lib/setline/<proxy>/`), never to `/etc/haproxy` or `/etc/nginx`.
- Needing a port below 1024 is not a reason to run as root. Use
  `AmbientCapabilities=CAP_NET_BIND_SERVICE` on the unit instead.
- If a feature seems to need root, implement it in `setline-apply` (or in a
  helper that `setline-apply` runs as root) rather than raising the daemon's
  privileges.
- Shipped binaries are linked with full RELRO: `dub.json` passes `-z now` as
  `lflags`, so the GOT is resolved at load time and made read-only and a
  GOT-overwrite bug on the request path cannot be turned into a write primitive.
  The Debian and Arch builds come out as PIE as well; the Fedora-built rpms do
  not, because LDC on Fedora links non-PIE by default (`-pie` alone fails against
  gcc's `crtbegin.o`). That gap is known and is not a deployment blocker - it
  only widens the ASLR coverage of the daemon, and closing it needs a different
  link path, not a flag.

## Implementation Constraints

- Keep the route model simple: prefix plus exactly one action.
- Keep route configuration as `host -> path prefix -> port or ports`. Route
  ports map directly to `127.0.0.1:<port>`; do not add a backend URL model.
- Route hosts do not include a port. Host `*` is allowed only as a fallback
  namespace, not as a bulk operation over all hosts.
- Normalize route prefixes at input boundaries. Except for root `/`, trailing
  slashes are removed so `/m/edu/learning/` and `/m/edu/learning` identify the
  same route.
- Keep route lookup indexed by URI path segment instead of scanning every route
  for each request.
- Parse the HTTP head once into `HttpHead` and use its fields on the proxy hot
  path. Do not repeatedly scan raw header strings for host, body framing,
  WebSocket, or response status decisions.
- Keep request and response bodies streaming. For chunked bodies, track only
  chunk boundaries and do not accumulate full body content.
- Support sequential keep-alive on both sides of the proxy. Each client
  connection keeps one upstream connection for its own requests (port
  affinity), with a small per-port idle pool behind it as the recycling bin;
  discard connections whenever framing or connection headers make reuse unsafe
  and expire idle ones.
- Do not support HTTP pipelining. A reused client connection must send the next
  request only after the previous response has completed.
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
- Do not let normal proxy mode generate or synchronize external proxy
  configuration. In normal proxy mode, setline only knows this machine's local
  route-to-port view.
- Do not synthesize proxy identity headers. Existing proxy headers pass through
  only because the request head is otherwise forwarded unchanged.
- Do not track every active client connection just to silence Ctrl+C shutdown
  warnings. Avoid adding hot-path global synchronization unless it protects
  normal proxy correctness; storing `TCPConnection` copies globally also keeps
  eventcore handles alive until process exit, which leaks fds.
- Do not use production `synchronized` around route lookup, health reads, or
  route persistence. Only active-connection accounting currently needs hot-path
  atomic mutation.

## Runtime Route Management

The admin API can update the runtime route table:

- add or replace a single route
- delete a single route
- clear routes for a single host
- replace routes for a single host

Runtime route changes write the top-level `routes` field back to the startup
config file by default. They never change listener, peer-reader, timeout,
health-check, or connection-limit settings.

All route-changing requests must come from the local machine and must specify
the target host. There is no credential anywhere in setline: writes are gated by
the local check, because a route change redirects traffic, and they are served by
`adminListen` only, which defaults to loopback - so the strongest guarantee is
the bind, not the check. Reads are gated by source address (localhost, or an
address listed in `peerReaders`) and are split across the two listeners: `GET
/_setline/routes` rides both `listen` and `adminListen`, because it is the
endpoint consumed from other hosts, by the agent that renders `[agent] peers` into
a proxy config; the status page and `status.json` stay on `adminListen` alone.

"Local" requires two things: a loopback TCP peer address (`127.0.0.1` / `::1` /
`::ffff:127.0.0.1`) and a loopback request host (`Host` or `X-Forwarded-Host`
naming `127.0.0.1`, `::1`, or `localhost`, port ignored). Requests without a
`Host` are never local. Consequences that are part of the contract and must stay
documented:

- The host dimension covers writes only, and it exists because of local proxies:
  in `remote client -> local haproxy/nginx -> setline` the forwarded request
  carries the browser's public host name, so the route table can no longer be
  rewritten (it was, before this was added: relaying `PUT /_setline/routes`
  through haproxy returned `200` and persisted the route, which is covered by an
  e2e case now). Reads do not use it: a local caller may legitimately address
  setline by its public name, and the read path carries the route table rather
  than the ability to change it.
- A proxy that rewrites `Host` can still look local, so this is defense in
  depth, not a boundary. Front proxies must reject `/_setline` themselves
  (`http-request deny if { path_beg /_setline }`, `location ^~ /_setline {
  return 404; }`, or a rule matching just `/_setline/routes`): **the route table
  read is served by `listen`** and reads trust the connection's source address,
  so a request forwarded by a local proxy arrives from loopback and is allowed -
  the proxy's own deny is the only thing standing between its clients and the
  route table.
- The upshot of the split: the peer-protocol read (`GET /_setline/routes`) rides
  the data plane, so its reachability is the proxy's reachability plus the
  `peerReaders` list; everything else - status, `status.json`, writes - lives
  only on `adminListen`, which defaults to `127.0.0.1:8081`. Route changes are
  therefore a local-only operation by default, and the loopback bind - not the
  `Host` heuristic - is what actually enforces it. Keeping the data-plane
  surface to the one endpoint the peer protocol needs is deliberate: the status
  views carry listener addresses, timeouts, counters and the whole route table,
  and have no cross-machine consumer.
- The gate does not distinguish local users, processes, or network namespaces.
  Any process that can open a TCP connection to the listener can change routes,
  so setline must not share a host or netns with untrusted workloads. Route
  changes redirect traffic, which in agent mode also means arbitrary
  `host:port` targets in the rendered proxy fragments.

Reads have no credential: localhost, or an address listed in `peerReaders`. That
list takes address literals only - host names would tie a security decision to
DNS, CIDR would need bitwise matching - and a reader behind NAT or a layer-4
proxy has to list that proxy, which admits everyone behind it. Admin request
bodies are capped by a 4 MiB defensive limit (`413` beyond that); the data plane
never buffers a body, only this control-plane path does.

The new routes are written to disk before the in-memory route table is swapped.
If persistence fails, the existing runtime routes remain active.

Health state is refreshed after successful route changes. Existing backend
ports keep their current health counters and online/offline state; newly
introduced ports start healthy; ports that are no longer referenced by any
route are removed from the health table.

## Remote Proxy Rendering

`[agent] peers` is the discovery form of the same agent-side helper. Each peer is
a remote setline instance read through `GET /_setline/routes`; its local ports
are rewritten to `<peer url host>:<port>`, and routes sharing a host and path prefix
are merged into one backend group so several machines serving the same prefix
become multiple servers of one upstream. The result is rendered as a HAProxy or
Nginx fragment, written atomically under the `[agent] output` root directory
(`<root>/{haproxy,nginx}/setline.{cfg,conf}`), and never merged into the
proxy's own main config file: the fragment is included (Nginx) or concatenated
(HAProxy, which has no `include`) by deployment tooling. The process renders
exactly one round and exits; the cadence is external
(`setline-render.timer` in the package), so there is no in-process scheduler and no
`sync` config.

With no `peers`, the same renderer reads the local route table instead
(single-host deployment, where the proxy and setline share a machine).

The fragment carries only rules and backends and never a listener, because the
listen address, TLS and the rest of the proxy config are the deployment's own
decisions. Wiring recipes: `docs/haproxy-integration.md`,
`docs/nginx-integration.md`.

A registry-bundle source (`agent.remote`, plus its `agent.workDir` scratch
directory) existed for a while and was dropped: it fed the same renderer from a
manifest and versioned `.tar.gz` that an external registry system had to build,
doubling the surface while `[agent] peers` already produced the same fragments
from running instances. Only `peers` and the local route table remain.

This rendering mode may describe remote machine IPs and ports because it is
generating HAProxy/Nginx configuration, not selecting setline backends. It must
stay separate from `routes`, which remain local-port-only for the setline proxy.

The renderer does not own service discovery, liveness, deployment ordering, or
firewall policy. Those decisions stay in the deployment system and in the
target proxy's own health checks.

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
