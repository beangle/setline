#!/bin/bash
# setline 端到端回归：真实 haproxy -> setline -> 自测后端。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BACKEND_PORT="${BACKEND_PORT:-19199}"
SETLINE_PORT="${SETLINE_PORT:-19198}"
HAPROXY_PORT="${HAPROXY_PORT:-19197}"
# 管理口缺省是回环 127.0.0.1:8081；回归给它一个独立端口，避免撞上宿主机上真在跑的东西。
SETLINE_ADMIN_PORT="${SETLINE_ADMIN_PORT:-19196}"
# 管理面用例要单独起一个 setline，不能和上面那两个端口撞。
SPLIT_DATA_PORT="${SPLIT_DATA_PORT:-19194}"
SPLIT_ADMIN_PORT="${SPLIT_ADMIN_PORT:-19195}"
PEER_SERVICE_PORT="${PEER_SERVICE_PORT:-19193}"
PEER_SERVICE_ADMIN_PORT="${PEER_SERVICE_ADMIN_PORT:-19192}"
READ_TIMEOUT_MILLIS="${READ_TIMEOUT_MILLIS:-500}"
WS_IDLE_MILLIS="${WS_IDLE_MILLIS:-500}"
# 池内空闲连接保留多久。比检查窗口长，这样「已回池」和「池已清空」两步都能稳定观察到。
POOL_IDLE_MILLIS="${POOL_IDLE_MILLIS:-3000}"
WORK="$(mktemp -d /tmp/setline-e2e.XXXXXX)"
BACKEND_PID=""
SETLINE_PID=""
HAPROXY_PID=""
SPLIT_PID=""
PEER_SERVICE_PID=""
KEEPALIVE_PID=""

