# setline

`setline` is a small Linux-only local HTTP path router written in D.

It listens on a local address, matches requests by host and path prefix, and
forwards them to local backend services.

`setline` is a lightweight user-space HTTP full proxy that listens on a fixed
port and dispatches requests to local backend ports by host and URI prefix. It
favors simple deployment and predictable HTTP streaming over kernel-level
transparent proxy techniques.

**Positioning: setline is a proxy that sits behind a proxy.** It is deployed
after HAProxy/Nginx and is never the first hop a client reaches. Either the
front proxy connects straight to the applications and setline only renders the
routing fragments, or setline serves as the subordinate proxy for that front
proxy - in both shapes it never faces untrusted clients, so TLS termination,
header size limits, client timeouts, rate limiting and access logging stay the
front proxy's job. The consequences of this boundary, the out-of-scope list and
the improvement plan live in `docs/roadmap.md`.

## Scope

- Linux only.
- Backends are local only; the listener defaults to loopback and can
  explicitly bind other interfaces.
- HTTP/1.x only in this first version.
- Host-scoped path-prefix routing with longest-prefix priority.
- Local HTTP backends only.
- Multiple backends use random selection. No weight support.
- URL/path rewriting is intentionally unsupported.

## Build

```bash
dub build
```

Packaging and the end-to-end/benchmark harnesses are under `scripts/`; see
`scripts/README.md`.

## Run

```bash
dub run -- -f config.example.json       # start
dub run -- -c -f config.example.json    # validate the config and exit
```

## Config

```json
{
  "listen": "127.0.0.1:8080",
  "adminListen": "127.0.0.1:10080",
  "peerReaders": ["10.0.1.7"],
  "routes": {
    "local1.example.com": { "/api/edu": [9002, 9003], "/api": 9001 },
    "local2.example.com": { "/api": 9081 },
    "*": { "/": 9090 }
  }
}
```

Routes are chosen by the request `Host` header (port stripped, lowercased), then
by longest path prefix within that host, with `*` as the fallback namespace.
Each port maps to `127.0.0.1:<port>`: setline proxies only to local backends.
`config.example.json` shows every key, and `scripts/package/setline.json` is
what the packages install.

The admin API is `/_setline/*`. It always has its own listener, `adminListen`,
defaulting to `127.0.0.1:10080`. The data plane `listen` serves exactly one
endpoint, `GET /_setline/routes` (the peer protocol), so a machine that only
knows the service port can read the route table; the status page, `status.json`
and every write live on `adminListen` alone. Route changes are therefore a
localhost-only action. Reads are gated by source address: localhost, or an
address listed in `peerReaders` - setline holds no credentials. Front proxies
should reject `/_setline` outright.

The full reference - every field, its default, the validation errors and worked
examples - is `docs/configuration.md`.

## Agent mode

With an `agent` block, `setline` renders a HAProxy or Nginx **fragment** from a
route table: its own, or a set of live `setline` peers (`agent.peers`). It
never rewrites the proxy's own
config, and a render-only machine has no listener at all: it renders one round
and exits, re-rendering on a systemd timer (`setline-render.timer`). The unprivileged
`setline` writes fragments atomically; the root-owned `setline-apply` validates
and reloads them, hot-syncing a routes-only map change without a reload when a
HAProxy admin socket is available.

Fields and examples: `docs/configuration.md`. Wiring: `docs/haproxy-integration.md`
and `docs/nginx-integration.md`. Applying and reloading: `docs/agent-reload.md`.

## Documentation

- `docs/configuration.md` - every config field, defaults, validation errors, examples.
- `docs/deployment.md` - where setline sits, the file descriptor budget, systemd units, packaging, shutdown.
- `docs/haproxy-integration.md`, `docs/nginx-integration.md` - fragment layout and wiring.
- `docs/agent-reload.md` - applying and reloading fragments (`setline-apply`, the timer, HAProxy map hot-sync).
- `docs/runtime-routes-api.md` - runtime route API, credentials, the status page and `status.json`.
- `docs/transparent-proxy-design.md` - the streaming and connection model, including the WebSocket tunnel.
- `docs/project-constraints.md` - scope, the privilege model and the constraints behind them.
- `docs/roadmap.md` - what is done, what is planned, and the evidence for both.
- `docs/d-style.md`, `docs/d-coding.md` - D code style and coding rules.
- `scripts/README.md` - packaging, end-to-end and benchmark harnesses.

## Notes

This project is deliberately narrow: host-scoped local HTTP path routing, local
backend selection, and transparent proxying. Running `setline` as root is a
requirement to avoid, not a tuning choice - see the Privilege Model in
`docs/project-constraints.md`.
