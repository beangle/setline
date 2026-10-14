#!/bin/bash
# setline 端到端回归：真实 haproxy -> setline -> 自测后端。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BACKEND_PORT="${BACKEND_PORT:-19199}"
SETLINE_PORT="${SETLINE_PORT:-19198}"
HAPROXY_PORT="${HAPROXY_PORT:-19197}"
# P2-4 要单独起一个 setline，不能和上面那两个端口撞。
SPLIT_DATA_PORT="${SPLIT_DATA_PORT:-19194}"
SPLIT_ADMIN_PORT="${SPLIT_ADMIN_PORT:-19195}"
READ_TIMEOUT_MILLIS="${READ_TIMEOUT_MILLIS:-500}"
WS_IDLE_MILLIS="${WS_IDLE_MILLIS:-500}"
# 池内空闲连接保留多久。比检查窗口长，这样「已回池」和「池已清空」两步都能稳定观察到。
POOL_IDLE_MILLIS="${POOL_IDLE_MILLIS:-3000}"
WORK="$(mktemp -d /tmp/setline-e2e.XXXXXX)"
BACKEND_PID=""
SETLINE_PID=""
HAPROXY_PID=""
SPLIT_PID=""
KEEPALIVE_PID=""

cleanup() {
  [ -z "$HAPROXY_PID" ] || kill "$HAPROXY_PID" 2>/dev/null || true
  [ -z "$SETLINE_PID" ] || kill "$SETLINE_PID" 2>/dev/null || true
  [ -z "$SPLIT_PID" ] || kill "$SPLIT_PID" 2>/dev/null || true
  [ -z "$KEEPALIVE_PID" ] || kill "$KEEPALIVE_PID" 2>/dev/null || true
  [ -z "$BACKEND_PID" ] || kill "$BACKEND_PID" 2>/dev/null || true
  wait "$HAPROXY_PID" "$SETLINE_PID" "$SPLIT_PID" "$KEEPALIVE_PID" "$BACKEND_PID" 2>/dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

wait_for_port() {
  local port="$1"
  local attempts="${2:-50}"
  for _ in $(seq "$attempts"); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
      exec 3>&- 3<&-
      return 0
    fi
    sleep 0.1
  done
  return 1
}

fd_count() {
  find "/proc/$1/fd" -mindepth 1 -maxdepth 1 | wc -l
}

wait_for_line() {
  local file="$1"
  local pattern="$2"
  local attempts="${3:-50}"
  for _ in $(seq "$attempts"); do
    grep -q "$pattern" "$file" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

status_counter() {
  curl -fsS "http://127.0.0.1:$SETLINE_PORT/__setline/status.json" |
    grep -o "\"$1\":[0-9]*" | head -1 | cut -d: -f2
}

haproxy_version() {
  local binary="$1"
  # 2.2 及更早打印 "HA-Proxy version"，2.3 起改为 "HAProxy version"。
  "$binary" -vv 2>/dev/null |
    sed -n 's/^HA-*Proxy version \([^ -]*\).*/\1/p' |
    head -1
}

run_case() {
  local binary="$1"
  local label="$2"
  local version
  version="$(haproxy_version "$binary")"
  [ -n "$version" ] || fail "$binary has no readable HAProxy version"

  cat >"$WORK/haproxy.cfg" <<CFG
global
  maxconn 4096
defaults
  mode http
  timeout connect 2s
  timeout client 30s
  timeout server 30s
frontend front
  bind 127.0.0.1:$HAPROXY_PORT
  default_backend setline
backend setline
  server s1 127.0.0.1:$SETLINE_PORT check
CFG
  "$binary" -f "$WORK/haproxy.cfg" -db >"$WORK/haproxy-$label.log" 2>&1 &
  HAPROXY_PID=$!
  wait_for_port "$HAPROXY_PORT" 50 || fail "$label haproxy did not listen"

  local expect_body
  expect_body="$(curl -fsS --max-time 5 \
    -H 'Host: local.test' -H 'Expect: 100-continue' \
    --data-binary '0123456789abcdefghij0123456789abcdefghij' \
    "http://127.0.0.1:$HAPROXY_PORT/expect")"
  [ "$expect_body" = "expect-ok" ] || fail "$label Expect body mismatch: $expect_body"
  echo "PASS[$label] Expect: 100-continue -> 200"

  printf 'GET /hints HTTP/1.1\r\nHost: local.test\r\nConnection: close\r\n\r\n' |
    timeout 5 nc 127.0.0.1 "$HAPROXY_PORT" >"$WORK/hints.raw"
  grep -q '103 Early Hints' "$WORK/hints.raw" || fail "$label missing 103"
  grep -q '200 OK' "$WORK/hints.raw" || fail "$label missing final 200"
  grep -q 'hints-ok' "$WORK/hints.raw" || fail "$label missing final body"
  echo "PASS[$label] 103 Early Hints + final 200"

  printf 'GET /ok HTTP/1.1\r\nHost: local.test\r\nConnection: close\r\n\r\n' |
    timeout 5 nc 127.0.0.1 "$HAPROXY_PORT" >"$WORK/connection-close.raw"
  grep -qi '^connection: close' "$WORK/connection-close.raw" ||
    fail "$label Connection close request was not closed"
  echo "PASS[$label] Connection: close closes client connection"

  printf 'GET /ok HTTP/1.0\r\nHost: local.test\r\n\r\n' |
    timeout 5 nc 127.0.0.1 "$HAPROXY_PORT" >"$WORK/http10.raw"
  grep -q '^HTTP/.* 200' "$WORK/http10.raw" || fail "$label HTTP/1.0 request did not return 200"
  grep -q '^ok$' "$WORK/http10.raw" || fail "$label HTTP/1.0 response body missing"
  echo "PASS[$label] HTTP/1.0 request"

  printf 'GET /no-length HTTP/1.1\r\nHost: local.test\r\n\r\n' |
    timeout 5 nc 127.0.0.1 "$HAPROXY_PORT" >"$WORK/no-length.raw"
  grep -q '^HTTP/.* 200' "$WORK/no-length.raw" || fail "$label close-delimited response status missing"
  grep -q 'no-length-ok' "$WORK/no-length.raw" || fail "$label close-delimited body missing"
  echo "PASS[$label] response without length uses connection close"

  printf 'HEAD /head HTTP/1.1\r\nHost: local.test\r\nConnection: close\r\n\r\n' |
    timeout 5 nc 127.0.0.1 "$HAPROXY_PORT" >"$WORK/head.raw"
  grep -q '^HTTP/.* 200' "$WORK/head.raw" || fail "$label HEAD status missing"
  grep -q '^ok$' "$WORK/head.raw" && fail "$label HEAD returned a body"
  echo "PASS[$label] HEAD suppresses response body"

  printf 'GET /status/204 HTTP/1.1\r\nHost: local.test\r\nConnection: close\r\n\r\n' |
    timeout 5 nc 127.0.0.1 "$HAPROXY_PORT" >"$WORK/status204.raw"
  grep -q '^HTTP/.* 204' "$WORK/status204.raw" || fail "$label 204 status missing"
  grep -q '^ok$' "$WORK/status204.raw" && fail "$label 204 returned a body"
  echo "PASS[$label] 204 suppresses response body"

  printf 'GET /status/304 HTTP/1.1\r\nHost: local.test\r\nConnection: close\r\n\r\n' |
    timeout 5 nc 127.0.0.1 "$HAPROXY_PORT" >"$WORK/status304.raw"
  grep -q '^HTTP/.* 304' "$WORK/status304.raw" || fail "$label 304 status missing"
  grep -q '^ok$' "$WORK/status304.raw" && fail "$label 304 returned a body"
  echo "PASS[$label] 304 suppresses response body"

  printf 'POST /framing HTTP/1.1\r\nHost: local.test\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\nhello' |
    timeout 5 nc 127.0.0.1 "$SETLINE_PORT" >"$WORK/duplicate-cl.raw"
  grep -q '^HTTP/.* 400' "$WORK/duplicate-cl.raw" ||
    fail "$label conflicting Content-Length was not rejected"

  printf 'POST /framing HTTP/1.1\r\nHost: local.test\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n' |
    timeout 5 nc 127.0.0.1 "$SETLINE_PORT" >"$WORK/cl-te.raw"
  grep -q '^HTTP/.* 400' "$WORK/cl-te.raw" ||
    fail "$label CL+TE was not rejected"
  echo "PASS[$label] conflicting request framing rejected"

  python3 scripts/e2e_ws.py echo --port "$HAPROXY_PORT" --path /ws ||
    fail "$label websocket tunnel did not echo"
  echo "PASS[$label] WebSocket tunnel echoes both directions"

  # P0-3 的判据：同一条 client 连接上的顺序请求必须复用上游连接。
  #
  # 这里直接打 setline、不看 haproxy：haproxy 会按它自己的连接池给每个客户端连接各开一条
  # 到 setline 的连接（`http-reuse safe` 并不会把空闲连接无条件借给新客户端），所以经过
  # haproxy 数出来的「上游新建数」是「haproxy 开了几条连接」，而不是「一条客户端连接复用
  # 了几次」。setline 自己的 `upstreamConnects` 才是干净的口径，也顺带避开了后端 accepts
  # 统计请求自身的问题。
  local before_connects after_connects
  before_connects="$(status_counter upstreamConnects)"
  ab -q -n 50 -c 1 -k -H 'Host: local.test' "http://127.0.0.1:$SETLINE_PORT/ok" >/dev/null
  after_connects="$(status_counter upstreamConnects)"
  local new_connects=$((after_connects - before_connects))
  [ "$new_connects" -le 1 ] ||
    fail "$label created $new_connects upstream connections for 50 sequential requests"
  echo "PASS[$label] 50 sequential requests on one client connection opened $new_connects upstream connection"

  local stats
  stats="$(curl -fsS "http://127.0.0.1:$SETLINE_PORT/__setline/status.json")"
  echo "$stats" | grep -qE '"poolHits":[1-9]' ||
    fail "$label status.json did not report pool hits: $stats"
  echo "$stats" | grep -qE '"upstreamConnects":[1-9]' ||
    fail "$label status.json did not report upstream connects: $stats"
  echo "$stats" | grep -q "\"$BACKEND_PORT\":" ||
    fail "$label status.json did not report per-port request counts: $stats"
  echo "$stats" | grep -qE '"webSocketTunnels":[1-9]' ||
    fail "$label status.json did not report websocket tunnels: $stats"
  echo "$stats" | grep -qE '"webSocketBytesToClient":[1-9]' ||
    fail "$label status.json did not report websocket bytes: $stats"
  echo "PASS[$label] status.json reports pool, per-port and websocket counters"

  grep -q "setline access host=local.test" "$WORK/setline.log" ||
    fail "$label access log line missing"
  echo "PASS[$label] access log records proxied requests"

  local status
  status="$(curl -sS --max-time 5 -o "$WORK/timeout.body" -w '%{http_code}' \
    -H 'Host: local.test' "http://127.0.0.1:$HAPROXY_PORT/stall")"
  [ "$status" = "504" ] || fail "$label upstream timeout returned $status instead of 504"
  echo "PASS[$label] upstream read timeout -> 504"

  local before during after
  before="$(fd_count "$SETLINE_PID")"
  curl -sS --max-time 0.8 -H 'Host: local.test' \
    "http://127.0.0.1:$HAPROXY_PORT/stall" >/dev/null 2>&1 || true
  sleep 0.2
  during="$(fd_count "$SETLINE_PID")"
  sleep 0.5
  after="$(fd_count "$SETLINE_PID")"
  [ "$after" -le "$before" ] || fail "$label fd count grew: before=$before during=$during after=$after"
  echo "PASS[$label] client abort released fds (before=$before during=$during after=$after)"

  kill "$HAPROXY_PID" 2>/dev/null || true
  wait "$HAPROXY_PID" 2>/dev/null || true
  HAPROXY_PID=""
}

cd "$ROOT"
dub build --build=release-nobounds --compiler=ldc2

python3 scripts/e2e_backend.py --port "$BACKEND_PORT" --ready-file "$WORK/backend.ready" \
  >"$WORK/backend.log" 2>&1 &
BACKEND_PID=$!
wait_for_port "$BACKEND_PORT" 50 || fail "test backend did not listen"

cat >"$WORK/setline.json" <<JSON
{"listen":"127.0.0.1:$SETLINE_PORT","readTimeoutMillis":$READ_TIMEOUT_MILLIS,"accessLog":true,
 "webSocketIdleTimeoutMillis":$WS_IDLE_MILLIS,"upstreamIdleTimeoutMillis":$POOL_IDLE_MILLIS,
 "healthCheck":{"intervalMillis":60000,"timeoutMillis":1000,"unhealthyThreshold":3,"healthyThreshold":1},
 "routes":{"local.test":{"/":$BACKEND_PORT}}}
JSON
"$ROOT/target/setline" -f "$WORK/setline.json" >"$WORK/setline.log" 2>&1 &
SETLINE_PID=$!
wait_for_port "$SETLINE_PORT" 50 || fail "setline did not listen"

# listen:false：纯渲染部署。进程只按配置文件渲染片段，不绑任何监听，渲染完立即退出。
check_render_only() {
  local dir="$WORK/render-only"
  mkdir -p "$dir"
  cat >"$WORK/render-only.json" <<JSON
{"listen":false,"agent":{"type":"haproxy","output":"$dir/setline.cfg"},
 "routes":{"local.test":{"/":$BACKEND_PORT}}}
JSON
  if ! "$ROOT/target/setline" -f "$WORK/render-only.json" >"$WORK/render-only.log" 2>&1; then
    fail "listen:false renderer exited non-zero: $(cat "$WORK/render-only.log")"
  fi
  [ -s "$dir/setline.cfg" ] || fail "listen:false did not write the backend fragment"
  [ -s "$dir/setline.map" ] || fail "listen:false did not write the routing map"
  grep -q 'local.test' "$dir/setline.map" ||
    fail "listen:false map is missing the configured route"
  echo "PASS render-only listen:false writes fragments and exits"
}
check_render_only

# P1-7：客户端连接亲和 + 专属上游连接的空闲回收。
#
# 前置代理复用到 setline 的连接时，setline 给每条客户端连接一条专属上游连接：稳态下新建
# 上游连接数等于客户端连接数，而不是每轮并发都新建/关闭（每次关闭都在 setline 自己的临时
# 端口上留一个 TIME_WAIT）。连接空闲超过 `upstreamIdleTimeoutMillis` 后交回空闲池，池里的
# 连接同样在超时后被独立巡检 task 关掉——不管 `healthCheck.intervalMillis` 配成多少。
check_upstream_affinity() {
  local label="upstream-affinity"
  local connections=8 requests=200 hold_millis=4000
  local requested=$((connections * requests))

  # 先等上一轮（haproxy 被 kill 时）的客户端连接收尾，让基线干净。
  local before_leased=0
  for _ in $(seq 100); do
    before_leased="$(status_counter upstreamLeased)"
    [ "$before_leased" = 0 ] && break
    sleep 0.1
  done
  [ "$before_leased" = 0 ] ||
    fail "$label ${before_leased} upstream connections stayed leased after the haproxy connections closed"

  local before_connects before_hits
  before_connects="$(status_counter upstreamConnects)"
  before_hits="$(status_counter poolHits)"

  python3 scripts/e2e_keepalive.py --port "$SETLINE_PORT" --host-header local.test --path /ok \
    --connections "$connections" --requests "$requests" --hold-millis "$hold_millis" \
    >"$WORK/keepalive.out" 2>&1 &
  KEEPALIVE_PID=$!

  wait_for_line "$WORK/keepalive.out" '^opened=' 100 ||
    fail "$label keep-alive clients never got a response: $(cat "$WORK/keepalive.out")"
  local during_leased
  during_leased="$(status_counter upstreamLeased)"
  [ "$during_leased" -ge "$connections" ] ||
    fail "$label only $during_leased upstream connections for $connections keep-alive clients"

  wait_for_line "$WORK/keepalive.out" '^requests=' 100 ||
    fail "$label keep-alive requests did not finish: $(cat "$WORK/keepalive.out")"
  local churn hits
  churn=$(( $(status_counter upstreamConnects) - before_connects ))
  hits=$(( $(status_counter poolHits) - before_hits ))
  [ "$churn" -le $((connections + 2)) ] ||
    fail "$label created $churn upstream connections for $requested requests over $connections clients"
  [ "$hits" -ge $((requested - connections - 2)) ] ||
    fail "$label only $hits upstream reuses for $requested requests over $connections clients"

  # 客户端连接还挂着，但专属上游连接应当在 upstreamIdleTimeoutMillis 之后回池。
  local reclaimed=0 leased=0
  for _ in $(seq 100); do
    leased="$(status_counter upstreamLeased)"
    if [ "$leased" = 0 ]; then
      reclaimed=1
      break
    fi
    sleep 0.2
  done
  local idle
  idle="$(status_counter upstreamIdle)"
  [ "$reclaimed" = 1 ] ||
    fail "$label idle keep-alive clients still hold $leased upstream connections"
  [ "$idle" -ge "$connections" ] ||
    fail "$label reclaimed leases did not return to the pool (idle=$idle)"

  # 池里的连接由独立的巡检 task 按真实时间关掉，不必等 healthCheck.intervalMillis（这里配 60s）。
  local drained=0
  for _ in $(seq 60); do
    if [ "$(status_counter upstreamIdle)" = 0 ]; then
      drained=1
      break
    fi
    sleep 0.2
  done
  [ "$drained" = 1 ] ||
    fail "$label idle pool kept $(status_counter upstreamIdle) connections past upstreamIdleTimeoutMillis"

  wait "$KEEPALIVE_PID" || fail "$label keep-alive client failed: $(cat "$WORK/keepalive.out")"
  KEEPALIVE_PID=""
  echo "PASS[$label] $requested requests over $connections keep-alive clients opened $churn" \
    "upstream connections; idle leases returned to the pool (idle=$idle) and drained after" \
    "${POOL_IDLE_MILLIS}ms idle"
}

# P2-5：WebSocket 隧道的空闲超时。只有「两个方向都没有字节」才叫空闲，因此这里既验证
# 静默隧道会在超时后断开，也验证只有一个方向有流量时不会被误杀。
check_websocket_idle() {
  local binary="$1"
  local label="websocket-idle"
  cat >"$WORK/websocket.cfg" <<CFG
global
  maxconn 4096
defaults
  mode http
  timeout connect 2s
  timeout client 30s
  timeout server 30s
  timeout tunnel 30s
frontend front
  bind 127.0.0.1:$HAPROXY_PORT
  default_backend setline
backend setline
  server s1 127.0.0.1:$SETLINE_PORT
CFG
  "$binary" -f "$WORK/websocket.cfg" -db >"$WORK/websocket-haproxy.log" 2>&1 &
  HAPROXY_PID=$!
  wait_for_port "$HAPROXY_PORT" 50 || fail "$label haproxy did not listen"

  python3 scripts/e2e_ws.py stream --port "$HAPROXY_PORT" --path '/ws?idle=1' \
    --count 8 --gap-millis 200 ||
    fail "$label a tunnel with traffic in one direction was killed"
  echo "PASS[$label] one-way traffic keeps the tunnel open past the idle timeout"

  python3 scripts/e2e_ws.py idle --port "$HAPROXY_PORT" --path '/ws?idle=1' \
    --expect-millis "$WS_IDLE_MILLIS" ||
    fail "$label a silent tunnel was not closed after ${WS_IDLE_MILLIS}ms"

  local stats
  stats="$(curl -fsS "http://127.0.0.1:$SETLINE_PORT/__setline/status.json")"
  echo "$stats" | grep -qE "\"webSocketIdleTimeouts\":[1-9]" ||
    fail "$label status.json did not count the idle timeout: $stats"
  echo "$stats" | grep -qE '"activeWebSockets":0' ||
    fail "$label closed tunnels are still counted as active: $stats"
  echo "PASS[$label] silent tunnel closed after ${WS_IDLE_MILLIS}ms and was counted"

  kill "$HAPROXY_PID" 2>/dev/null || true
  wait "$HAPROXY_PID" 2>/dev/null || true
  HAPROXY_PID=""
}

# P2-2：SIGTERM 优雅退出。停监听后把在途请求跑完再退出，客户端不该看到 5xx 或连接重置。
check_graceful_shutdown() {
  local binary="$1"
  local label="graceful"
  cat >"$WORK/graceful.cfg" <<CFG
global
  maxconn 4096
defaults
  mode http
  timeout connect 2s
  timeout client 30s
  timeout server 30s
  retries 0
frontend front
  bind 127.0.0.1:$HAPROXY_PORT
  default_backend setline
backend setline
  server s1 127.0.0.1:$SETLINE_PORT
CFG
  "$binary" -f "$WORK/graceful.cfg" -db >"$WORK/graceful-haproxy.log" 2>&1 &
  HAPROXY_PID=$!
  wait_for_port "$HAPROXY_PORT" 50 || fail "$label haproxy did not listen"

  local codes="$WORK/graceful.codes" pids=()
  : >"$codes"
  local i
  for i in $(seq 8); do
    curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: local.test' \
      "http://127.0.0.1:$HAPROXY_PORT/slow?ms=400" >>"$codes" &
    pids+=("$!")
  done
  # 等 8 个请求都进到 setline，再发 SIGTERM。
  sleep 0.15

  # 同时挂一条 WebSocket 隧道：长连接隧道不算「在途请求」，不能让它把退出拖到
  # systemd 的 TimeoutStopSec。探针在隧道被断开时自行退出，退出码非 0 会 fail。
  python3 scripts/e2e_ws.py hold --port "$HAPROXY_PORT" --path /ws --seconds 20 \
    >"$WORK/graceful-websocket.log" 2>&1 &
  local tunnel_pid=$!
  sleep 0.3

  kill -TERM "$SETLINE_PID"

  local failed=0 pid
  for pid in "${pids[@]}"; do
    wait "$pid" || failed=1
  done
  [ "$failed" = 0 ] || fail "$label a client request failed during drain"
  if grep -qv '^200$' "$codes"; then
    fail "$label saw a non-200 during drain: $(tr '\n' ' ' <"$codes")"
  fi

  # 用 /proc 判断退出：未回收的僵尸进程对 kill -0 仍然可见。
  local gone=0
  for _ in $(seq 200); do
    if [ ! -e "/proc/$SETLINE_PID" ] ||
      [ "$(awk '{print $3}' "/proc/$SETLINE_PID/stat" 2>/dev/null)" = "Z" ]; then
      gone=1
      break
    fi
    sleep 0.05
  done
  [ "$gone" = 1 ] || fail "$label setline did not exit after SIGTERM"
  # 退出码必须是 0：被信号打断或被信号默认动作杀掉（139 等）时前置代理看到的是
  # 连接被重置，肉眼上却「进程没了」，所以这里必须显式核对。
  local exit_status=0
  wait "$SETLINE_PID" || exit_status=$?
  [ "$exit_status" = 0 ] || fail "$label setline exited with status $exit_status after SIGTERM"
  SETLINE_PID=""

  local tunnel_status=0
  wait "$tunnel_pid" || tunnel_status=$?
  [ "$tunnel_status" = 0 ] ||
    fail "$label websocket tunnel outlived the process: $(cat "$WORK/graceful-websocket.log")"
  echo "PASS[$label] SIGTERM drained 8 in-flight requests past an open websocket tunnel, exit status 0"

  kill "$HAPROXY_PID" 2>/dev/null || true
  wait "$HAPROXY_PID" 2>/dev/null || true
  HAPROXY_PID=""
}

# 用机器上现有的 haproxy 跑一轮；不强制版本。片段里的写法要求 2.0+，但具体是哪个
# 小版本由环境决定。想指定二进制用 HAPROXY_BINARIES=/path/haproxy[,/another]。
if [ -n "${HAPROXY_BINARIES:-}" ]; then
  IFS=',' read -r -a haproxy_bins <<<"$HAPROXY_BINARIES"
  index=1
  for binary in "${haproxy_bins[@]}"; do
    run_case "$binary" "explicit-$index"
    index=$((index + 1))
  done
else
  HAPROXY_BIN="$(command -v haproxy || true)"
  [ -n "$HAPROXY_BIN" ] || fail "no haproxy in PATH; set HAPROXY_BINARIES=/path/to/haproxy"
  run_case "$HAPROXY_BIN" "haproxy-$(haproxy_version "$HAPROXY_BIN")"
fi

# P2-4：控制面与数据面分离。管理接口挪到独立监听后，数据面可以稳定只绑回环。
check_admin_listen() {
  local label="admin-listen"
  cat >"$WORK/split.json" <<JSON
{"listen":"127.0.0.1:$SPLIT_DATA_PORT","adminListen":"127.0.0.1:$SPLIT_ADMIN_PORT",
 "routes":{"local.test":{"/":$BACKEND_PORT}}}
JSON
  "$ROOT/target/setline" -f "$WORK/split.json" >"$WORK/split.log" 2>&1 &
  SPLIT_PID=$!

  local ok=1
  for _ in $(seq 50); do
    # 进程要是没起来（例如端口被占），先报出来，别拿旧实例的响应当成功。
    kill -0 "$SPLIT_PID" 2>/dev/null || break
    if wait_for_port "$SPLIT_ADMIN_PORT" 1 && curl -fsS -o /dev/null \
      "http://127.0.0.1:$SPLIT_ADMIN_PORT/__setline/status.json" 2>/dev/null; then
      ok=0
      break
    fi
    sleep 0.1
  done
  [ "$ok" = 0 ] || fail "$label split setline did not listen: $(cat "$WORK/split.log")"

  local data_admin admin_root admin_status data_root
  data_admin="$(curl -s -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:$SPLIT_DATA_PORT/__setline/status.json")"
  [ "$data_admin" = 404 ] ||
    fail "$label data plane still serves the admin API ($data_admin)"
  admin_root="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$SPLIT_ADMIN_PORT/")"
  [ "$admin_root" = 404 ] || fail "$label admin listener proxied an unknown path ($admin_root)"
  admin_status="$(curl -s "http://127.0.0.1:$SPLIT_ADMIN_PORT/__setline/status.json")"
  echo "$admin_status" | grep -q "\"adminListen\":{\"host\":\"127.0.0.1\",\"port\":$SPLIT_ADMIN_PORT}" ||
    fail "$label status.json does not report its own admin listen: $admin_status"
  data_root="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: local.test' \
    "http://127.0.0.1:$SPLIT_DATA_PORT/ok")"
  [ "$data_root" = 200 ] || fail "$label data plane stopped proxying ($data_root)"

  local exit_status=0
  kill -TERM "$SPLIT_PID" 2>/dev/null || true
  wait "$SPLIT_PID" || exit_status=$?
  SPLIT_PID=""
  [ "$exit_status" = 0 ] || fail "$label split instance exited with $exit_status"
  if grep -q 'leaking eventcore driver' "$WORK/split.log"; then
    fail "$label split instance leaked handles on exit: $(cat "$WORK/split.log")"
  fi
  echo "PASS[$label] admin moved to $SPLIT_ADMIN_PORT, data plane stays on $SPLIT_DATA_PORT"
}

check_upstream_affinity
check_websocket_idle "${HAPROXY_BIN:-${haproxy_bins[0]}}"
check_graceful_shutdown "${HAPROXY_BIN:-${haproxy_bins[0]}}"
check_admin_listen
echo "e2e: done"