cleanup() {
  [ -z "$HAPROXY_PID" ] || kill "$HAPROXY_PID" 2>/dev/null || true
  [ -z "$SETLINE_PID" ] || kill "$SETLINE_PID" 2>/dev/null || true
  [ -z "$SPLIT_PID" ] || kill "$SPLIT_PID" 2>/dev/null || true
  [ -z "$PEER_SERVICE_PID" ] || kill "$PEER_SERVICE_PID" 2>/dev/null || true
  [ -z "$KEEPALIVE_PID" ] || kill "$KEEPALIVE_PID" 2>/dev/null || true
  [ -z "$BACKEND_PID" ] || kill "$BACKEND_PID" 2>/dev/null || true
  wait "$HAPROXY_PID" "$SETLINE_PID" "$SPLIT_PID" "$PEER_SERVICE_PID" \
    "$KEEPALIVE_PID" "$BACKEND_PID" 2>/dev/null || true
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
  curl -fsS "http://127.0.0.1:$SETLINE_ADMIN_PORT/_setline/status.json" |
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
  # setline 的写接口只按 TCP 对端判断「本机」，经 haproxy 转发的远端请求对端就是
  # 127.0.0.1，会被当成本机来源。前置代理必须自己拒掉管理路径（接线见 docs/haproxy-integration.md）。
  http-request deny if { path_beg /_setline }
  default_backend setline
backend setline
  server s1 127.0.0.1:$SETLINE_PORT check
CFG
  "$binary" -f "$WORK/haproxy.cfg" -db >"$WORK/haproxy-$label.log" 2>&1 &
  HAPROXY_PID=$!
  wait_for_port "$HAPROXY_PORT" 50 || fail "$label haproxy did not listen"

  # 管理路径必须由前置代理挡掉（peer 协议读也挂在数据面上，所以这是入口唯一的一道）：
  # 数据面只承接 `GET /_setline/routes`，写和 status 都只在管理口上。
  local proxy_admin data_read data_status data_write direct_admin
  proxy_admin="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$HAPROXY_PORT/_setline/routes")"
  [ "$proxy_admin" = "403" ] ||
    fail "$label frontend did not deny /_setline (got $proxy_admin)"
  # 读搭在数据面上：只认得业务端口的机器也能读路由表。
  data_read="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: local.test' \
    "http://127.0.0.1:$SETLINE_PORT/_setline/routes")"
  [ "$data_read" = "200" ] ||
    fail "$label data plane does not serve the peer routes endpoint (got $data_read)"
  # 状态页/status.json 只在管理口上，数据面一律 404。
  data_status="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: local.test' \
    "http://127.0.0.1:$SETLINE_PORT/_setline/status.json")"
  [ "$data_status" = "404" ] ||
    fail "$label data plane served status.json (got $data_status)"
  # 写不搭在数据面上。
  data_write="$(curl -s -o /dev/null -w '%{http_code}' -X PUT -H 'Host: local.test' \
    "http://127.0.0.1:$SETLINE_PORT/_setline/routes?host=evil.test")"
  [ "$data_write" = "404" ] ||
    fail "$label data plane accepted an admin write (got $data_write)"
  direct_admin="$(curl -s -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:$SETLINE_ADMIN_PORT/_setline/routes")"
  [ "$direct_admin" = "200" ] ||
    fail "$label local admin read broke (got $direct_admin)"
  echo "PASS[$label] peer routes ride the data plane; status and writes stay on the admin listener"

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

  # 上游把响应体截断时，setline 只能关掉 client 连接。若它像以前那样再补一个 502，
  # 响应体里就会多出一条状态行和错误文本（声明的 Content-Length 已经发出去，前置代理
  # 会把它们当成响应内容，甚至判成协议错误）。
  #
  # 这里直接打 setline 以保证信号只来自它，但不能用 `printf | nc`：管道结束会让 nc 半关闭
  # （FIN），而 setline 把 client 的 FIN 当作「放弃本次请求」
  # （见 docs/transparent-proxy-design.md 的 Connection Lifetime），
  # 那样测到的就不是截断响应了。用 /dev/tcp 拿一个既能写又能读的 fd，不半关闭。
  exec 3<>"/dev/tcp/127.0.0.1/$SETLINE_PORT"
  printf 'GET /truncate HTTP/1.1\r\nHost: local.test\r\nConnection: close\r\n\r\n' >&3
  timeout 5 cat <&3 >"$WORK/truncate.raw" || true
  exec 3<&- 3>&-
  # 补发的状态行会紧跟在 body 字节后面（没有换行），所以不能只数行首，要数全文出现次数。
  local status_lines
  status_lines="$(grep -oE 'HTTP/1\.[01] [0-9]+' "$WORK/truncate.raw" | wc -l | tr -d ' ')"
  [ "$status_lines" = 1 ] ||
    fail "$label truncated response carried $status_lines status lines: $(tr -d '\r' <"$WORK/truncate.raw" | tr '\n' ' ')"
  grep -q 'trunc' "$WORK/truncate.raw" || fail "$label truncated response body missing"
  echo "PASS[$label] truncated upstream response is not followed by a synthetic response"

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

  # 判据：同一条 client 连接上的顺序请求必须复用上游连接。
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
  stats="$(curl -fsS "http://127.0.0.1:$SETLINE_ADMIN_PORT/_setline/status.json")"
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
dub build --build=release-nobounds --compiler=ldc2 --config=agent

check_cli_flags() {
  local status
  set +e
  "$ROOT/target/setline" --config "$WORK/missing.json" >"$WORK/setline-wrong-flag.log" 2>&1
  status=$?
  set -e
  [ "$status" = 2 ] ||
    fail "setline accepted --config; expected the service to use -f only"
  set +e
  "$ROOT/target/setline-agent" -f "$WORK/missing.conf" >"$WORK/agent-wrong-flag.log" 2>&1
  status=$?
  set -e
  [ "$status" = 2 ] ||
    fail "setline-agent accepted -f; expected the agent to use --config only"
  echo "PASS setline uses -f and setline-agent uses --config"
}
check_cli_flags

python3 scripts/e2e_backend.py --port "$BACKEND_PORT" --ready-file "$WORK/backend.ready" \
  >"$WORK/backend.log" 2>&1 &
BACKEND_PID=$!
wait_for_port "$BACKEND_PORT" 50 || fail "test backend did not listen"

