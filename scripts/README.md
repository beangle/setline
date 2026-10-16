# Build, packaging and test scripts

| Path | Purpose |
|------|---------|
| `build_deb.sh` / `build_rpm.sh` / `build_srpm.sh` | Build a `.deb`, a binary `.rpm`, or a source `.src.rpm` rebuildable on the target host. |
| `package/` | Default config, systemd units and the spec fragment shared by the packages (`setline.spec.common`). |
| `bench.sh` | Reproducible benchmarks: RPS, P99, 1MB throughput, upstream connections, TIME_WAIT. `BENCH_HAPROXY=1` adds the real `ab -> haproxy -> setline` shape. |
| `bench_backend.d` | Static backend for `bench.sh` (one connection per thread, no GIL). |
| `bench_headers.py` | Minimal keep-alive client used by the header-length sweep. |
| `e2e.sh` | End-to-end regression through the machine's real HAProxy. |
| `e2e_backend.py` | Test backend for `e2e.sh` (`/slow`, `/stall`, `/ws`, ...). |
| `e2e_keepalive.py` | keep-alive client for `e2e.sh`. |
| `e2e_ws.py` | Minimal WebSocket probe for `e2e.sh`. |

The build scripts always overwrite: one version number maps to many source
states during development, so skipping a rebuild would silently ship a stale
package.

The version comes from the release git tag, so tag first and package second.
The installed file list and the install/upgrade scriptlets live in
`scripts/package/setline.spec.common`; `build_rpm.sh` and `build_srpm.sh` both
paste that fragment into the spec they generate, so a package rebuilt from the
SRPM has the same contents as the one we publish.

## Install layout

`/usr/bin/setline`; `/usr/share/setline/{setline.json.default,apply.conf.example,haproxy-setline-cfgdir.conf.example}`;
`/usr/share/doc/setline/*.md` (everything under `docs/`, plus the `CHANGELOG.md`);
`/usr/lib/setline/setline-apply`;
`/usr/lib/systemd/system/{setline.service,setline-render.service,setline-render.timer,setline-apply.service,setline-apply.timer}`;
`/etc/setline/setline.json`; `/var/lib/setline/{haproxy,nginx,apply}/`.

The first install copies `setline.json.default` to `/etc/setline/setline.json`.
Runtime route updates write that file back, so it is owned by `setline:beangle`
and group-writable, and the package neither tracks nor removes it.

## Fragment reload

`setline` writes fragments atomically to `/var/lib/setline/<proxy>/`; the
root-owned `setline-apply` validates them and reloads (timer-driven, idempotent
on a content hash, rolls the whole set back on failure). Rationale and
alternatives: `docs/agent-reload.md`.

- Fragments only carry rules and backends; the listener stays with the proxy's
  main config. HAProxy needs the four `map_beg()` lines in its frontend; nginx
  needs the upstream include in `http {}` and the per-host locations in each
  `server {}`. A routes-only change (`*.map`) is hot-synced without a reload;
  adding or removing a backend reloads.

Enable it with one timer - `agent.type` picks the proxy:
`systemctl enable --now setline-apply.timer`. A pure render machine
(`agent.peers`, no `listen`) also enables `setline-render.timer`,
which re-runs `setline-render.service` every 30s (one run renders one round and
exits); a single-host deployment keeps `setline.service` resident instead.
`setline-apply auto` dispatches on
`setline -f <cfg> --agent-type` for every config in `SETLINE_CONFIGS` (default
`/etc/setline/setline.json`); with no agent-mode config it is a no-op, so an idle
timer on a plain proxy host is normal. `setline-apply haproxy` runs one by hand.

## End-to-end regression and benchmarks

