#!/bin/bash
# setline 可复现基准：RPS、P99、1MB 吞吐、新建上游连接和 TIME_WAIT 峰值。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BACKEND_PORT="${BACKEND_PORT:-19599}"
SETLINE_PORT="${SETLINE_PORT:-19598}"
HAPROXY_PORT="${HAPROXY_PORT:-19597}"
# 管理口缺省是回环 127.0.0.1:10080；基准里固定一个回环端口，免得撞上宿主机上真在跑的东西。
SETLINE_ADMIN_PORT="${SETLINE_ADMIN_PORT:-19596}"
SETLINE_INSTANCES="${SETLINE_INSTANCES:-1}"
REQUESTS="${BENCH_REQUESTS:-5000}"
REQUESTS_64="${BENCH_REQUESTS_64:-10000}"
LARGE_REQUESTS="${BENCH_LARGE_REQUESTS:-100}"
POOL_REQUESTS="${BENCH_POOL_REQUESTS:-1000}"
WORK="$(mktemp -d /tmp/setline-bench.XXXXXX)"
BACKEND_PID=""
SETLINE_PID=""
HAPROXY_PID=""
SAMPLER_PID=""
SETLINE_PIDS=()

cleanup() {
  [ -z "$SAMPLER_PID" ] || kill "$SAMPLER_PID" 2>/dev/null || true
  for pid in "${SETLINE_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  [ -z "$HAPROXY_PID" ] || kill "$HAPROXY_PID" 2>/dev/null || true
  [ -z "$BACKEND_PID" ] || kill "$BACKEND_PID" 2>/dev/null || true
  wait "$SAMPLER_PID" "$HAPROXY_PID" "$BACKEND_PID" 2>/dev/null || true
  for pid in "${SETLINE_PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
  done
  if [ "${KEEP_WORK:-0}" != "1" ]; then
    rm -rf "$WORK"
  else
    echo "kept work directory: $WORK"
  fi
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

wait_for_port() {
  local port="$1"
  for _ in $(seq 50); do
    if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
      exec 3>&- 3<&-
      return 0
    fi
    sleep 0.1
  done
  return 1
}

metric() {
  local name="$1"
  shift
  local output="$WORK/$name.ab"
  ab -q "$@" >"$output"
  local rps p99
  rps="$(sed -n 's/^Requests per second:[[:space:]]*\([0-9.]*\).*/\1/p' "$output")"
  p99="$(sed -n 's/^[[:space:]]*99%[[:space:]]*\([0-9.]*\).*/\1/p' "$output")"
  [ -n "$rps" ] || fail "$name did not report Requests per second"
  [ -n "$p99" ] || fail "$name did not report p99"
  printf '%s rps=%s p99_ms=%s\n' "$name" "$rps" "$p99"
}

time_wait_count() {
  ss -tan state time-wait 2>/dev/null | tail -n +2 | wc -l
}

# TIME_WAIT 峰值采样：起一个后台循环，把观察窗内的最高水位写进文件。
start_time_wait_sampler() {
  local peak_file="$1"
  printf '%s\n' "$(time_wait_count)" >"$peak_file"
  (
    peak="$(cat "$peak_file")"
    while true; do
      current="$(time_wait_count)"
      if [ "$current" -gt "$peak" ]; then
        peak="$current"
        printf '%s\n' "$peak" >"$peak_file"
      fi
      sleep 0.05
    done
  ) &
  SAMPLER_PID=$!
}

stop_time_wait_sampler() {
  [ -z "$SAMPLER_PID" ] || kill "$SAMPLER_PID" 2>/dev/null || true
  wait "$SAMPLER_PID" 2>/dev/null || true
  SAMPLER_PID=""
}

# 读一个 setline 计数器的当前值（status.json 里 counters 的平铺字段）。
status_counter() {
  curl -fsS "http://127.0.0.1:$SETLINE_ADMIN_PORT/_setline/status.json" |
    grep -o "\"$1\":[0-9]*" | head -1 | cut -d: -f2
}

cd "$ROOT"
for command in dub ldc2 ab python3 ss sed awk getconf; do
  command -v "$command" >/dev/null 2>&1 || fail "missing required command: $command"
done
dub build --build=release-nobounds --compiler=ldc2

# 基准后端用 D 写的静态后端：e2e_backend.py 是 Python，高并发下 GIL 会先于 setline
# 饱和，用它量多实例扩展比只会得到假结果（见 scripts/bench_backend.d 顶部说明）。
ldc2 -O3 -release -of="$WORK/bench_backend" scripts/bench_backend.d
"$WORK/bench_backend" --port "$BACKEND_PORT" --ready-file "$WORK/backend.ready" \
  >"$WORK/backend.log" 2>&1 &
BACKEND_PID=$!
wait_for_port "$BACKEND_PORT" || fail "backend did not listen"

cat >"$WORK/setline.json" <<JSON
{"listen":"127.0.0.1:$SETLINE_PORT","adminListen":"127.0.0.1:$SETLINE_ADMIN_PORT",
 "readTimeoutMillis":30000,"reusePort":$([ "$SETLINE_INSTANCES" -gt 1 ] && echo true || echo false),
 "healthCheck":{"intervalMillis":60000,"timeoutMillis":1000,"unhealthyThreshold":3,"healthyThreshold":1},
 "routes":{"local.test":{"/":$BACKEND_PORT}}}
JSON
for instance in $(seq "$SETLINE_INSTANCES"); do
  "$ROOT/target/setline" -f "$WORK/setline.json" >"$WORK/setline-$instance.log" 2>&1 &
  SETLINE_PIDS+=("$!")
done
wait_for_port "$SETLINE_PORT" || fail "setline did not listen"

printf 'instances=%s\n' "$SETLINE_INSTANCES"
URL="http://127.0.0.1:$SETLINE_PORT/ok"
HOST_HEADER='Host: local.test'
metric sequential -n 1000 -c 1 -k -H "$HOST_HEADER" "$URL"
metric concurrency_8 -n "$REQUESTS" -c 8 -k -H "$HOST_HEADER" "$URL"
metric concurrency_64 -n "$REQUESTS_64" -c 64 -k -H "$HOST_HEADER" "$URL"

LARGE_URL="http://127.0.0.1:$SETLINE_PORT/large?bytes=1048576"
large_output="$WORK/large_1m.ab"
ab -q -n "$LARGE_REQUESTS" -c 8 -k -H "$HOST_HEADER" "$LARGE_URL" >"$large_output"
large_rps="$(sed -n 's/^Requests per second:[[:space:]]*\([0-9.]*\).*/\1/p' "$large_output")"
large_p99="$(sed -n 's/^[[:space:]]*99%[[:space:]]*\([0-9.]*\).*/\1/p' "$large_output")"
large_rate="$(sed -n 's/^Transfer rate:[[:space:]]*\([0-9.]*\).*/\1/p' "$large_output")"
printf 'large_1m rps=%s p99_ms=%s kib_s=%s\n' "$large_rps" "$large_p99" "$large_rate"

# P1-2：头部解析的 CPU 开销必须随头长线性增长，不能是平方。用一个 X-Pad 头把请求
# 撑大，量 setline 自己的 CPU 时间（/proc/<pid>/stat 的 utime+stime）除以请求数和
# 头字节数：线性扫描下「每字节 CPU」随头长下降或持平（固定开销摊薄），平方实现下
# 它会随头长线性上升。客户端不用 ab（请求缓冲只有 8KB，头一长就被截断），用
# scripts/bench_headers.py。
cpu_ticks_total() {
  local ticks=0 value
  for pid in "${SETLINE_PIDS[@]}"; do
    value="$(sed 's/^[^)]*) //' "/proc/$pid/stat" | awk '{print $12 + $13}')"
    ticks=$((ticks + value))
  done
  printf '%s' "$ticks"
}
clock_tck="$(getconf CLK_TCK)"
header_requests="${BENCH_HEADER_REQUESTS:-8000}"
printf 'header_bytes client_ms cpu_us_per_request cpu_ns_per_header_byte\n'
for header_bytes in 0 1024 4096 16384 32768 49152; do
  before="$(cpu_ticks_total)"
  client="$(python3 scripts/bench_headers.py --port "$SETLINE_PORT" \
    --host "${HOST_HEADER#Host: }" --path /ok --pad-bytes "$header_bytes" \
    --requests "$header_requests")"
  after="$(cpu_ticks_total)"
  client_ms="$(printf '%s' "$client" | sed -n 's/.*elapsed_ms=\([0-9]*\).*/\1/p')"
  [ -n "$client_ms" ] || fail "header sweep at $header_bytes bytes did not finish"
  requests="$(printf '%s' "$client" | sed -n 's/.*requests=\([0-9]*\).*/\1/p')"
  awk -v bytes="$header_bytes" -v ms="$client_ms" -v ticks="$((after - before))" \
    -v tck="$clock_tck" -v requests="$requests" \
    'BEGIN { us = ticks * 1000000 / tck / requests;
             per = bytes > 0 ? sprintf("%.2f", us * 1000 / bytes) : "-";
             printf "%s %s %.1f %s\n", bytes, ms, us, per }'