cat >"$WORK/setline.json" <<JSON
{"listen":"127.0.0.1:$SETLINE_PORT","adminListen":"127.0.0.1:$SETLINE_ADMIN_PORT",
 "readTimeoutMillis":$READ_TIMEOUT_MILLIS,
 "webSocketIdleTimeoutMillis":$WS_IDLE_MILLIS,"upstreamIdleTimeoutMillis":$POOL_IDLE_MILLIS,
 "healthCheck":{"intervalMillis":60000,"timeoutMillis":1000,"unhealthyThreshold":3,"healthyThreshold":1},
 "routes":{"local.test":{"/":$BACKEND_PORT}}}
JSON
"$ROOT/target/setline" -f "$WORK/setline.json" >"$WORK/setline.log" 2>&1 &
SETLINE_PID=$!
wait_for_port "$SETLINE_PORT" 50 || fail "setline did not listen"

# setline-agent：只读 setline.conf，按 [routes] 渲染片段，不绑任何监听，渲染完立即退出。
check_render_only() {
  local dir="$WORK/render-only"
  mkdir -p "$dir"
  cat >"$WORK/render-only.conf" <<CONF
[agent]
type = haproxy
output = $dir

[routes]
local.test = {"/": $BACKEND_PORT}
CONF
  if ! "$ROOT/target/setline-agent" render --config "$WORK/render-only.conf" \
      >"$WORK/render-only.log" 2>&1; then
    fail "setline-agent renderer exited non-zero: $(cat "$WORK/render-only.log")"
  fi
  # output 是根目录：程序按 type 自己建 haproxy/ 子目录并写固定文件名。
  [ -s "$dir/haproxy/setline.cfg" ] || fail "setline-agent did not write the backend fragment"
  [ -s "$dir/haproxy/setline.map" ] || fail "setline-agent did not write the routing map"
  grep -q 'local.test' "$dir/haproxy/setline.map" ||
    fail "setline-agent map is missing the configured [routes] entry"
  echo "PASS setline-agent renders predefined [routes] and exits"
}
check_render_only

# 管理接口只该为控制面读取有界的 body：给一个超过 4 MiB 防御性上限的 PUT，必须回 413。
check_admin_body_limit() {
  local big="$WORK/admin-big.json" code
  { printf '{"routes":{"/big":['; head -c 4194304 /dev/zero | tr '\0' '1'; printf ']}}'; } >"$big"
  code="$(curl -s -o /dev/null -w '%{http_code}' -X PUT -H 'Expect:' \
    --data-binary @"$big" \
    "http://127.0.0.1:$SETLINE_ADMIN_PORT/_setline/routes/all?host=big.test" || true)"
  [ "$code" = "413" ] || fail "admin accepted an oversized body: $code"
  echo "PASS admin rejects a request body over the defensive limit with 413"
}
check_admin_body_limit

# 拼一条原始管理接口写请求：$1=Host 头，$2=X-Forwarded-Host（可空），$3=body。
raw_admin_put() {
  local host="$1" forwarded="$2" body="$3"
  printf 'PUT /_setline/routes?host=gate.test HTTP/1.1\r\nHost: %s\r\n' "$host"
  [ -z "$forwarded" ] || printf 'X-Forwarded-Host: %s\r\n' "$forwarded"
  printf 'Content-Length: %s\r\nConnection: close\r\n\r\n%s' "${#body}" "$body"
}

# 写接口的「本机」= 回环对端 + 回环 Host：经本机代理转发的远端请求带着公开主机名，
# 不再被当成本机（原因见 docs/configuration.md 的 peerReaders 一节）。
check_admin_write_gate() {
  local body='{"/evil":[9999]}' out
  out="$(raw_admin_put "127.0.0.1:$SETLINE_ADMIN_PORT" "" "$body" |
    timeout 5 nc 127.0.0.1 "$SETLINE_ADMIN_PORT")"
  echo "$out" | grep -q '^HTTP/.* 200' || fail "loopback-host write was rejected: $out"

  out="$(raw_admin_put app.example.com "" "$body" | timeout 5 nc 127.0.0.1 "$SETLINE_ADMIN_PORT")"
  echo "$out" | grep -q '^HTTP/.* 403' || fail "public-host write was accepted: $out"

  out="$(raw_admin_put "127.0.0.1:$SETLINE_ADMIN_PORT" app.example.com "$body" |
    timeout 5 nc 127.0.0.1 "$SETLINE_ADMIN_PORT")"
  echo "$out" | grep -q '^HTTP/.* 403' || fail "write with a proxied host was accepted: $out"

  curl -s -o /dev/null -X DELETE \
    "http://127.0.0.1:$SETLINE_ADMIN_PORT/_setline/routes?host=gate.test&prefix=/evil"
  echo "PASS write gate requires a loopback host, not just a loopback peer"
}
check_admin_write_gate

