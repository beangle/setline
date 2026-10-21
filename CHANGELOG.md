# Changelog

All notable changes to setline are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project uses
`0.0.x` versions and makes no compatibility promise between them until `0.1.0`.

Per-release notes with the upgrade steps spelled out live in
`docs/release-note-<version>.md`.

## [Unreleased]

### Added

- `setline.conf` is now the local control plane, matching `basctl.conf`: it
  holds `[remote]` URL/Profile/key, the topology and proxy download targets,
  `[agent] type/output/peers`, and every `[apply]` reload parameter.
- `[proxy] file` is optional: it defaults to `/etc/haproxy/haproxy.cfg` for
  haproxy and `/etc/nginx/nginx.conf` for nginx.
- Apply state is fixed at `<agent.output>/apply`; there is no separate
  `[apply] stateDir` setting.
- `setline pull` downloads the peer list, proxy config and HTTPS certificate
  pair from bashub using the Profile key from `setline.conf`, then rewrites
  only `[agent] peers` in `setline.conf` with atomic no-op updates when content
  is unchanged. Certificates are split
  into `cert.pem`/`key.pem` for nginx and concatenated into `bundle.pem` for
  haproxy under the fixed `/etc/setline/certs` directory; private-key files are
  mode `0600`, and clearing the Profile certificate removes the managed files.
- `setline-agent --remote` (start and reload) fetches
  `GET /api/{profile}/config/setline-manifest`, compares per-resource SHA-256
  values with `<agent.output>/remote.manifest.json`, and download only changed
  resources. A remote failure keeps the last successfully pulled configuration
  and does not block rendering or applying local routes.
- Agent remote sync is split across the privilege boundary:
  `setline pull --check --stage` runs as the `setline` user and writes changed
  resources to `<agent.output>/remote-stage`; root then runs
  `setline pull --install`, which re-verifies the local staging hashes and
  installs the managed files without accessing the network. Installed files
  inherit the owner and mode of the file they replace, so `setline.conf` keeps
  its `0640` protection.
- `setline-agent.timer` drives `setline-agent-interval.service`, which only
  renders peers/local routes and applies fragments. It does not contact
  bashub; remote configuration is checked by `setline-agent.service` on
  start/reload, or manually with `setline pull`.
- `setline pull --check --stage` exits `10` after staging a changed proxy main config or
  certificate pair. The agent
  then runs `setline-apply --now --force`, which bypasses both the unchanged
  fragment hash and HAProxy map hot-sync so a changed main proxy config or
  certificate triggers a real validation and reload.
- `setline init` writes a commented `setline.conf` template only when the
  target does not exist.
- `setline --apply-config` exports the resolved `[apply]` settings for
  `setline-apply`; `--agent-type` reads the proxy type from the same file.
- `setline --agent-peers` reports the number of configured `[agent] peers`,
  for diagnostics without parsing INI in shell.
- `setline render` performs one render round without binding a listener. It
  aggregates `[agent] peers` when configured and otherwise renders the local
  topology; the root-owned agent helper invokes it through `runuser`.
- `setline-agent` and `setline-agent.timer` replace the separate render and
  apply timers. The start/reload unit performs one remote manifest check; the
  timer-driven interval unit runs `setline render` as the `setline` user with
  `runuser`, then runs `setline-apply --now` as root.

### Changed

- `setline.json` is now topology-only: `listen`, `adminListen`, timeouts and
  `routes`. Any `agent` field in JSON is rejected; `[agent] type/output/peers`
  belong to `setline.conf`.
- `setline-apply` reads all reload settings from `setline.conf` instead of
  `apply.conf` and environment variables. Fragment paths and the HAProxy config
  list now follow a custom `[agent] output` root.
- `setline-apply` accepts `--now` to skip the quiet window when the caller has
  just completed a render round.
- `setline.service` always listens and proxies when `listen` is enabled,
  including with `[agent] peers`. Peers now select the renderer's data source
  instead of turning the resident process into a one-shot renderer. With no
  peers it still re-renders local route changes immediately.
- Package install creates `/etc/setline/setline.conf` (`root:beangle 0640`) on
  first install and preserves it on upgrades.

### Removed

- `download-setline`, `download-haproxy`, `download-proxy`,
  `/etc/setline/apply.conf` and the separate reload environment-variable
  configuration. No compatibility fallback is provided.
- `setline-render.{service,timer}` and `setline-apply.{service,timer}`. Package
  upgrades remove their enable links and migrate an enabled timer to
  `setline-agent.timer`, starting it if the old timer was running.

## [0.0.4] - 2026-10-16

The release that turns setline into something deployable: the data plane and
the control plane are split, runtime route updates reach a running proxy, the
upstream connection is reused instead of rebuilt per request, and the package,
the systemd units and the end-to-end harness come with it.

### Added

- **Separate admin listener.** `adminListen` (default `127.0.0.1:8081`) serves
  the whole admin API; the data plane `listen` serves exactly one endpoint,
  `GET /_setline/routes`, so a machine that knows only the service port can read
  the route table.
