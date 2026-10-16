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
- `/usr/share/setline/{setline.json.default,apply.conf.example,haproxy-setline-cfgdir.conf.example}`
- `/usr/share/doc/setline/*.md` (all of `docs/`, plus `CHANGELOG.md`)
- `/usr/lib/setline/setline-apply` (fragment validate/reload helper)
- `/usr/lib/systemd/system/setline.service`
- `/usr/lib/systemd/system/setline-render.service` + `setline-render.timer`
- `/usr/lib/systemd/system/setline-apply.service` + `setline-apply.timer`
- `/etc/setline/setline.json`

`scripts/build_srpm.sh` produces the same package from source on the target
host: the binary and source specs share the file list and the scriptlets
(`scripts/package/setline.spec.common`), so `rpmbuild --rebuild setline-*.src.rpm`
does not quietly give you a package with fewer files. The generated specs only
use section names at the start of a line, which is what older `rpmbuild` (the
rpm 4.11 on CentOS 7) needs.

The packages install the units but never enable them. A machine whose config
has an `agent` block needs

```bash
sudo systemctl enable --now setline-apply.timer  # validate + reload when fragments change
```

otherwise the generated fragment is never validated or reloaded. How to run it
by hand, its exit codes and the `/etc/setline/apply.conf` overrides are in
`docs/agent-reload.md`. A pure render machine (`agent.peers`, no `listen`) drives rendering with `setline-render.timer` instead of a resident
process: the timer re-runs `setline-render.service` every 30s, because one run
renders one round and exits. A single-host deployment (`listen` set) is the
opposite - it keeps `setline.service` resident (`sudo systemctl enable --now
setline.service`) and re-renders on every route change, so do **not** enable
`setline-render.timer` there: two renderers writing the same files are
redundant.

The systemd service runs:

```text
/usr/bin/setline -f /etc/setline/setline.json
```

`setline-render.service` runs the same command as `setline` (the unprivileged
user) and exits after one round; drop a
`/etc/systemd/system/setline-render.service.d/*.conf` with an `ExecStart=`
override if the config lives elsewhere.

Runtime route updates rewrite the configured JSON file, so package install
scripts make `/etc/setline/setline.json` writable by the `setline` service user.
The config file is generated on first install and is not tracked as a package
file, so removing the package preserves `/etc/setline/setline.json`.

### systemd 版本兼容

unit 里的启动限流写成 `[Service]` 段的旧拼写 `StartLimitInterval=` / `StartLimitBurst=`
（没有 `Sec` 后缀），这是为了同时兼容两端：

- CentOS 7 / RHEL 7 带的是 systemd 219，只认这种写法；`StartLimitIntervalSec=`（`[Unit]`
  段）是 systemd 229 才加的，219 上会打
  `Unknown lvalue 'StartLimitIntervalSec' in section 'Service'` 并把它忽略掉；
- 旧拼写在 systemd ≥ 229 里**依然生效**（`systemctl show -p StartLimitIntervalUSec <unit>`
  能读到配置值，只是不再写进 `systemd.service(5)`），不产生告警。

所以一份 unit 在 219 和 259 上都不报警、限流都真的生效。unit 里其余设置的最低版本都在
219 之前（`RestartPreventExitStatus=` 189、`AccuracySec=` 197、`OnUnitInactiveSec=` 212，
`StartLimitIntervalSec=` 229 是唯一越界的），没有别的 CentOS 7 兼容问题。

不过 haproxy 这一侧有独立的最低版本要求：**HAProxy ≥ 2.0**（`-f <目录>` 从 1.7 起才有，
本项目基线取 2.0；片段只用 2.0 起就有的老指令，已在 2.0.33、2.2.9、3.0.25
实测）。CentOS 7 自带的 **1.5.18 低于这个门槛**（它不认 `-f <目录>`，CentOS 7 也没有
`/etc/haproxy/conf.d`），要在这类机器上用 haproxy 集成得先升级，或换用 nginx。版本门槛
和替代方案见 `docs/haproxy-integration.md` 的「版本要求」。nginx 集成不受影响（接线自检
用 `nginx -T`，那是 nginx 1.9.3 就有的开关，CentOS 7 能装到的 nginx 都满足）。

### 启动即失败（status=1）怎么查

`systemctl status`/`journalctl` 里那几行 `main process exited, code=exited,
status=1/FAILURE`、`start request repeated too quickly` 都不是原因：前者是 systemd 对
**退出码**的转述，后者只是重启限流挡下了第 6 次尝试。真正的原因在进程自己写进 journal 的
**上一行** stderr 里，`-o cat` 可以滤掉 systemd 的 `-- Subject:` 样板：

```bash
journalctl -u setline -b -o cat | tail -20
systemctl status setline -l --no-pager        # 也会带出最后几行 stderr
```