# 服务入口只读 setline.json；即使同机存在带 peers 的 setline.conf，也不会自行渲染。
check_peer_service_still_listens() {
  local dir="$WORK/peer-service"
  mkdir -p "$dir"
  cat >"$WORK/peer-service.conf" <<CONF
[agent]
type = haproxy
output = $dir
peers = peer=http://127.0.0.1:$SETLINE_ADMIN_PORT
CONF
  cat >"$WORK/peer-service.json" <<JSON
{"listen":"127.0.0.1:$PEER_SERVICE_PORT","adminListen":"127.0.0.1:$PEER_SERVICE_ADMIN_PORT","routes":{}}
JSON
  "$ROOT/target/setline" -f "$WORK/peer-service.json" >"$WORK/peer-service.log" 2>&1 &
  PEER_SERVICE_PID=$!
  wait_for_port "$PEER_SERVICE_PORT" 50 ||
    fail "setline.service did not listen: $(cat "$WORK/peer-service.log")"
  curl -fsS "http://127.0.0.1:$PEER_SERVICE_ADMIN_PORT/_setline/status.json" >/dev/null ||
    fail "setline.service admin listener did not start"
  [ ! -e "$dir/haproxy/setline.cfg" ] ||
    fail "setline.service read setline.conf and rendered agent fragments itself"
  kill "$PEER_SERVICE_PID" 2>/dev/null || true
  wait "$PEER_SERVICE_PID" 2>/dev/null || true
  PEER_SERVICE_PID=""
  echo "PASS setline.service ignores setline.conf and leaves rendering to setline-agent"
}
check_peer_service_still_listens

# 一轮渲染由 agent 入口完成：读 peers、写片段、退出，不碰监听。
check_peer_render_once() {
  local dir="$WORK/peer-render"
  mkdir -p "$dir"
  cat >"$WORK/peer-render.conf" <<CONF
[agent]
type = haproxy
output = $dir
peers = peer=http://127.0.0.1:$SETLINE_ADMIN_PORT
CONF
  [ "$("$ROOT/target/setline-agent" --agent-peers --config "$WORK/peer-render.conf")" = "1" ] ||
    fail "setline-agent --agent-peers did not report the configured peer"
  if ! timeout 20 "$ROOT/target/setline-agent" render --config "$WORK/peer-render.conf" \
      >"$WORK/peer-render.log" 2>&1; then
    fail "peer renderer did not exit 0: $(cat "$WORK/peer-render.log")"
  fi
  [ -s "$dir/haproxy/setline.cfg" ] || fail "peer renderer did not write the backend fragment"
  grep -q '^  server local_test_0 127.0.0.1:' "$dir/haproxy/setline.cfg" ||
    fail "peer renderer did not name the backend after host + path"
  grep -q '127.0.0.1:' "$dir/haproxy/setline.cfg" ||
    fail "peer renderer did not rewrite the route port onto the peer host"
  echo "PASS peer renderer writes fragments and exits after one round"
}
check_peer_render_once

# 客户端连接亲和 + 专属上游连接的空闲回收。
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