- **Route updates under `/_setline/*`**: `GET /_setline/routes`,
  `PUT`/`DELETE /_setline/routes`, `PUT /_setline/routes/all`, plus the status
  page and `status.json` on the admin listener. Updates are written back to the
  config file atomically.
- **`peerReaders`**: the read gate is a list of source addresses. setline holds
  no credentials at all - reads are admitted by source, writes only from
  loopback with a loopback `Host`.
- **Upstream connection reuse**: one upstream connection per client connection,
  kept across requests that route to the same backend port, plus a small idle
  pool sized from the recent concurrency high-water mark.
  `upstreamIdleTimeoutMillis` (default 30s) bounds both.
- **`readTimeoutMillis`** (default 15s): a backend that stalls between response
  bytes becomes a `504` while the response has not started, and a client that
  disconnects interrupts a read blocked on it.
- **WebSocket tunnelling** with `webSocketIdleTimeoutMillis` (`0` = never time
  out) and byte/tunnel counters.
- **`reusePort`** for running several listeners on the same address.
- **`listen: false`** render-only deployments and **agent mode**: render a
  HAProxy or Nginx fragment from the local route table or from `agent.peers`,
  driven by `setline-render.timer`, applied by the root-owned `setline-apply`.
- **HAProxy map hot-sync**: a routes-only change is synced into the running
  proxy through its admin socket instead of a reload.
- **Status page and `status.json`**: listeners, live counters, per-port health
  and the route table; the page refreshes itself every 5 seconds
  (`?refresh=30`, `?refresh=0` to stop).
- **Packaging**: RPM, SRPM and DEB build scripts with systemd units
  (`setline.service`, `setline-render.{service,timer}`,
  `setline-apply.{service,timer}`) and a default `/etc/setline/setline.json`.
- **Harnesses**: `scripts/e2e.sh` (haproxy -> setline -> backend, 26 cases) and
  `scripts/bench.sh`.

### Changed

- Runtime route updates rewrite the config file with two-space indentation,
  sorted keys and unescaped paths, so the file stays hand-editable and repeated
  updates produce no diff noise.
- The default admin port moved to `127.0.0.1:8081`. `10080` is on the browsers'
  restricted-port list (the status page could not be opened there) and `18080`
  is claimed by common tooling.
- The status page groups its metrics into two columns (listeners and routes,
  traffic and counters).
- HTTP framing is strict on both hops: incremental head scanning, `1xx`
  intermediates, `Expect: 100-continue`, `Content-Length` validated as `1*DIGIT`,
  and a truncated connection instead of a response written after the head.
- Unknown config keys are ignored, including keys from earlier drafts
  (`adminToken`, `agent.bind`, `agent.sync`, `agent.remote`, `agent.workDir`,
  `agent.token`); `agent.peers[]` still rejects unknown fields.
- The package version comes from the release git tag (`v0.0.4` -> `0.0.4`)
  instead of `dub.json`, so the tag is the single source of truth and the
  packaging scripts must run after it exists.
- Backends are named after the route they serve - host group plus path prefix,
  with `*` written `default` and a `b_` prefix (`b_app_example_com_api_edu`,
  `b_default`) -
  instead of after the machine that reported them. The identity of a service
  has always been host plus prefix: routes from several peers with the same
  host and prefix merge into one backend, so the old names named it after
  whichever peer happened to be read first.

### Removed

- **`adminToken`** and every other credential: `agent.token`, `peers[].token`
  and the `X-Setline-Token` header. The gate is the source address.
- **`accessLog`**: setline keeps no access log of its own - the front proxy
  owns the per-request record, and the status counters cover the rest.
- The `agent.bind`, `agent.sync`, `agent.remote`, `agent.workDir` keys.
- The uncalled renderer helpers (`renderProxyConfig`, `renderHaproxy`,
  `renderNginx`, `nginxListenPort`).

### Fixed

- The SRPM rebuilds into the same package as the release rpm: the binary and
  source specs share their file list and scriptlets, and debuginfo generation
  is off (Fedora computed an empty debugsource list for the D sources and
  failed the rebuild).
- Connections are no longer churned per request: at c=64 and 20k requests the
  old path opened 2059-2202 upstream connections and left 1988-2240 `TIME_WAIT`
  entries, which exhausted the ephemeral port range and dropped throughput from
  65k to 17k RPS.
- Graceful shutdown on `SIGTERM` drains in-flight requests past an open
  WebSocket tunnel and exits `0`.
- Running the proxy or the agent as root is refused with exit code 2
  (`RestartPreventExitStatus=2`), instead of quietly serving the network with
  full privileges.

## [0.0.3] - 2026-06-07

The version that named the project's shape. Documents setline as a lightweight
user-space HTTP full proxy and records the decision to leave external proxy
configuration to deployment tooling. Adds Linux packaging scripts, client-side
keep-alive, host-scoped routes, the runtime route API with write-back, the
config check command (`-c`), health-aware backend selection and basic-auth
status endpoints over a single listener.

## [0.0.2] - 2026-06-06

Renames the package to `beangle-setline`.

## [0.0.1] - 2026-06-06

First cut: transparent proxying and route lookup in a single process.

[0.0.4]: https://github.com/beangle/setline/compare/v0.0.3...v0.0.4
