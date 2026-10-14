# 构建与打包脚本

| 路径 | 用途 |
|------|------|
| `build_deb.sh` | 构建 Debian/Ubuntu `.deb` 安装包 |
| `build_rpm.sh` | 构建二进制 `.rpm` 安装包 |
| `build_srpm.sh` | 构建源码 `.src.rpm`，可在目标机器重编 |
| `package/` | systemd 安装包使用的默认配置和服务文件 |
| `bench.sh` | 可复现性能基准（顺序/8/64 并发 RPS、P99、1MB 吞吐、上游新建连接、TIME_WAIT）；`BENCH_HAPROXY=1` 加测 `ab -> haproxy -> setline` 的真实形态 |
| `bench_backend.d` | `bench.sh` 用的静态基准后端（一连接一线程，无 GIL） |
| `bench_headers.py` | `bench.sh` 量头部解析开销用的最小 keep-alive 客户端 |
| `e2e.sh` | 端到端回归：真实 HAProxy -> setline -> 自测后端 |
| `e2e_keepalive.py` | e2e 用的 keep-alive 客户端（多条连接各顺序发 N 个请求，可挂住不发） |
| `e2e_backend.py` | e2e 用的自测后端（含 `/slow`、`/stall`、`/ws` 等端点） |
| `e2e_ws.py` | e2e 用的最小 WebSocket 探针（echo / idle / hold / stream） |

三个脚本都是**全量重建**：同名产物已存在时直接覆盖，没有"已存在就跳过"的开关。包名里的版本
来自 `dub.json`，开发期同一个版本会对应多次源码改动，跳过重建只会让你以为拿到了新包。

安装包默认布局：

- `/usr/bin/setline`
- `/usr/share/setline/setline.json.default`
- `/usr/share/setline/apply.conf.example`
- `/usr/share/setline/haproxy-setline-cfgdir.conf.example`
- `/usr/share/doc/setline/*.md`（`docs/` 下的全部文档：配置参考、reload 设计、部署、API 等）
- `/usr/lib/setline/setline-apply`
- `/usr/lib/systemd/system/setline.service`
- `/usr/lib/systemd/system/setline-apply.service`
- `/usr/lib/systemd/system/setline-apply.timer`
- `/etc/setline/setline.json`
- `/var/lib/setline/haproxy/`、`/var/lib/setline/nginx/`、`/var/lib/setline/apply/`

首次安装时会从 `/usr/share/setline/setline.json.default` 复制配置到
`/etc/setline/setline.json`。运行时路由更新需要写回配置文件，所以该文件归
`setline:beangle` 所有，并对所属组可写。

`/etc/setline/setline.json` 不作为 deb/rpm 包文件跟踪，卸载软件包时保留。

## 片段热加载

`setline` 只负责把 HAProxy/Nginx 片段原子写到 `/var/lib/setline/<proxy>/`，
校验与 reload 由 root 的 `setline-apply` 完成（timer 驱动、按内容哈希幂等、
失败整体回滚）。

接线分两种模式，逐步示例见 `docs/haproxy-integration.md` 与
`docs/nginx-integration.md`：

- 规则模式（`agent.bind` 留空，推荐）：只生成规则和后端，监听归代理主配置。
  haproxy 还要在主配置 frontend 里加 `map_beg()` 那四行；nginx 要在 `http {}`
  include upstream 文件、在每个 `server {}` include 对应 host 的 location 文件。
  只改路由表（`*.map`）时 `setline-apply` 会自动热同步，不 reload；加/删 backend 才 reload。
- 自包含模式（`agent.bind` 有值）：片段自带 `bind`/`listen`；nginx 在 `http {}`
  include 一份文件，haproxy 把片段目录作为额外的 `-f`（目录内只加载 `*.cfg`），
  并按 `haproxy-setline-cfgdir.conf.example` 覆盖单元的 `ExecStart`/`ExecReload`,
  因为 `-f $CFGDIR` 无法通过 `Environment=` 追加第二个目录。

启用自动应用（**一个 timer 就够**，跑 haproxy 还是 nginx 由配置里的 `agent.type`
决定，见下）：

```bash
systemctl enable --now setline-apply.timer
```

`setline-apply auto` 会对 `SETLINE_CONFIGS`（默认 `/etc/setline/setline.json`）里的每份
配置执行 `setline -f <cfg> --agent-type`，按返回的 `agent.type` 分派；没有任何配置处于
agent 模式时它什么都不做（普通代理机器上 timer 空转是正常的）。手工只跑某个代理仍然
可以：`setline-apply haproxy`。