# WebSocket 隧道的空闲超时。只有「两个方向都没有字节」才叫空闲，因此这里既验证
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
  stats="$(curl -fsS "http://127.0.0.1:$SETLINE_ADMIN_PORT/_setline/status.json")"
  echo "$stats" | grep -qE "\"webSocketIdleTimeouts\":[1-9]" ||
    fail "$label status.json did not count the idle timeout: $stats"
  echo "$stats" | grep -qE '"activeWebSockets":0' ||
    fail "$label closed tunnels are still counted as active: $stats"
  echo "PASS[$label] silent tunnel closed after ${WS_IDLE_MILLIS}ms and was counted"

  kill "$HAPROXY_PID" 2>/dev/null || true
  wait "$HAPROXY_PID" 2>/dev/null || true
  HAPROXY_PID=""
}

# SIGTERM 优雅退出。停监听后把在途请求跑完再退出，客户端不该看到 5xx 或连接重置。
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

# 本机的非回环 IPv4 地址：准入按来源地址判定，要真的端到端验证就得有非回环来源。
local_addresses() {
  { # 默认路由的源地址优先：它几乎肯定是 up 的，其它（网桥等）可能没载波。
    ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") print $(i + 1)}'
    ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1
    hostname -I 2>/dev/null | tr ' ' '\n'; } |
    grep -E '^[0-9]+(\.[0-9]+){3}$' | grep -v '^127\.' | awk '!seen[$0]++'
}

