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

Route updates through the admin API affect only memory. They do not rewrite the
config file. On restart, setline loads routes from the configured JSON file
again.

Supported runtime operations are:

- add or replace one route
- delete one route
- clear all routes
- replace all routes

All route-changing calls must come from localhost and must pass the admin token
check. Keep these endpoints bound to trusted local automation such as service
startup scripts or deployment hooks.

When routes change, setline rebuilds the next route tree first and then swaps
it into runtime state. Backend health information is preserved for ports that
remain referenced by the new route set.

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
normal setline workload. The project routes by HTTP URL and may add
`Forwarded`/`X-Forwarded-*` headers, so it must read and sometimes rewrite HTTP
headers. The first practical bottlenecks are usually file descriptors, backend
connect timeout, listen queue limits, and short-lived upstream connections.

## Shutdown Notes

setline stops its listener and health-check task when the event loop exits.
It does not track every active client connection for shutdown cleanup, because
that would add synchronization to the normal connection lifecycle.

If Ctrl+C is pressed while WebSocket, slow, or half-open client connections are
still active, eventcore may print `streamSocket` active-handle warnings during
process exit. Avoid treating that shutdown-only diagnostic as a load-path
tuning target unless it becomes operationally noisy in real deployments.
