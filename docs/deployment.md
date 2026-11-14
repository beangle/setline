# Deployment Notes

setline is a user-space full HTTP proxy. Each browser request can hold one
client-side TCP connection and one upstream TCP connection, so deployment limits
must leave enough room for both sides of the proxy.

## Build

Use a release build for load testing or long-running deployment:

```bash
dub build --compiler=ldc2 --build=release
```

Optionally strip the binary after building:

```bash
strip target/setline
```

## Linux Packages

Native Linux package scripts live in `scripts/`:

```bash
scripts/build_deb.sh
scripts/build_rpm.sh
scripts/build_srpm.sh
```

The binary package installs:

- `/usr/bin/setline`
- `/usr/share/setline/setline.json.default`
- `/usr/share/doc/setline/*.md` (all of `docs/`, plus `CHANGELOG.md`)
- `/usr/lib/systemd/system/setline.service`
- `/etc/setline/setline.json` (created on first install)

When routes change, setline rebuilds the next host route trees, writes the new
`routes` field to disk, and then swaps it into runtime state. Port health
information is preserved for ports that remain referenced by the new route set.
If writing the config file fails, runtime routes are not changed.

## File Descriptors

`maxConnections` counts connected clients, not in-flight requests: a connection
holds its slot from `accept` to `close`, so an idle keep-alive connection and an
open WebSocket tunnel count as well. While a connection is proxying, setline also
holds one upstream connection for it (see "Upstream connection affinity"), and
affinity keeps that connection for the whole client connection. One client
connection therefore costs two descriptors for most of its life:

- browser to setline (the `maxConnections` slot),
- setline to the upstream connection leased to that client connection.

The startup check and the shipped unit use one formula for that:

```text
required open files = 2 * maxConnections + 64
                    = client sockets + upstream sockets + fixed overhead
```

- `2 * maxConnections` — one client socket plus the upstream socket leased to it.
  Affinity makes this the steady state, not just a worst case: a connection that
  has served one request keeps its upstream connection until the front proxy
  closes the client connection.
- `64` — overhead that does not scale with traffic: the data listener and the
  admin listener (`adminListen`), eventcore's epoll/eventfd/timerfd handles, the
  health probes (one connection at a time), and the idle upstream pool that
  recycling leaves behind (at most 32 connections per backend port; the pool
  ceiling is 4..32, see "Upstream connection affinity").

The margin is a flat 64, so a host that spreads traffic over many backend ports
can hold more than 64 idle pool descriptors (up to 32 per port, all idle at the
same time). That is harmless, but the true worst case is
`2 * maxConnections + 64 + 32 * routed_ports`; add that headroom when routing to
many ports. On startup setline compares the formula with `RLIMIT_NOFILE` and
prints a warning when the limit is too low:

```text
Warning: RLIMIT_NOFILE=1024 is below required fd budget 131134
(2*maxConnections+64=65535*2+64); raise systemd LimitNOFILE
```

The default `65535` needs `131134`, which is exactly what the shipped
`setline.service` sets. Raise `LimitNOFILE` whenever `maxConnections` grows.

For an interactive shell:

```bash
ulimit -n 131134
```

For systemd:

```ini
[Service]
LimitNOFILE=131134
```

Check the running process:

```bash
cat /proc/$(pidof setline)/limits | grep "open files"
```

### Multiple Processes

Set `"reusePort": true` only when several setline processes intentionally listen
on the exact same address. This maps to Linux `SO_REUSEPORT`; each process still
owns its route table, health state, connection pool, and admin endpoint. Keep
their route configuration synchronized, and do not enable it merely to make a
single process use more than one CPU: verify request throughput across one and
four instances before treating it as a scaling deployment:

```bash
SETLINE_INSTANCES=1 scripts/bench.sh    # baseline: one instance
SETLINE_INSTANCES=4 scripts/bench.sh    # four instances on the same port
```

Measured on a 16-core machine (single-threaded `ab`, `-n 40000`, TIME_WAIT
drained first): one instance saturates a core at ~20k RPS, four instances reach
~65k RPS at `-c 64`/`-c 128` (3.3x) with per-request CPU unchanged (40 -> 48us)
and each instance only ~76% busy. The remaining gap to 4x is the client and the
loopback softirq, not setline.