done

# 顺序请求的上游新建连接数：主口径用 setline 自己的计数器，后端 accepts 作旁证
# （`__connections` 那次查询自身会占一个 accept，所以要减掉）。
for _ in $(seq 50); do
  curl -fsS -H "$HOST_HEADER" "$URL" >/dev/null
done
curl -fsS "http://127.0.0.1:$BACKEND_PORT/__reset" >/dev/null
pool_before_connects="$(status_counter upstreamConnects)"
baseline_time_wait="$(time_wait_count)"
peak_file="$WORK/time_wait.peak"
start_ns="$(date +%s%N)"
start_time_wait_sampler "$peak_file"
ab -q -n "$POOL_REQUESTS" -c 1 -k -H "$HOST_HEADER" "$URL" >"$WORK/pool.ab"
end_ns="$(date +%s%N)"
stop_time_wait_sampler

accepts="$(curl -fsS "http://127.0.0.1:$BACKEND_PORT/__connections" |
  sed -n 's/^accepts=//p')"
backend_connections=$((accepts > 0 ? accepts - 1 : 0))
new_connections=$(( $(status_counter upstreamConnects) - pool_before_connects ))
elapsed_ms=$(((end_ns - start_ns) / 1000000))
[ "$elapsed_ms" -gt 0 ] || elapsed_ms=1
new_per_second="$(awk -v count="$new_connections" -v ms="$elapsed_ms" \
  'BEGIN { printf "%.3f", count * 1000 / ms }')"