那行只有两种形态：

1. `Config /etc/setline/setline.json is invalid: <原因>` —— JSON 语法或字段问题（未知字段、
   `routes` 结构不对、写了已取消的字段……）。用 `-c` 单独校验，
   不需要起服务、不需要 root：

   ```bash
   setline -c -f /etc/setline/setline.json
   ```

2. 监听失败也走同一个 catch-all，所以端口被占、无权限绑低端口会伪装成
   `Config ... is invalid: <bind 的错误>`。`listen` 写 `*:8080` 时先看端口是不是被占了
   （`ss -ltnp | grep 8080`）；要绑 1024 以下端口用
   `AmbientCapabilities=CAP_NET_BIND_SERVICE`——**不要**为了绑低端口让服务以
   root 运行（硬性要求，见 `docs/project-constraints.md` 的 Privilege Model）。

3. `refusing to run as root: ...` —— 手工 `sudo setline -f ...` 起服务时最常见。代理和
   渲染 agent 都要求非 root；`setline-apply` 以 root 调用的 `--agent-type`/`--sync-map`
   两个出口、以及 `-c` 校验不受影响。这条以退出码 `2` 结束，unit 里的
   `RestartPreventExitStatus=2` 会直接停住，不会重启五次。

前台手工复现最直接，注意用服务账号，才和 unit 里的权限一致：

```bash
sudo -u setline /usr/bin/setline -f /etc/setline/setline.json
```

修好之后必须清掉限流计数，否则 systemd 还在「repeated too quickly」状态里拒绝启动：

```bash
sudo systemctl reset-failed setline && sudo systemctl start setline
```

注意 setline 对配置与监听类失败统一返回 `1`，所以 unit 里的
`RestartPreventExitStatus=2` 挡不住它们，只会重启 5 次后停在 failed —— 看到的就是上面
那串日志。唯一的 `2` 是第 3 条（以 root 运行）：那是重启也没用的失败，本就不该重试。

如果 journal 里出现的是 `error while loading shared libraries` 或 `GLIBC_2.xx not found`，
那是二进制与发行版不匹配（例如在 Fedora 上打的包拿到 CentOS 7 上装），跟配置无关。

## Application Config

Use `connectTimeoutMillis` to limit how long setline waits when opening a TCP
connection to a backend:

```json
{
  "listen": "127.0.0.1:8080",
  "connectTimeoutMillis": 3000,
  "readTimeoutMillis": 15000,
  "maxConnections": 65535
}
```

A shorter timeout prevents an unavailable backend from occupying too many
vibe-core tasks and file descriptors. For local development backends, 1000-3000
ms is usually enough. For slower startup or remote-like test environments, use a
larger value.

`readTimeoutMillis` protects the segment setline cannot otherwise recover on its
own: a local backend that accepts the connection and then stops producing the
next response byte. Before the final response begins, timeout is reported as
`504` and both connections are recycled. After response bytes have been sent,
setline can only recycle the connection because the client already received the
start of a response.

`maxConnections` limits concurrent client connections. The default is
intentionally large so most deployments do not need to change it; it acts as a
last-resort fuse to prevent the process from exhausting file descriptors or
memory under abnormal load. When the limit is reached, setline returns
`503 Service Unavailable` before reading the proxied request. It counts
connections, not requests: a connection keeps its slot from `accept` to `close`,
so an idle keep-alive connection counts too.

Each of those connections also holds one upstream socket for most of its life,
so the process needs open files according to:

```text
required open files = 2 * maxConnections + 64
```

The two terms, what the fixed 64 covers, and how to raise the limit for a shell
or a systemd unit are in "File Descriptors" below.

### Upstream connection affinity

setline gives every client connection one dedicated upstream connection and keeps
it across the requests on that connection, as long as the request still routes to
the same backend port. The front proxy already serializes requests on a connection
(`http-reuse` in haproxy), so this is the same granularity the proxy works at.

Why not a shared pool sized to fit: the pool only helps when its capacity is at
least the concurrency, and every connection the pool drops is a connection
setline has to open again on the next request. Those closed connections leave a
`TIME_WAIT` entry on this host, so churn scales with request rate and can eat the
ephemeral port range under load. With affinity, steady state is "one upstream
connection per client connection, created once": closing happens when the client
connection goes away, which is the rate the front proxy chooses, not the request
rate. A small pool still sits behind it as a recycling bin for connections left
over from closed client connections, sized from recent concurrency (4..32 per
port). A dedicated janitor task trims that pool once a second and lets the
capacity follow real time — the high-water mark halves after every 30s without a
new peak — so pool behaviour does not depend on `healthCheck.intervalMillis`,
which only controls how often backends are probed.

`upstreamIdleTimeoutMillis` (default 30s) bounds how long a connection may sit
idle. A client connection that stops sending requests releases its upstream
connection back to the pool; the pool itself expires idle connections on the same
timeout.