设计与取舍（为什么不用 `-sf`/`-x`/`SIGHUP`、为什么用 timer 而不是 path 单元、
回滚粒度等）见 `docs/agent-reload.md`。

## 端到端回归与基准

`scripts/e2e.sh` 用真实 HAProxy 打通 `haproxy -> setline -> 后端`，覆盖 1xx 中间响应、
`Expect: 100-continue`、HTTP/1.0、连接关闭界定响应、HEAD/204/304、请求报文边界、
上游连接复用、上游读超时与客户端中断回收、`status.json` 计数、访问日志，以及
`listen:false` 纯渲染、WebSocket 隧道（双向回显、空闲超时、单向流量不被误杀）和
SIGTERM 优雅退出（8 个在途请求全部 200、隧道打开时也不阻塞，且**退出码为 0**），以及
`adminListen` 控制面/数据面分离（管理口 200、两边互相 `404`、数据面仍能代理），以及
上游连接亲和（`upstream-affinity`：8 条 keep-alive 客户端 × 200 请求只新建 ≤10 条上游
连接，空闲超过 `upstreamIdleTimeoutMillis` 后专属连接回池，池里的连接随后被独立巡检关掉
——`healthCheck.intervalMillis` 配成 60s 也照样在超时后回收）。

WebSocket 用例是有意义的版本回归：haproxy 3.0 会自己校验握手（请求缺
`Sec-WebSocket-Key` 回 400，101 缺 `Sec-WebSocket-Accept` 回 502），所以自测后端按
RFC 6455 算真的 accept 值；否则请求根本到不了 setline。

**用机器上现有的 haproxy 跑一轮，不强制版本**：片段里的写法要求 2.0+，但具体小版本由
环境决定（开发机是什么就跑什么）。要指定二进制可设
`HAPROXY_BINARIES=/path/to/haproxy`（多个用逗号分隔，各跑一轮）：

```bash
scripts/e2e.sh
HAPROXY_BINARIES=/opt/haproxy-2.2.9/haproxy scripts/e2e.sh
```

如果本机没有 haproxy，脚本直接报错退出并提示设置 `HAPROXY_BINARIES`；想覆盖多个大版本，
自己准备二进制并在提交说明里记下版本号即可，脚本不负责下载或编译 haproxy。

`scripts/bench.sh` 用 `ab` 出数值，所有性能结论都必须来自它，不接受「感觉快了」。

基准后端是 `scripts/bench_backend.d`（`ldc2 -O3 -release` 现编现用），不是 e2e 那个
`e2e_backend.py`：后者是 Python，GIL 把上限压到约 35k RPS，测 setline 的扩展性时它会先
饱和——多实例 RPS 比 1 实例只高 1.7× 就是这么来的。要对比多实例，用环境变量：

```bash
SETLINE_INSTANCES=1 scripts/bench.sh    # 单实例基线
SETLINE_INSTANCES=4 scripts/bench.sh    # 4 实例（reusePort）
```

`bench.sh` 还会做一次头部长度扫描（`header_bytes` 那几行），量的是 setline 自己的 CPU
时间除以请求数与头字节数：增量扫描下「每字节 CPU」随头长下降，平方实现下不降反升。
撑大请求头的客户端是 `scripts/bench_headers.py`——`ab` 把请求拼在 8KB 的固定缓冲里，
头一长就被截断。

加了 `BENCH_HAPROXY=1` 之后还会跑一遍 `ab -> haproxy -> setline -> 后端`：前面几段的
「并发」就是 ab 到 setline 的连接数，而真实部署中间还有一层 haproxy，它按自己的连接池
把请求映射到「haproxy -> setline」的连接上，setline 侧看到的客户端连接数才是稳态上游
连接数的口径。这一段的输出是 `haproxy_shape` 行（rps/p99/上游新建数/复用次数/TIME_WAIT
增量），haproxy 取 `PATH` 里的那个，也可以用 `BENCH_HAPROXY_BIN=/path/to/haproxy` 指定。

**测之前先等 TIME_WAIT 排空**（`ss -tan state time-wait | wc -l`）：本机临时端口区间
只有 28k 个，残留的 TIME_WAIT（60s）会让 connect 拿不到端口，吞吐和 CPU/请求都会失真。
