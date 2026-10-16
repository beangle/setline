# setline 0.0.4

Released 2026-10-16. First release meant to be installed: the data plane and the
control plane are separate, route updates reach a running proxy, upstream
connections are reused, and the packages, systemd units and harnesses ship with
it. Every other changelog entry is in `CHANGELOG.md`.

## Highlights

- **Two listeners.** `listen` carries traffic and exactly one admin endpoint,
  `GET /_setline/routes`. `adminListen` (default `127.0.0.1:8081`) carries the
  rest of `/_setline/*`: the status page, `status.json`, and every write. A
  front proxy can therefore deny `/_setline` on the public port and lose
  nothing, and a machine that only knows the service port can still read the
  route table.
- **No credentials.** `adminToken`, `agent.token`, `peers[].token` and the
  `X-Setline-Token` header are gone. Reads are admitted by source address
  (`peerReaders`), writes only from loopback with a loopback `Host` - "only this
  host can change routing" is now a TCP-level fact.
- **Connection reuse.** One upstream connection per client connection, held
  across requests that resolve to the same backend port, plus a small idle pool
  sized from the recent concurrency high-water mark. The old path reconnected
  per request and, at c=64 and 20k requests, left 1988-2240 `TIME_WAIT` entries
  behind - enough to exhaust the ephemeral port range and drop throughput from
  65k to 17k RPS.
- **Timeouts that end a stalled request.** `readTimeoutMillis` (default 15s)
  turns a backend that stops sending into a `504` while the response has not
  started; a client that gives up interrupts the read instead of holding fds.
  WebSocket tunnels have their own idle timeout (`0` = never).
- **WebSocket tunnelling** with tunnel and byte counters, and a graceful
  `SIGTERM` shutdown that drains in-flight requests past an open tunnel.
- **Agent mode.** Render a HAProxy or Nginx fragment from the local route table
  or from live `agent.peers`, one round per systemd timer tick, applied by the
  root-owned `setline-apply`. A routes-only change is hot-synced into a running
  HAProxy through its admin socket instead of a reload.
- **Packages.** RPM, SRPM and DEB scripts with units and a default config;
  `scripts/e2e.sh` drives haproxy -> setline -> backend and `scripts/bench.sh`
  measures throughput.

## Upgrading from an earlier 0.0.x build

A 0.0.3-style file still parses - the fields it had are still valid - but two
things about the admin API changed, and one key has to go:

- Delete `adminToken`. Nothing replaces it: reads are gated by `peerReaders`
  (a list of source addresses), writes by loopback.
- Move admin calls from `http://<host>:8080/__setline/...` to
  `http://127.0.0.1:8081/_setline/...`, and drop the `X-Setline-Token` header:
  the admin API left the data-plane port and now has its own listener. The
  default is `127.0.0.1:8081`; `10080` was rejected because browsers refuse to
  open that port at all (Firefox: "This address is restricted", Amanda's
  registered port), and `18080` because Spark's history server claims it and
  container port mappings commonly hold it.
- Runtime route updates rewrite the config file on disk. It is written with two
  space indentation, sorted keys and unescaped paths - the first update reflows
  a hand-written file, and it stays readable afterwards.

If your config was written against one of the untagged builds between the
0.0.x tags, also delete `accessLog` (setline keeps no access log; the front
proxy's log and the per-port counters on the status page cover it) and any
`agent.bind`, `agent.sync`, `agent.remote`, `agent.workDir` or `agent.token`.
Unknown keys are ignored rather than rejected, so a leftover one is harmless -
but it does nothing, which is worse than a config you can read.

## Installing

Packages are built by `scripts/build_rpm.sh`, `scripts/build_srpm.sh` and
`scripts/build_deb.sh`; the version comes from the release git tag, so tag
first and package second (`v0.0.3` -> `0.0.3`).

```bash
scripts/build_rpm.sh            # target/setline-0.0.4-1.fc44.x86_64.rpm (--> .el7 on RHEL 7)
scripts/build_srpm.sh           # target/setline-0.0.4-1.el7.src.rpm
scripts/build_deb.sh            # target/setline_0.0.4-1_amd64.deb
```

The package installs `/usr/bin/setline`, `/usr/lib/setline/setline-apply`, the
units under `/usr/lib/systemd/system/`, docs under `/usr/share/doc/setline/`,
and a first `/etc/setline/setline.json` (owned `setline:beangle`, group
writable because runtime updates write it; the package never removes it). It
creates the `beangle` group and the `setline` user, and enables nothing -
`systemctl enable --now setline` is yours to run.

Removing the package stops and disables the units and leaves
`/etc/setline/setline.json` in place, so a reinstall keeps your routes.

The default config listens on `*:8080` with the admin API on loopback and no
routes, so setline starts clean and routes arrive through the API or the config
file.

## Behaviour worth knowing

- `setline` and `setline-render` must not run as root; they exit `2` and say so.
  `setline.service` maps that to `RestartPreventExitStatus=2`. Only
  `setline-apply` runs as root.
- Exit codes: `0` success, `1` unusable config, `2` refused root start (or a
  `--sync-map` usage error), `4` HAProxy map hot-sync unavailable - the last one
  tells `setline-apply` to fall back to a reload.
- Raise `LimitNOFILE` to `2 * maxConnections + 64` (the units ship `131134` for
  the default `maxConnections` of 65535). setline prints the arithmetic on
  stderr when the limit is too low.
- The status page (`/_setline/status.html`) refreshes itself every 5 seconds;
  `?refresh=30` changes that and `?refresh=0` stops it. `status.json` carries
  the same data without the admin listener address.

## Verification

- `dub test --compiler=ldc2`: 103 passed, 0 failed.
- `dub build --build=release-nobounds --compiler=ldc2`: clean, and clean again
  with `-w` (warnings as errors); the only diagnostics the compiler emits come
  from a dub dependency, never from setline's own sources.
- `scripts/e2e.sh` against the system haproxy: 26 PASS, covering 1xx
  intermediates, `Expect: 100-continue`, HTTP/1.0, close-delimited bodies,
  HEAD/204/304, request framing, upstream reuse and affinity, upstream read
  timeout, client abort, `status.json`, `listen:false`, WebSocket echo/idle,
  `SIGTERM` shutdown and the split between the two listeners.
- `scripts/build_rpm.sh` and `scripts/build_srpm.sh` build
  `setline-0.0.4-1.<dist>.x86_64.rpm` and `...src.rpm`; the package was listed
  to confirm its 22 files (binary, `setline-apply`, five units, three default
  configs, all of `docs/` plus `CHANGELOG.md`), and both the packaged default
  config and `config.example.json` pass `setline -c`. Rebuilding the SRPM on
  the target host (`rpmbuild --rebuild`) yields the same 22 files and the same
  install/upgrade scriptlets.
- `scripts/bench.sh` for throughput, `P99` and connection churn on your own
  hardware; drain `TIME_WAIT` first or you measure port exhaustion instead.

Checked on Fedora 44 with LDC 1.42.0 (DMD 2.112.1 front end), Dub 1.41.0,
HAProxy 3.0.25 and nginx 1.30.4.

## Not in this release

TLS, HTTP/2 and HTTP/3, client-side timeouts and slowloris protection,
authentication, rate limiting, access logging, unix-socket backends and any
scheduling beyond random port selection. setline is a proxy that sits behind a
proxy; the reasoning is in `docs/project-constraints.md`.