### The admin plane

The admin API is split across the two listeners. The data plane (`listen`)
serves exactly one endpoint, `GET /_setline/routes`; the status page,
`status.json` and every write live only on `adminListen` (`127.0.0.1:8081` by
default, so writes stay a local operation). The recommended production shape
keeps the data plane on loopback and leaves the admin listener alone:

```json
{
  "listen": "127.0.0.1:8080",
  "adminListen": "127.0.0.1:8081",
  "peerReaders": ["10.0.1.7"]
}
```

`listen` is where the front proxy sends traffic, so it never needs to leave the
machine - and because it also carries the peer protocol read (`GET
/_setline/routes`), "who can reach the proxy" matters for the route table too.
That read is open to anything that reaches `listen` from loopback (including
requests a front proxy forwards), and to the addresses listed in `peerReaders`;
keep the front proxy rejecting `/_setline`, list only the machines that render
this setline's routes, or point the proxy only at the application backends.

`adminListen` is what tools and collectors may also connect to; it serves the
whole `/_setline/*` API (everything else is `404`) and does not route to
backends. It carries the writes, which still require a local caller, so the
default `127.0.0.1:8081` keeps route changes a purely local operation. It is
also the only door for the status page and `status.json`: those describe the
listener, timeouts, health-check tuning and counters, have no cross-machine
consumer, and would only widen what a leaked `/_setline` exposes. Bind it to `*`
only when a collector cannot go through the proxy.

Writes require a loopback TCP peer *and* a loopback request host, so a local
proxy relaying a remote request (`remote client -> haproxy/nginx -> setline`)
cannot change routes: it gets `403`. A proxy can rewrite `Host` to evade that, so
keep denying the admin path at the proxy itself (`http-request deny if { path_beg
/_setline }`, `location ^~ /_setline { return 404; }`). Reads do not look at the
host - a local caller may address setline by its public name - which is why that
proxy-side deny is the read side's only protection.

Tools work against either door: basctl writes (so `adminListen`), and the peer
protocol reads the route table on `listen`. Sending a write to `listen` gets a
`404` - the admin listener is the only place where routes can be changed - and
so does a status read, which only `adminListen` serves.

Startup still validates the address pair: `adminListen` may not duplicate
`listen` (including `*:port` versus a concrete address on the same port), and
`"adminListen": false` is rejected — it no longer means "share `listen`". A
`"listen": false` deployment must not set `adminListen` at all, and a `listen`
that would land on 8081 without an explicit `adminListen` is rejected too.

## Runtime Route Updates

Route updates through the admin API update memory and rewrite the top-level
`routes` field in the configured JSON file. On restart, setline keeps the last
runtime route changes because they have already been written to that file.

Supported runtime operations are:

- add or replace one route
- delete one route
- clear routes for one host
- replace routes for one host

All route-changing calls must come from localhost and must specify the target
route host. There is no credential: the localhost check is the whole access
control for writes. Keep these endpoints bound to trusted local automation such
as service startup scripts or deployment hooks.

Reads take a different path: their gate is the source address (localhost, or an
address listed in `peerReaders`), and `GET /_setline/routes` is served on
`listen` as well as on `adminListen`, so a peer can read the route table without
knowing the admin listener. The status page and `status.json` live on
`adminListen` alone. Because the route table read rides the data plane, keep
`/_setline` denied at the proxy (a rule matching just `/_setline/routes` is
enough) or keep `listen` on loopback.

That read path is what `agent.peers` uses: an edge proxy machine reads each
peer's route table (no credential - the peer's `peerReaders` lists the edge),
rewrites the peer's local ports to
`<peer url host>:<port>`, merges routes that share a host and path prefix, and writes
a HAProxy/Nginx fragment under the `agent.output` root directory
(`<root>/{haproxy,nginx}/setline.{cfg,conf}`). Leave `agent.peers` empty and the
same output is rendered from the local route table instead. By default the
fragment carries only rules and backends, so the proxy's own config keeps
the listener; how to wire each proxy is in `docs/haproxy-integration.md` and
`docs/nginx-integration.md`.

Reloading is separate and privileged. `setline` runs as the unprivileged
`setline` user and only writes the fragment; `setline-apply` (root, oneshot,
timer-driven) validates it, runs `systemctl reload`, and rolls the fragment
directory back if either step fails. Running the daemon as root is a hard
requirement to avoid, not a tuning choice: see the Privilege Model in
`docs/project-constraints.md`. See `docs/agent-reload.md` for the reload flow.

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
  health probes (one connection at a time), the `--sync-map` admin socket, and
  the idle upstream pool that recycling leaves behind (at most 32 connections per
  backend port; the pool ceiling is 4..32, see "Upstream connection affinity").

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