# 管理接口的**写**只在独立监听上；**读**同时挂在数据面和管理口上，准入只看来源地址
# （本机，或 peerReaders 里列出的读方），全程没有凭据。
check_admin_listen() {
  local label="admin-listen"
  # 两个监听都绑所有地址，好让非回环来源真的出现；读方地址写进 peerReaders 才放行。
  local lan_a lan_b
  lan_a="$(local_addresses | head -1)"
  lan_b="$(local_addresses | sed -n 2p)"
  local readers=""
  [ -z "$lan_a" ] || readers=",\"peerReaders\":[\"$lan_a\"]"
  cat >"$WORK/split.json" <<JSON
{"listen":"*:$SPLIT_DATA_PORT","adminListen":"*:$SPLIT_ADMIN_PORT"$readers,
 "routes":{"local.test":{"/":$BACKEND_PORT}}}
JSON
  "$ROOT/target/setline" -f "$WORK/split.json" >"$WORK/split.log" 2>&1 &
  SPLIT_PID=$!

  local ok=1
  for _ in $(seq 50); do
    # 进程要是没起来（例如端口被占），先报出来，别拿旧实例的响应当成功。
    kill -0 "$SPLIT_PID" 2>/dev/null || break
    if wait_for_port "$SPLIT_ADMIN_PORT" 1 && curl -fsS -o /dev/null \
      "http://127.0.0.1:$SPLIT_ADMIN_PORT/_setline/status.json" 2>/dev/null; then
      ok=0
      break
    fi
    sleep 0.1
  done
  [ "$ok" = 0 ] || fail "$label split setline did not listen: $(cat "$WORK/split.log")"

  # 数据面只承接 peer 协议一个端点：本机来源直接读得到（没有任何凭据），status.json 这类
  # 没有跨机消费者的读则是 404。
  local data_read data_status data_write admin_root admin_status data_root
  data_read="$(curl -s -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:$SPLIT_DATA_PORT/_setline/routes")"
  [ "$data_read" = 200 ] ||
    fail "$label local data plane read was rejected ($data_read)"
  data_status="$(curl -s -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:$SPLIT_DATA_PORT/_setline/status.json")"
  [ "$data_status" = 404 ] ||
    fail "$label data plane served status.json (got $data_status)"
  # 写只在管理口上：数据面收到 PUT 一律 404，不管来源是谁。
  data_write="$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
    "http://127.0.0.1:$SPLIT_DATA_PORT/_setline/routes?host=evil.test")"
  [ "$data_write" = 404 ] ||
    fail "$label data plane accepted an admin write ($data_write)"
  admin_root="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$SPLIT_ADMIN_PORT/")"
  [ "$admin_root" = 404 ] || fail "$label admin listener proxied an unknown path ($admin_root)"
  admin_status="$(curl -s "http://127.0.0.1:$SPLIT_ADMIN_PORT/_setline/status.json")"
  # status.json 面向机器读取，不该暴露管理口地址；入口只留在状态页 HTML 和启动日志里。
  if echo "$admin_status" | grep -q '"adminListen"'; then
    fail "$label status.json leaked the admin listen address: $admin_status"
  fi
  data_root="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: local.test' \
    "http://127.0.0.1:$SPLIT_DATA_PORT/ok")"
  [ "$data_root" = 200 ] || fail "$label data plane stopped proxying ($data_root)"

  # 读只看来源地址：本机来源带公开 Host 也读得到（本地调用方可能就是按公开名访问的），
  # 所以前置代理不 deny /_setline 时读会被转发进来——这是记录在案的取舍，代理侧的 deny
  # 才是入口那道门。写不一样：它既是公开 Host 又来自回环对端，正是「经本机代理转发」的形状，
  # 一律 403。
  local read_code write_code
  read_code="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: split.internal' \
    "http://127.0.0.1:$SPLIT_DATA_PORT/_setline/routes")"
  [ "$read_code" = 200 ] || fail "$label local read with a public host was rejected ($read_code)"
  read_code="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: 127.0.0.1' \
    -H 'X-Forwarded-Host: split.internal' "http://127.0.0.1:$SPLIT_ADMIN_PORT/_setline/status.json")"
  [ "$read_code" = 200 ] || fail "$label local status read with a forwarded host was rejected ($read_code)"
  write_code="$(curl -s -o /dev/null -w '%{http_code}' -X PUT -H 'Host: split.internal' \
    "http://127.0.0.1:$SPLIT_ADMIN_PORT/_setline/routes?host=evil.test")"
  [ "$write_code" = 403 ] || fail "$label proxied write was not rejected ($write_code)"
  write_code="$(curl -s -o /dev/null -w '%{http_code}' -X PUT -H 'Host: 127.0.0.1' \
    -H 'X-Forwarded-Host: split.internal' \
    "http://127.0.0.1:$SPLIT_ADMIN_PORT/_setline/routes?host=evil.test")"
  [ "$write_code" = 403 ] || fail "$label forwarded-host write was not rejected ($write_code)"

  # 非回环来源：列进 peerReaders 的地址读得到，没列的读不到。这条只有在机器上真的有非回环
  # 地址时才跑得起来（容器里常常只有回环）。
  if [ -n "$lan_a" ]; then
    grep -q "setline peer readers: .*$lan_a" "$WORK/split.log" ||
      fail "$label startup log did not print the reader list: $(cat "$WORK/split.log")"
    read_code="$(curl -s -o /dev/null -w '%{http_code}' "http://$lan_a:$SPLIT_DATA_PORT/_setline/routes")"
    [ "$read_code" = 200 ] || fail "$label listed reader $lan_a was rejected ($read_code)"
    read_code="$(curl -s -o /dev/null -w '%{http_code}' "http://$lan_a:$SPLIT_ADMIN_PORT/_setline/status.json")"
    [ "$read_code" = 200 ] || fail "$label listed reader could not read status.json ($read_code)"
    data_status="$(curl -s -o /dev/null -w '%{http_code}' "http://$lan_a:$SPLIT_DATA_PORT/_setline/status.json")"
    [ "$data_status" = 404 ] || fail "$label listed reader got status.json off the data plane ($data_status)"
    write_code="$(curl -s -o /dev/null -w '%{http_code}' -X PUT \
      "http://$lan_a:$SPLIT_ADMIN_PORT/_setline/routes?host=evil.test")"
    [ "$write_code" = 403 ] || fail "$label listed reader could write routes ($write_code)"
    if [ -n "$lan_b" ]; then
      read_code="$(curl -s -o /dev/null -w '%{http_code}' "http://$lan_b:$SPLIT_DATA_PORT/_setline/routes")"
      [ "$read_code" = 403 ] || fail "$label unlisted address $lan_b was not rejected ($read_code)"
    fi
    echo "PASS[$label] peerReaders admits $lan_a${lan_b:+ and rejects $lan_b}"
  else
    echo "PASS[$label] no non-loopback address on this host: address allowlist not exercised"
  fi

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