peak_time_wait="$(cat "$peak_file")"

printf 'upstream requests=%s new_connections=%s new_per_second=%s backend_accepts=%s\n' \
  "$POOL_REQUESTS" "$new_connections" "$new_per_second" "$backend_connections"
printf 'timewait baseline=%s peak=%s delta=%s\n' \
  "$baseline_time_wait" "$peak_time_wait" "$((peak_time_wait - baseline_time_wait))"

# 真实形态：ab -> haproxy -> setline -> 后端。
#
# 前面几段直接打 setline，看到的「客户端连接」就是 ab 的连接；实际部署里中间还有一层
# haproxy，它按自己的连接池把客户端请求映射到「haproxy -> setline」的连接上。所以这一段
# 才是 setline 该被考核的形态：稳态上游新建连接数应当约等于 haproxy 到 setline 的连接数，
# 而不是随请求数增长。用 `BENCH_HAPROXY=1` 打开。
haproxy_shape() {
  local concurrency="$1"
  local requests="$2"
  local before_connects before_hits baseline peak_file output rps p99
  before_connects="$(status_counter upstreamConnects)"
  before_hits="$(status_counter poolHits)"
  baseline="$(time_wait_count)"
  peak_file="$WORK/haproxy-time_wait.peak"
  start_time_wait_sampler "$peak_file"
  output="$WORK/haproxy-c$concurrency.ab"
  ab -q -n "$requests" -c "$concurrency" -k -H "$HOST_HEADER" \
    "http://127.0.0.1:$HAPROXY_PORT/ok" >"$output"
  stop_time_wait_sampler
  rps="$(sed -n 's/^Requests per second:[[:space:]]*\([0-9.]*\).*/\1/p' "$output")"
  p99="$(sed -n 's/^[[:space:]]*99%[[:space:]]*\([0-9.]*\).*/\1/p' "$output")"
  printf 'haproxy_shape c=%s requests=%s rps=%s p99_ms=%s upstream_connects=%s pool_hits=%s timewait_delta=%s\n' \
    "$concurrency" "$requests" "$rps" "$p99" \
    "$(( $(status_counter upstreamConnects) - before_connects ))" \
    "$(( $(status_counter poolHits) - before_hits ))" \
    "$(( $(cat "$peak_file") - baseline ))"
}

if [ "${BENCH_HAPROXY:-0}" = "1" ]; then
  HAPROXY_BIN="${BENCH_HAPROXY_BIN:-$(command -v haproxy || true)}"
  [ -n "$HAPROXY_BIN" ] ||
    fail "BENCH_HAPROXY=1 needs haproxy in PATH or BENCH_HAPROXY_BIN=/path/to/haproxy"
  cat >"$WORK/haproxy.cfg" <<CFG
global
  maxconn 8192
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
  "$HAPROXY_BIN" -f "$WORK/haproxy.cfg" -db >"$WORK/haproxy.log" 2>&1 &
  HAPROXY_PID=$!
  wait_for_port "$HAPROXY_PORT" || fail "haproxy did not listen"
  printf 'haproxy=%s\n' "$("$HAPROXY_BIN" -vv 2>/dev/null |
    sed -n 's/^HA-*Proxy version \([^ -]*\).*/\1/p' | head -1)"
  haproxy_shape 8 "$REQUESTS"
  haproxy_shape 64 "$REQUESTS_64"
  kill "$HAPROXY_PID" 2>/dev/null || true
  wait "$HAPROXY_PID" 2>/dev/null || true
  HAPROXY_PID=""
fi
