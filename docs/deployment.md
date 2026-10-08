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
- `/usr/lib/setline/setline-apply` (fragment validate/reload helper)
- `/usr/lib/systemd/system/setline.service`
- `/usr/lib/systemd/system/setline-apply.service` + `setline-apply.timer`
- `/etc/setline/setline.json`

Only `setline.service` is started by the user; the packages install the
`setline-apply` units but never enable them. Machines whose config has an
`agent` block need

```bash
sudo systemctl enable --now setline-apply.timer
```

otherwise the generated fragment is never validated or reloaded. How to run it
by hand, its exit codes and the `/etc/setline/apply.conf` overrides are in
`docs/agent-reload.md`.

The systemd service runs:

```text
/usr/bin/setline -f /etc/setline/setline.json
```

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
本项目基线取 2.0；规则模式和自包含模式在 2.0 以上通用，已在 2.0.33、2.2.9、3.0.25
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
   `agent.peers` 与 `agent.remote` 同时出现、`routes` 结构不对……）。用 `-c` 单独校验，
   不需要起服务、不需要 root：

   ```bash
   setline -c -f /etc/setline/setline.json
   ```

2. 监听失败也走同一个 catch-all，所以端口被占、无权限绑低端口会伪装成
   `Config ... is invalid: <bind 的错误>`。`listen` 写 `*:8080` 时先看端口是不是被占了
   （`ss -ltnp | grep 8080`）；要绑 1024 以下端口得让服务有 root 或
   `AmbientCapabilities=CAP_NET_BIND_SERVICE`。

前台手工复现最直接，注意用服务账号，才和 unit 里的权限一致：

```bash
sudo -u setline /usr/bin/setline -f /etc/setline/setline.json
```

修好之后必须清掉限流计数，否则 systemd 还在「repeated too quickly」状态里拒绝启动：

```bash
sudo systemctl reset-failed setline && sudo systemctl start setline
```

注意目前 setline 对所有启动期失败都返回 `1`，所以 unit 里的 `RestartPreventExitStatus=2`
挡不住配置错误，只会重启 5 次后停在 failed —— 看到的就是上面那串日志。

如果 journal 里出现的是 `error while loading shared libraries` 或 `GLIBC_2.xx not found`，
那是二进制与发行版不匹配（例如在 Fedora 上打的包拿到 CentOS 7 上装），跟配置无关。

## Application Config

Use `connectTimeoutMillis` to limit how long setline waits when opening a TCP
connection to a backend:

```json
{
  "listen": "127.0.0.1:8080",
  "connectTimeoutMillis": 3000,
  "maxConnections": 65535
}
```

A shorter timeout prevents an unavailable backend from occupying too many
vibe-core tasks and file descriptors. For local development backends, 1000-3000
ms is usually enough. For slower startup or remote-like test environments, use a
larger value.

`maxConnections` limits active browser-to-setline connections. The default is
intentionally large so most deployments do not need to change it; it acts as a
last-resort fuse to prevent the process from exhausting file descriptors or
memory under abnormal load. When the limit is reached, setline returns
`503 Service Unavailable` before reading the proxied request.

If you lower `maxConnections`, size the process file descriptor limit for at
least two sockets per proxied request:

```text
required open files >= maxConnections * 2 + backend/process overhead
```

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
route host. They do not require the admin token: the localhost check is the
whole access control for writes. Keep these endpoints bound to trusted local
automation such as service startup scripts or deployment hooks.

Reads take a different path. `GET /__setline/routes` and the status page require
`adminToken` and are not limited to localhost, because same-network services
(for example a haproxy/nginx config synchronization agent) are expected to read
the route table. Set `adminToken` whenever `listen` binds `*`.

That read path is what `agent.peers` uses: an edge proxy machine reads each
peer's route table with `X-Setline-Token`, rewrites the peer's local ports to
`<peer url host>:<port>`, merges routes that share a host and path prefix, and writes
a HAProxy/Nginx fragment to `agent.output`. `agent.remote` is the alternative
source (a registry bundle) and cannot be combined with `agent.peers`. By default
the fragment carries only rules and backends, so the proxy's own config keeps
the listener; how to wire each proxy is in `docs/haproxy-integration.md` and
`docs/nginx-integration.md`.

Reloading is separate and privileged. `setline` runs as the unprivileged
`setline` user and only writes the fragment; `setline-apply` (root, oneshot,
timer-driven) validates it, runs `systemctl reload`, and rolls the fragment
directory back if either step fails. See `docs/agent-reload.md`.

When routes change, setline rebuilds the next host route trees, writes the new
`routes` field to disk, and then swaps it into runtime state. Port health
information is preserved for ports that remain referenced by the new route set.
If writing the config file fails, runtime routes are not changed.

## File Descriptors

Each proxied request needs at least two file descriptors:

- browser to setline
- setline to backend

Set a high open-file limit for the process.

For an interactive shell:

```bash
ulimit -n 65535
```

For systemd:

```ini
[Service]
LimitNOFILE=65535
```

Check the running process:

```bash
cat /proc/$(pidof setline)/limits | grep "open files"
```

## TCP Listen Queues

Increase kernel listen queue limits so bursts of browser resource requests do
not overflow before setline accepts them:

```bash
sudo sysctl -w net.core.somaxconn=4096
sudo sysctl -w net.ipv4.tcp_max_syn_backlog=4096
```

To persist the values, place them in `/etc/sysctl.d/90-setline.conf`:

```conf
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 4096
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

setline stops its listener and health-check task when the event loop exits.
It does not track every active client connection for shutdown cleanup, because
that would add synchronization to the normal connection lifecycle.

If Ctrl+C is pressed while WebSocket, slow, or half-open client connections are
still active, eventcore may print `streamSocket` active-handle warnings during
process exit. Avoid treating that shutdown-only diagnostic as a load-path
tuning target unless it becomes operationally noisy in real deployments.