`e2e.sh` drives `haproxy -> setline -> backend` with the haproxy already on the
machine (2.0+; `HAPROXY_BINARIES=/path/to/haproxy`, comma-separated, runs one
round each). It fails with that hint when none is installed rather than
downloading one. Covered: 1xx intermediates, `Expect: 100-continue`, HTTP/1.0,
close-delimited bodies, HEAD/204/304, request framing, upstream reuse, upstream
read timeout, client abort, `status.json`, `listen:false`
render-only mode, WebSocket echo/idle/one-way, SIGTERM shutdown (exit status 0)
and how `/_setline` is split between the two listeners: the peer-protocol
`GET /_setline/routes` rides both the admin listener (its own port, default
`127.0.0.1:8081`) and the data plane, while status reads and writes stay on the
admin listener alone. Upstream affinity has its own case: 8 keep-alive
clients x 200 requests open at most 10 upstream connections, and those pooled
connections are reaped after `upstreamIdleTimeoutMillis` even with
`healthCheck.intervalMillis` at 60s. The WebSocket cases exercise HAProxy's own
handshake checks, so the test backend computes a real RFC 6455 accept value.

`bench.sh` produces every performance number - nothing is claimed from "it feels
faster". Run it on a quiet machine with TIME_WAIT drained
(`ss -tan state time-wait | wc -l`): the local ephemeral range is only ~28k, and
leftovers skew both throughput and CPU per request. It compiles
`bench_backend.d` on the fly (`ldc2 -O3 -release`) instead of reusing the Python
e2e backend, whose GIL caps out around 35k RPS and would saturate before setline
does. Compare instance counts with:

```bash
SETLINE_INSTANCES=1 scripts/bench.sh   # single-instance baseline
SETLINE_INSTANCES=4 scripts/bench.sh   # four instances sharing the port (reusePort)
```

`BENCH_HAPROXY=1` adds the deployed shape (`ab -> haproxy -> setline -> backend`,
haproxy from `PATH` or `BENCH_HAPROXY_BIN`).

### Reading the output

```
sequential     rps=14605.36 p99_ms=0
concurrency_8  rps=21328.78 p99_ms=1
concurrency_64 rps=20405.87 p99_ms=6
large_1m       rps=316.42   p99_ms=44 kib_s=324038.67
header_bytes client_ms cpu_us_per_request cpu_ns_per_header_byte
0 635 53.8 -        1024 642 56.2 54.93        49152 2084 200.0 4.07
upstream requests=1000 new_connections=0 new_per_second=0.000 backend_accepts=0
timewait baseline=176 peak=176 delta=0
haproxy=3.0.25
haproxy_shape c=64 requests=10000 rps=15702.48 p99_ms=6 upstream_connects=32 pool_hits=9968 timewait_delta=0
```

- `instances` is `SETLINE_INSTANCES`; more than one means that many setline
  processes share the port via `reusePort`.
- `rps` / `p99_ms` are `ab`'s Requests per second and 99th percentile. `ab`
  prints percentiles in whole milliseconds, so `p99_ms=0` is "under 1ms".
  `sequential` is `-n 1000 -c 1`, the others `-c 8` / `-c 64`, all with `-k`.
- `large_1m` serves 1MB bodies (`/large?bytes=1048576`); `kib_s` is `ab`'s
  transfer rate and agrees with `rps` (316/s ~ 324038 KiB/s).
- Header sweep: `client_ms` is the client's total time for 8000 requests,
  `cpu_us_per_request` is setline's own CPU (`utime+stime`) per request, and
  `cpu_ns_per_header_byte` divides that by the header size. Watch the last
  column: incremental scanning makes it fall or hold as headers grow, while a
  rescanning (quadratic) implementation makes it rise. (`ab` cannot send these -
  its request buffer is 8KB - hence `bench_headers.py`.)
- `upstream`: upstream connections setline opened for 1000 sequential keep-alive
  requests, with the backend's accept count as a cross-check. `0` means one
  upstream connection per client connection, reused, so no churn.
- `timewait`: TIME_WAIT before the run and its peak during it; `delta` is the
  difference, and `0` means the run left nothing behind.
- `haproxy_shape`: the `ab -> haproxy -> setline` shape. `upstream_connects` and
  `timewait_delta` are deltas for that run, `pool_hits` counts requests served
  from a reused connection. Expect `upstream_connects` to track the number of
  haproxy-to-setline connections rather than the request count,
  `pool_hits ~= requests` and `timewait_delta ~= 0`.

Absolute numbers depend on the machine; compare only runs on the same host with
TIME_WAIT drained.