At `-c 64` on one instance the same machine now measures ~23k RPS (direct) and
~22k RPS behind haproxy (previously ~18k, when an upstream connection was
recycled every few requests). Upstream connection churn dropped from ~10% of
requests to one connection per client connection, and the `TIME_WAIT` delta over
a 20k-request run went from ~2000 to 0.

## TCP Listen Queues

Increase kernel listen queue limits so bursts of browser resource requests do
not overflow before setline accepts them:

```bash
sudo sysctl -w net.core.somaxconn=4096
sudo sysctl -w net.ipv4.tcp_max_syn_backlog=4096
sudo sysctl -w net.ipv4.ip_local_port_range="10240 65535"
```

To persist the values, place them in `/etc/sysctl.d/90-setline.conf`:

```conf
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.ip_local_port_range = 10240 65535
```

`ip_local_port_range` matters because every connection setline opens to a backend
consumes an ephemeral port on this host. The default range (`32768 60999`, about
28k ports) is shared with everything else on the machine, and a port closed by
setline stays in `TIME_WAIT` for 60s. Wide range plus `tcp_tw_reuse` (2 on
recent kernels, i.e. allowed for loopback) gives churn a lot more headroom:

```bash
ss -tan state time-wait | wc -l    # watch this before/after a load test
```

Then reload:

```bash
sudo sysctl --system
```

vibe-core does not currently expose a per-listener backlog parameter through the
`listenTCP` API used by setline, so these kernel limits are the deploy-time knob
for the accept queue.

## Ephemeral Ports

setline opens outbound TCP connections to local backends. With many short
requests, the local ephemeral port range can become a limit before CPU does.

How fast the range is consumed depends on how often connections are *closed*,
not on request count: setline reuses one upstream connection per client
connection (see "Upstream connection affinity"), so ports are consumed at the
rate client connections come and go. Before that change an upstream connection
was recycled every few requests, which put roughly one `TIME_WAIT` per request on
this host.

Recommended range:

```bash
sudo sysctl -w net.ipv4.ip_local_port_range="10000 65535"
```

Persistent config:

```conf
net.ipv4.ip_local_port_range = 10000 65535
```

Useful checks:

```bash
ss -tan state time-wait | wc -l
ss -tan '( sport >= :10000 )' | wc -l
```

Benchmark only after `TIME_WAIT` has drained. The range holds ~55k ports and each
residue lasts 60s, so a run started too early measures port exhaustion instead of
throughput: one session reported 17k RPS at 211us per request for four instances
until the sockets cleared, and 65k RPS at 48us afterwards.

## What Not To Tune First

Do not start with DSR, TPROXY, TCP splicing, or broad TCP buffer changes for the
normal setline workload. The project routes by HTTP URL, so it must read HTTP
heads even though it does not rewrite request paths or add proxy identity
headers. The first practical bottlenecks are usually file descriptors, backend
connect timeout, listen queue limits, and short-lived upstream connections.

The normal proxy path reads the HTTP head once, parses the fields it needs into
`HttpHead`, and then streams request and response bodies. Chunked bodies are
tracked by boundary state only, not buffered as full body strings. Route lookup
and health reads avoid production `synchronized`; active-connection limiting is
handled with atomics.

## Shutdown Notes

On `SIGTERM`/`SIGINT` setline stops listening immediately, waits for requests
that are already being processed to finish, and then exits with status 0. A
second signal skips the wait; `TimeoutStopSec` in the unit is the last resort.
Idle keep-alive connections and WebSocket tunnels are not waited for — they are
long-lived by nature and are dropped when the process exits.

It does not track every active client connection for shutdown cleanup, because
that would add synchronization to the normal connection lifecycle, and holding
`TCPConnection` copies in a registry defers eventcore handle release to process
exit (an fd leak, not a fix).

Because the drain waits for real requests, a restart under load can take as
long as the slowest in-flight request. Size `TimeoutStopSec` above
`readTimeoutMillis` so a request that is about to time out can still be
answered with `504` before systemd force-kills the process.
