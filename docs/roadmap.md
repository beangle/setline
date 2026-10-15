# setline 改进路线图

本文是 setline 的改进指南，也是「什么该做、什么不该做」的判据：新需求先进这里定级，
再动手；每条改完把结论写回对应文档，并在本文勾掉。

## 定位：setline 是代理后面的代理

**setline 只部署在 haproxy / nginx 之后，永远不是用户访问的第一站。** 两种部署形态都成立：

```
推荐：setline 只渲染片段，haproxy/nginx 直接回源
  客户端 → haproxy/nginx（TLS、限流、超时、日志、HTTP/2）→ 本机后端
                        └─(读路由表 / 收片段)─ setline

下级代理：setline 承接数据面
  客户端 → haproxy/nginx → setline（host+path 路由）→ 本机后端
```

外部请求先被前置代理收敛成「格式合法、大小有界、速率可控」的 HTTP/1.1 请求，才交给
setline；setline 只负责按 host 和路径前缀选一个本机端口、把请求原样转发、支持运行时改
路由。它不面对不可信客户端，也不承担入口职责。

因此 setline **可以假设**前置代理已经做了这些事，自己不重复实现：

| 前置代理负责 | setline 的对应做法 |
|---|---|
| TLS 终结、HTTP/2/HTTP/3、证书 | 只讲 HTTP/1.x 明文，只连 `127.0.0.1:<业务端口>` |
| 请求/响应头大小上限、畸形报文拒绝 | 不做入口级校验（只保留便宜的防御性上限，见 P1） |
| `timeout client`、slowloris/慢速攻击防护 | 不实现客户端侧速率与空闲保护 |
| 连接数限制、限流、WAF、认证 | 只有一个兜底的 `maxConnections` |
| 访问日志、埋点 | 代理路径不写日志（需要时靠前置代理的日志 + `status.json`） |
| `X-Forwarded-For` 等信任边界头 | 原样透传，不自己生成 |

它**必须自己负责**的是前置代理看不到的那一段：到本机后端的连接、响应体的 HTTP 语义、
路由表的热更新、以及自己的资源回收（fd、连接池、卡死后端）。

> **前提**：作为数据面代理时，setline 的 `listen` 必须只绑回环
> （`"listen": "127.0.0.1:8080"`）。管理接口按方法分挂两个监听：写（`PUT`/`DELETE`）
> 只在 `adminListen`（缺省 `127.0.0.1:10080`），数据面 `listen` 只承接 peer 协议
> （`GET /_setline/routes`）一个读端点。读的准入是**来源地址**（本机，或 `peerReaders`
> 里列出的读方），而经本机前置代理转发的请求来源就是回环，所以前置代理必须显式拒掉
> `/_setline`（至少是 `/_setline/routes`），否则非本机读会被当成本机读放行。一旦把
> `listen` 绑 `*`，数据面就被绕过前置代理直接访问——上面「可以假设」的清单立刻失效，
> 本文的「不做」条目也全部作废。

## 不做清单（Out of scope）

定位决定边界。下面这些明确不做，除非定位本身改变：

| 事项 | 为什么不做 |
|---|---|
| TLS/证书、HTTP/2、HTTP/3、h2c | 前置代理终结；setline 只讲 HTTP/1.x 明文 |
| 客户端超时、慢速攻击防护、并发熔断 | 前置代理的 `timeout client` / `limit` 是正确位置 |
| 完整入口级请求校验 | 实测 haproxy 会在入口直接 `400 Bad request`；setline 只保留头上限和 P1-5 的一次性 framing 一致性拒绝 |
| 认证、鉴权、限流、WAF | 属于上游职责；setline 只管本机路由 |
| 访问日志、计费日志 | 前置代理的日志已覆盖；setline 只保留 `status.json` 这类状态视图。唯一例外是 P2-1 的 `accessLog`：默认关闭、只作排障用，不构成第二份统计口径 |
| 到远端后端的直连、unix socket 后端 | 后端固定 `127.0.0.1:<port>`；跨机交给前置代理 |
| URL 改写、缓存、压缩、cookie 处理 | 透明转发，不解释业务内容 |
| 加权/一致性哈希/粘性会话等调度算法 | 多端口只做随机 + 健康过滤；算法交给前置代理 |

## 目标与验收方式

只有两根轴：**正确性**（不破坏合法 HTTP 语义）和**性能**（高 RPS、大并发下开销可接受）。
所有性能结论必须来自可复现的基准，不接受「感觉快了」；所有正确性结论必须有端到端用例或
单测，不接受「看代码应该没问题」。

## 2026-10-14 验证记录

- `dub test --compiler=ldc2`：92 通过、0 失败。
- `dub build --build=release-nobounds --compiler=ldc2` 成功。
- `scripts/e2e.sh`：用机器上现有的 haproxy（本机 3.0.25）跑一轮，13 项全绿（1xx、
  Expect、HTTP/1.0、连接关闭界定响应、HEAD/204/304、请求报文边界、上游连接复用、
  上游读超时、客户端中断 fd 回收、status.json 计数、访问日志、listen:false 渲染）。
- P2-1、P2-2、P2-3 完成后重跑 e2e：本机 haproxy 3.0.25 全绿，新增
  `render-only`、`status.json reports pool and per-port counters`、
  `access log records proxied requests`、`graceful` 四项检查通过。
  `graceful` 会核对 setline 的**退出码必须是 0**（只查「进程没了」会漏掉被信号杀掉的情况）。
- P2-5 完成后重跑 e2e：本机 haproxy 3.0.25 全绿，新增
  `WebSocket tunnel echoes both directions`、`websocket-idle`（单向流量不被误杀 +
  静默隧道 501ms 断开且被计数）、`graceful` 里追加「隧道打开时 SIGTERM 仍以 0 退出」
  三项检查通过。
- 1 实例最终基准（c8/c64=2000/4000、1MB=300）：顺序 13694 RPS/P99 0ms，
  c8 23100/1ms，c64 21618/7ms，1MB 408.29 RPS/P99 38ms；
  稳态新建上游连接 0/秒、TIME_WAIT delta 0。
- 4 实例（`reusePort=true`）同口径：顺序 13403 RPS/P99 0ms，
  c8 39530/1ms，c64 32891/14ms，1MB 1118.44 RPS/P99 19ms。
  c8/c64 相对 1 实例只有 1.71×/1.52×，P1-1 仍不标完成。
- P2-5 之后重跑 1 实例基准（每档 3 轮）：顺序 11287–12543 RPS/P99 0ms、
  c8 18767–19722 RPS、c64 14708–16497 RPS、1MB 303–360 RPS。用改动前的二进制
  （同一份源码去掉 P2-5）交替跑同样 3 轮：顺序 10630–12258、c8 17081–19751、
  c64 14891–17519、1MB 330–338，两轮区间完全重叠。绝对值比上面那次整体低约 10%，
  是这台机器当时的负载，不是本次改动——P2-5 的新增代码只在 WebSocket 路径上，
  HTTP 热路径只多了一个「这条请求是否已交给隧道」的布尔判断。
- P2-4 完成后重跑：`dub test --compiler=ldc2` 94 通过、0 失败；`scripts/e2e.sh`
  全绿，新增 `admin-listen` 一项。该项同时核对 setline 退出码为 0、日志里没有
  `leaking eventcore driver` 告警（空闲上游连接池在退出时确实关了）。
- P1-1/P1-2 完成后重跑：`dub test --compiler=ldc2` 94 通过、0 失败；`scripts/e2e.sh`
  全绿。基准这轮换掉了 Python 后端（`scripts/bench_backend.d`），并新增头部长度
  扫描与 `scripts/bench_headers.py`。
- P1-1 最终口径（先等 TIME_WAIT 排空再测，`ab -n 40000`）：1 实例 c64/c128 =
  20006/19508 RPS（40µs CPU/请求，单核 80% 利用率——单实例的上限就是一颗核）；
  4 实例 = 65841/65430 RPS，即 3.29×/3.35×；每请求 CPU 40→48µs，四个实例平均
  利用率 76%，差距不在 setline。之前记的 1.71×/1.52× 是 Python 后端 GIL 的
  约 35k RPS 天花板造成的，不是 setline 的扩展性问题。
- P1-2 头部长度扫描（单实例，每档 8000 请求，只算 setline 自身 CPU）：
  0/1K/4K/16K/32K/48K 字节 = 43.8/46.2/55.0/83.8/126.2/167.5 µs，边际成本恒为
  2.5 ns/头字节。把 `HttpHeadScanner.feed` 改成每次从 0 重扫做对照，同样档位 =
  43.8/47.5/60.0/113.8/216.2/348.8 µs，每字节成本稳定在 ~7 ns（成本 ∝ n²），
  48KB 处比增量实现慢 2.1×。
- P1-7 完成后重跑：`dub test --compiler=ldc2` 95 通过、0 失败；`scripts/e2e.sh` 全绿，
  新增 `upstream-affinity` 一项（8 条 keep-alive 客户端 × 200 请求只新建 1 条上游连接，
  空闲 1s 后 8 条专属连接全部回池）。`BENCH_HAPROXY=1 scripts/bench.sh`（单实例，TIME_WAIT
  先排空）——直连：序号/c8/c64 = 16542/26044/24018 RPS（p99 0/1/5ms），1MB 390 RPS/40ms，
  顺序请求新建 0 条上游连接、TIME_WAIT 峰值增量 0；haproxy 形态：c8/c64 =
  23001/22247 RPS（p99 1/4ms），上游新建 0/32 条、TIME_WAIT 增量 0/0。
- P1-7 的做法与口径：池子容量治不了根——只要容量小于并发，被挤掉的连接就得重连，
  而每次关闭都在 setline 自己的临时端口上留一个 `TIME_WAIT`。改成**一条客户端连接一条
  上游连接**（跨请求保留）后，关闭只发生在客户端连接消失时，也就是前置代理决定的
  连接周转率，与请求速率脱钩；兜底池只用来接住已关闭客户端连接还回来的连接，容量跟随
  近期并发高水位（4..32），不是「并发上限」。
- 真实形态要先看清 haproxy 的行为：`http-reuse` 默认 `safe`，它给每个客户端连接各开一条
  到 setline 的连接，空闲连接不会无条件借给新客户端连接（实测 8 个并发客户端 =
  setline 侧 9 条客户端连接、8 条租约）。所以「上游新建连接数」在这种形态下约等于
  haproxy 到 setline 的连接数，而不是请求数；要复现这个形态用 `BENCH_HAPROXY=1
  scripts/bench.sh`。量 churn 的口径统一用 setline 自己的 `counters.upstreamConnects`，
  后端的 `accepts` 会把统计请求自身也算一次，且经过 haproxy 时数到的是代理的连接数。
- 专属上游连接在进程退出时仍会被 eventcore 记为活动句柄（`leaking eventcore driver`）：
  只要还有 task 引用着连接对象，句柄就释放不掉——这跟之前客户端连接的表现一致。真正需要
  显式关闭的只有空闲池里的连接（没有 task 引用），退出路径已经这么做了。
- P1-7 补单测 + 解耦池巡检：`dub test --compiler=ldc2` 96 通过、0 失败。把容量计算抽成纯
  函数 `raisedUpstreamPeak` / `decayedUpstreamPeak(peak, elapsedMillis)` /
  `upstreamPoolCapacityForPeak`（`upstreamPoolCapacity`、借出记账和 `sweepUpstreamPool` 都
  改为调它们），单测覆盖：借出只涨不落、容量 clamp 到 4..32、衰减按真实时间（半衰期 30s
  折半、时间 0 不动、到下限停住），再走一遍全局路径（连续借出 9 次 → 容量 9，归还只降借出
  数、高水位不变，`sweepUpstreamPool(Duration)` 按喂进去的时间逐轮衰减回 4），测试结束把
  全局状态还原。
- 池巡检原本挂在健康检查循环末尾（`src/setline/health.d`），于是 `healthCheck.intervalMillis`
  顺带决定了池回收精度和高水位回落速度：配成 60s 时池里连接要留到 60s 才可能被关、高水位
  要十几分钟才回落到下限。改成独立 task `runUpstreamPoolJanitor`（1s 一轮，`server.d` 里
  与 `healthTask` 一起启动、退出时一起 `interrupt`），把实际经过时间传给 `sweepUpstreamPool`
  按半衰期衰减。e2e 的 `upstream-affinity` 因此新增一步：在 `healthCheck.intervalMillis=60000`
  下等 `upstreamIdle` 回落到 0 并断言（12s 窗口内）。把 `upstreamPoolSweepMillis` 临时改回
  60s 复现旧耦合，该断言如预期失败（`idle pool kept 8 connections past upstreamIdleTimeoutMillis`），
  证明它确实卡得住这个回归。e2e 里 `upstreamIdleTimeoutMillis` 从 1s 提到 3s（`POOL_IDLE_MILLIS`），
  让「已回池」和「池已清空」两段都稳定可观察。
- 这一轮暴露的新问题记为 P1-7：并发超过池上限 4 之后约 8% 的请求要新建上游连接，
  TIME_WAIT 随请求数增长；临时端口被自己耗尽后吞吐会从 65k 掉到 17k 并开始报错。
  本轮没有改这个行为，只是把它量化了。P1-7 已修，见下面 P1-7 行与验证记录。
- 代码走查（本轮）修掉一个「响应流被污染」的缺陷：`forward` 只对读超时区分「响应头是否
  已经发出」，其它异常（响应体被上游截断时的 `Reached end of stream while reading data.`、
  隧道中途出错、client 断开）一律原样抛给 `handleRequest`，于是外层 catch 会在**已经发出的
  响应头后面**再补一个 `502`——状态行和错误文本直接混进响应体，已经声明 `Content-Length`
  的情况下前置代理会把它当成响应内容甚至判成协议错误。改法：`forward`/`forwardWebSocket`
  在最终响应头写出后统一抛新的 `ResponseStartedException`，`handleRequest` 只记一行访问日志
  并截断连接（`configuration.md` 的 `readTimeoutMillis` 一节本来就是这么写的口径，代码终于
  和文档一致）。e2e 新增 `truncated upstream response is not followed by a synthetic
  response`：后端 `/truncate` 声明 `Content-Length: 32` 却只发 4 字节，用例直接打 setline
  数报文里出现的状态行个数（补发的状态行紧跟在 body 字节后面、没有换行，所以必须全文计数
  而不是只数行首）。用 HEAD 源码另建一份二进制做对照：旧实现 2 条状态行，用例如预期失败。
- 同一轮走查的其它修正：`upstreamReadTimedOut` 改为按 `vibe.core.net.ReadTimeoutException`
  类型判断（原来比类名字符串，多一层包装就静默失效）；`Content-Length` 按 RFC 9110 收紧成
  `1*DIGIT`（`to!long` 会接受 `+5` 甚至 `-1`，后者被判成「合法但为负」→ 退化成「没有长度」，
  framing 冲突从入口漏掉）；framing 冲突的响应不再进上游连接复用；`tunnel` 改用
  `scope(exit)` 保证异常路径也关掉两端；删掉两处没有调用方的公开函数
  （`http.readHttpRequest`、`router.upsertRoute`），注释／文档补齐（`ForwardResult` 字段、
  `responseBodyDelimited`、`watchClientDisconnect`，`configuration.md` 新增「报文边界（framing）」
  一节）。`dub test --compiler=ldc2` 100 通过、0 失败；`scripts/e2e.sh` 全绿。走查收尾又补了
  几处纯函数单测：`escapeHtml` 的单引号分支、状态页／状态 JSON 的 `adminListen` 分支、
  `queryValue` 里「参数没有 `=`」和「名字不匹配继续往后找」两条路径、以及 `state` 删掉最后
  一条路由后整个 host 组要消失（含 host 不存在时 `deleteRoute` 返回 `false`）。这几处把
  `admin.d` 行覆盖 126→136、`state.d` 167→177、`util.d` 26→29。
- 走查还挖出一个测试基础设施缺陷：`silly` 用 `std.parallelism.parallel` **并发**跑 unittest，
  而 `proxy_test.d` 里两个上游池测试共用进程级状态（`gUpstreamLeased`／`gUpstreamPeak`）。
  「sizes the idle upstream pool」断言 `leasedUpstreamCount() == 0`，会读到另一个测试
  `noteUpstreamLeaseAcquired` 之后、归还之前的中间态，实测约 12%（5/40）随机失败，掩盖了
  真实回归信号。给两个池测试都套上项目已有的 `withStateTestLock` 后连跑 60 次全绿。
- **已知偏差（本轮未改）**：setline 把 client 的 FIN（半关闭）当成「放弃本次请求」——
  `watchClientDisconnect` 看到 `noMoreData` 就关掉上游，于是 `printf ... | nc` 这种「发完请求就
  `shutdown(WR)`、再读响应」的客户端会拿到 `502`（复现：直连 setline 用管道喂一个普通
  `GET /ok`）。这是 P0-4「客户端放弃后立即回收 fd」的实现代价：epoll 层面分不出「半关闭等着
  读响应」和「真的走了」，而此刻阻塞在上游读上的 task 只能靠关连接唤醒。前置代理
  （haproxy/nginx）在转发响应期间不会半关闭到 setline 的连接，推荐部署形态下撞不到；要支持
  直连半关闭的客户端，就得改成「FIN 后不中断上游读、靠 `readTimeoutMillis` 和写失败兜底」，
  代价是 P0-4 的 fd 回收从「立即」变成「最多一个读超时」。e2e 里走代理路径的探针因此一律走
  haproxy，新加的截断用例用 bash `/dev/tcp` 拿读写双向 fd、不半关闭。

## P0：阻塞生产使用

| # | 项目 | 状态 | 现状（证据） | 目标 | 验收 |
|---|---|---|---|---|---|
| P0-1 | 建立基准与端到端脚手架 | 已完成 | `scripts/e2e.sh` 用机器上现有的 haproxy 跑一轮（本机 3.0.25，13 项全绿），`scripts/bench.sh` 出性能数值 | `scripts/bench.sh`（顺序 RPS、8/64 并发 RPS、P99、1MB 响应吞吐、每秒新建上游连接数、TIME_WAIT 峰值）+ `scripts/e2e.sh`（真实 haproxy，用机器上现有的版本，可用 `HAPROXY_BINARIES` 指定） | 每次改动前后各跑一次，数值记进 PR/提交说明；跑的是哪个版本就记哪个版本 |
| P0-2 | 1xx 中间响应被当成最终响应 | 已完成 | 单测覆盖 1xx/最终响应同段与异段；e2e 覆盖 Expect POST 和 103 + 200 | 透传中间响应（100/103 可多条）后继续读最终响应；修正「同一次 read 里 1xx 之后的字节」的处理，不能当 body 直接甩给客户端 | e2e：Expect POST = 200 且无超时；103 + 200 都到客户端；单测覆盖 1xx 与最终响应同段/异段/带 body |
| P0-3 | 后端连接复用 | 已完成 | 每端口小池 + 30s 空闲超时；e2e 的 50 个顺序请求仅新建 1 条上游连接，新增 1000 请求仍为 0 条/秒、TIME_WAIT delta 0 | 按端口维护空闲连接池：响应边界明确且响应头没有 `Connection: close` 时放回；发送前发现空闲连接已 EOF 就换新连接（尚未发出任何字节，重试安全）；池上限 + 空闲超时 | 稳态下「每秒新建上游连接数」≈ 0；TIME_WAIT 不随请求数增长；e2e 全绿 |
| P0-4 | 资源回收与上游读超时 | 已完成 | 新增 `readTimeoutMillis`；e2e 的卡死后端返回 504，客户端放弃后 fd 在观察窗内回落到起点。「客户端放弃」的判据是 client 侧 FIN：见验证记录里的已知偏差（半关闭的客户端也会被当成放弃） | 客户端断开立即中断上游并释放两端；上游读加超时（新配置 `readTimeoutMillis`，超时回 504 并回收） | e2e：卡死后端场景下客户端放弃后 1s 内 setline fd 数回落；上游超时能主动 504 |

## P1：性能与容量

| # | 项目 | 状态 | 说明 | 验收 |
|---|---|---|---|---|
| P1-1 | 单核 → 多实例 | 已完成 | `reusePort` 接通 Linux `SO_REUSEPORT`。之前记的 1.71×/1.52× 是**基准的后端**造成的：`scripts/e2e_backend.py` 是 Python，GIL 把上限压到约 35k RPS，4 实例正好撞上这个天花板。换成 D 写的 `scripts/bench_backend.d`（一连接一线程，无 GIL，单进程 c8 即 128k RPS）后，同一台机器上 4 实例 c64/c128 = 65841/65430 RPS，是 1 实例（20006/19508）的 3.29×/3.35×；每请求 CPU 只从 40µs 升到 48µs，四个实例平均利用率 76%，没被 setline 自己打满——剩下的差距在 ab 单线程客户端和 loopback 软中断 | 4 实例下并发 RPS 接近线性（基准对比 1 实例） |
| P1-2 | 头解析改增量扫描 + 防御性上限 | 已完成 | 增量扫描和 64KB 上限已有单测，本轮补上基准证据。`scripts/bench.sh` 新增头部长度扫描（客户端是 `scripts/bench_headers.py`：`ab` 的请求缓冲只有 8KB，头再长就被截断），从 `/proc/<pid>/stat` 采 setline 的 CPU：0/1K/4K/16K/32K/48K 字节 = 43.8/46.2/55.0/83.8/126.2/167.5 µs，边际成本恒为 2.5 ns/头字节。把 `HttpHeadScanner.feed` 改回每次从 0 重扫做对照：43.8/47.5/60.0/113.8/216.2/348.8 µs，「每字节 CPU」稳定在 ~7 ns 即成本 ∝ n²，48KB 处慢 2.1× | 单测覆盖上限；基准里 CPU 不随头长平方增长 |
| P1-3 | fd 预算口径 | 已完成 | 启动时按 `2×maxConnections+64` 对照 `RLIMIT_NOFILE` 告警；unit 覆盖 1→66、65535→131134；包内 `LimitNOFILE=131134`；部署文档把公式拆开写清：`2×maxConnections` = 每条客户端连接一个 socket + 亲和租给它的一条上游 socket（亲和态是常态，不是最坏情况），`64` = 监听（数据面 + 可选 `adminListen`）、eventcore 的 epoll/eventfd/timerfd、逐个执行的健康探测、`--sync-map` 管理 socket、回收留下的空闲池（每端口 ≤32）；并写明多端口时余量不够，真实上界是 `2×maxConnections+64+32×端口数`。`configuration.md` 与 `README.md` 各留一句指到该节 | 启动时按 `2×maxConnections+64` 校验 `LimitNOFILE` 并告警；包里的 `LimitNOFILE` 按公式给值；文档写明公式并解释每一项 |
| P1-4 | I/O 缓冲调大 | 已完成 | 四个 relay 路径统一为 32KB；同后端 6 轮 A/B：8KB→32KB 的 1MB RPS 338.00→344.95，P99 46.0→45.17ms | 1MB 响应吞吐基准提升且 P99 不退化 |
| P1-5 | 报文边界从严 | 已完成 | 相同重复 CL 保留；冲突重复 CL、CL+TE、非法或非 chunked TE 在入口返回 400；`Content-Length` 只接受 `1*DIGIT`（`+5`/`-1` 不再被宽松解析成「没有长度」）；framing 冲突的响应不复用上游连接；`Connection: close` 不进 client/upstream 池，均有单测 | 单测：CL+TE 并存、重复 CL、带符号或非数字 CL、`Connection: close` 立即出池 |
| P1-6 | keep-alive 正确性回归 | 已完成 | e2e 覆盖 close、HTTP/1.0、连接关闭界定响应、HEAD/204/304，并保留 50 次顺序复用 | e2e 覆盖：`Connection: close`、HTTP/1.0、响应无长度（连接关闭界定）、HEAD/204/304 |
| P1-7 | 上游池容量与连接 churn | 已完成 | 旧判据：空闲池每端口上限 4，并发超过 4 后归还的连接挤掉最旧的，下一条请求重连——单实例 5000 请求 c=8/16/64 新建 204/501/1009 条（1.4%/2.5%/4.0%）。改为**客户端连接亲和**：每条客户端连接一条专属上游连接、跨请求保留（端口没变就继续用），背后留一个自适应兜底池（容量 = 近期并发高水位，clamp 到 4..32）接住客户端连接关闭时还回来的连接，`upstreamIdleTimeoutMillis`（默认 30s）到期回收。池巡检（回收 + 高水位衰减）是独立 task，1s 一轮、按真实经过时间衰减（半衰期 30s），不跟随 `healthCheck.intervalMillis`。A/B（16 核单实例 c=64、20k 请求、TIME_WAIT 先排空）：新建上游连接 2059-2202 → 56-64（直连）、1593-2038 → 0-64（haproxy 形态）；TIME_WAIT 峰值增量 1988-2240 → 0-92；RPS 18325-18803 → 22820-23312（直连）、16136-18245 → 21332-22175（haproxy）；p99 8-9ms → 4-5ms。`scripts/bench.sh` 新增 `BENCH_HAPROXY=1` 复现真实形态 | 高并发稳态下新建上游连接数≈客户端连接数、TIME_WAIT 不随请求数增长（P0-3 的判据在 c8 以上也成立）；e2e 新增用例：8 条 keep-alive 客户端 × 200 请求只新建 ≤10 条上游连接，且空闲 `upstreamIdleTimeoutMillis` 后专属连接回池、池内连接随后被独立巡检关掉（`healthCheck.intervalMillis` 配成 60s 也照样回收） |

## P2：可运维性

| # | 项目 | 状态 | 说明 |
|---|---|---|---|
| P2-1 | 观测 | 已完成 | `status.json` 增加 `counters`（空闲池命中、新建上游连接、上游读超时、unhealthy 转换、每端口请求数）；新增 `accessLog` 开关（默认关闭），每请求一行；e2e 覆盖 |
| P2-2 | 优雅退出 | 已完成 | 自己接管 SIGTERM/SIGINT（先 `disableDefaultSignalHandlers`，再装只累加计数的 async-signal-safe handler，并补回 `SIGPIPE=SIG_IGN`）；信号到达后停监听、等在途请求归零再 `exitEventLoop`，第二次信号立即退出；`setline.service` 显式给 `TimeoutStopSec=30`（大于默认 `readTimeoutMillis`）。e2e `graceful`：haproxy 后面 8 个 400ms 在途请求全部 200、退出码 0；手工验证停监听后新连接被拒、在途请求仍 200 |
| P2-3 | 只渲染不监听 | 已完成 | `"listen": false`：纯渲染部署，渲染片段后退出；要求 `agent.type`；e2e 覆盖片段落地 |
| P2-4 | 控制面与数据面分离 | 已完成 | 新增 `adminListen`：管理面单独监听，只服务 `/_setline/*`、其余一律 `404` 且不走路由表；数据面反过来不再认 `/_setline/*`（P2-7 起改为只承接其中的读，写仍不过数据面）。校验拒绝 `true`、拒绝与 `listen` 重合（含 `*:port` 与具体地址同端口）、拒绝与 `listen:false` 同用。`status.json` 多 `adminListen` 字段（P2-7 起移除）；启动日志打印 `setline admin listening on ...`。e2e `admin-listen`：管理口 200 / 根路径 404 / 数据面 `/_setline` 404（P2-7 起读改判 200）/ 数据面仍能代理 / 退出码 0。顺带修掉空闲上游连接池在退出时不关闭导致 eventcore 报 `leaking eventcore driver` 的告警 |
| P2-5 | WebSocket 隧道纳入超时与统计 | 已完成 | 新增 `webSocketIdleTimeoutMillis`（默认 `0` 不断开；只在**两个方向都没字节**时计时，单侧推送不算空闲）；`status.json` 增加 `activeWebSockets` 与 `counters.webSocketTunnels/webSocketIdleTimeouts/webSocketBytes*`。同时修掉隧道与优雅退出的冲突：101 之后不再算「在途请求」，否则一条隧道会把重启拖到 `TimeoutStopSec`。e2e 覆盖双向回显、单向流量不被误杀、静默隧道到点断开、隧道打开时 SIGTERM 仍能退出 |
| P2-6 | 管理口强制独立（缺省端口见 P2-7） | 已完成 | `adminListen` 从可选开关变成固定形态：管理接口永远有自己的监听。`"adminListen": false` 报错（不再表示共用 `listen`）；`listen: false` 时不允许写 `adminListen`；`listen` 落在缺省管理端口上、又没显式写 `adminListen` 时单独报错。缺省端口选型：18080 被 podman/pasta 的随机端口转发撞上，9080 是 WebSphere 默认、8088 是 Hadoop YARN 默认，最后取本机空闲且无主流软件默认的 10080（当时绑 `*`，P2-7 起改为回环）。`serve()` 里改成两个监听都绑成功才打印地址，管理口绑不上时给出指名 `adminListen` 的报错。删掉 `Config.adminListenEnabled` / `adminListenSeparated()`。单测覆盖缺省值、`false`、重合、缺省端口冲突；e2e 补「管理口 status.json 不含 adminListen」并把主实例管理口固定到独立端口 |
| P2-7 | peer 读挂数据面、写留管理口，管理口缺省回环 | 已完成 | 管理接口按方法分挂两个监听：**读**（`GET`）同时挂在数据面 `listen` 和管理口上（P2-8 收窄为只有 `/_setline/routes`），**写**（`PUT`/`DELETE /_setline/routes*`）只在管理口；数据面收到非 `GET` 的 `/_setline/*` 一律 `404`、连路由表都不查。外界于是只需知道业务端口就能读，管理口不必暴露，`adminListen` 缺省从 `*:10080` 改为 `127.0.0.1:10080`——读既然能从 `listen` 走，管理口只留写，而写绑回环让「只有本机能改路由」成为 TCP 层事实，不再依赖可被代理改写的 `Host` 判定（那条判定作为纵深防御保留）。`status.json` 不再输出 `adminListen`（面向机器读取），地址只出现在状态页 HTML 与启动日志；绑非回环时启动日志写明读接口的可达范围。单测覆盖缺省回环、`listen` 落在缺省管理端口上的冲突、`status.json` 无 `adminListen`；e2e 与 haproxy 用例改为「数据面读 200 / 数据面写 404 / 管理口读 200」 |
| P2-8 | 数据面只承接 peer 协议一个端点 | 已完成 | 数据面 `listen` 上的 `/_setline` 从「所有读」收窄为**只有 `GET /_setline/routes`**（`setline.util.peerRoutesPath`），其余（`status`、`status.html`、`status.json`，以及任何非 GET）一律 `404`、不查路由表。理由：路由表接口是 peer 协议（`agent.peers` 采集）唯一需要的跨机读，有明确的形状和解析器；状态页与 `status.json` 没有跨机消费者，却含监听地址、超时、`maxConnections`、健康检查调参、计数器和整张路由表，而 `status.json` 还是我们仍在自由改动的内部结构（P2-7 刚删过 `adminListen` 字段）——把「跨网可达面」绑在它上面等于给自己加兼容性负担，也让前置代理漏掉 `deny /_setline` 时的泄露面从「路由表」放大成「整幅运行画像」。代价是跨机监控 `status.json` 失去数据面通路，必须直连 `adminListen`（显式放开 + 把采集机写进 `peerReaders`，P2-9 起不再有 token）或在代理本机采集；这是有意的收窄，已写进 `docs/configuration.md` 与 `docs/deployment.md`。e2e：数据面 `/_setline/routes` 按来源放行（本机 200、未列入的地址 403），数据面 `status.json` 一律 `404`；单测不涉及（该分派在 TCP 入口） |
| P2-9 | 用来源地址互信替掉读写两处的 token | 已完成 | 删除 setline 里所有凭据：`adminToken`、`agent.token` 与 `peers[].token`（不是弃用，是删除：整条链路只看来源地址），新增顶层 `peerReaders`（地址字面量数组）作为读接口唯一的跨机准入。规则收敛成两条：**读 = 本机来源 或 来源地址在 `peerReaders` 里**（不看 Host），**写 = 回环对端 且 回环 Host**（不变）。理由：这条链路上唯一的跨机读方是另一台 setline（`setline -f` 按 `agent.peers[].url` 拉路由表），机器对机器、读方固定；给它配一份要在两台机器上同步的秘密，换不来比源地址更实在的东西——token 走明文 HTTP，抓到流量即可复用，源地址无法被嗅探复用（伪造 TCP 源地址需要位置且拿不到回程）。代价是名单本身要维护（换读方要改被读端），且读方经 NAT/L4 代理接入时名单只能写代理地址（等于放行它后面所有人），这一点写进 `docs/configuration.md`。`peerReaders` 只收数值地址：主机名会把安全判定绑在 DNS 上，CIDR 要按位比较（规则就不再是「一行地址」），列出回环地址按空操作报错。启动日志打印生效名单（写错地址的表现是 403，而 403 本身看不出名单是什么）。单测：地址归一化（大小写 / 空白 / `::ffff:` 映射）、字面量校验、名单匹配、配置拒绝主机名与 CIDR 与回环与空数组与 `listen:false` 同用、两个旧 key 的报错；e2e：`peerReaders` 里列出的本机非回环地址读得到、没列的 403、列出的读方也改不了路由，读侧带公开 Host 仍是 200（记录在案的取舍：前置代理的 `deny /_setline` 才是那道门） |

## 已完成（判据来源）

- setline 现在不持有任何凭据：读接口按来源地址放行（`peerReaders`），写接口按「回环对端 +
  回环 Host」放行。删掉 `adminToken`、`agent.token`、`peers[].token` 与 `isAuthorized`，
  读侧的 `X-Setline-Token` 头和 401 分支随之消失，读不再看 `Host`（本机调用方可能按公开
  主机名访问），取而代之的是 `rejectUnlistedReader` 的 403。地址比较只做归一化文本匹配：
  去空白、转小写、去掉 `::ffff:` 映射前缀（双栈监听上的 IPv4 对端），因此 `::ffff:10.0.1.7`
  和配置里的 `10.0.1.7` 是同一个地址；`peerReaders` 只收字面量，主机名（DNS）与 CIDR
  （按位比较）都在配置解析阶段报错，列回环地址按空操作报错。读方的 `agent.peers[].url`
  与它之间不再有任何配套字段——两台机器上只有「地址」这一种配置。
- 管理口与数据面分家：`adminListen` 缺省 `127.0.0.1:10080`，服务写（`PUT`/`DELETE`）、
  状态页与 `status.json`；数据面 `listen` 稳定只绑回环，只承接 peer 协议一个读端点
  （`GET /_setline/routes`），所以外界只认业务端口也能读路由表。放开绑定面不放开写：
  写接口只认本机来源，且缺省绑定就是回环——「只有本机能改路由」不靠 `Host` 判定；代价只在
  读接口，用防火墙或 `peerReaders` 收敛（当时还是 `adminToken`），绑非回环时启动日志会写明。管理口地址只出现在
  状态页 HTML 和启动日志里：`status.json` 是给机器读的（采集机、面板），不暴露管理入口。
- `agent.output` 从「文件路径」收敛为「根目录」：目录名（`<output>/haproxy` 或
  `<output>/nginx`）与文件名（`setline.cfg`/`setline.conf`，规则模式再派生 `.map` 或按
  host 分文件）都由 setline 生成，不再开放文件粒度配置——它同时是 `setline-apply` 的
  `HAPROXY_FRAGMENT_DIR`/`NGINX_FRAGMENT_DIR` 与代理主配置 `include`/`-f` 的接线约定。
  子目录按需创建；`output` 非空时要求绝对路径（相对路径会随 CWD 漂移）。运维视角只剩
  「给一个可写根目录」，单测覆盖三种形态的派生路径与 stdout（空 `output`）模式。
- 去掉 `agent.bind`：片段固定只出规则和后端定义，监听段永远归代理主配置。它跟上一
  条正好相反——布局已经由程序固定，再留一个会改变「同一路径下内容契约」的开关，只会
  让 `-f <dir>` / `include` 的接线在两种语义之间摇摆。渲染器里的自包含分支
  （`renderProxyConfig`/`renderHaproxy`/`renderNginx` 与 `nginxListenPort`）一并删除；
  旧配置写了 `agent.bind` 报 `agent.bind has been removed`，不静默忽略。
- 去掉 `agent.sync`：进程每次只渲染一轮就退出，周期刷新交给 systemd timer（包内的
  `setline-render.timer`，每 30s 拉起 `setline-render.service`）。节奏统一由 systemd 管（
  `systemctl list-timers`/`journalctl` 可见），不再需要 `mode`/`intervalMillis` 两个
  配置项与进程内调度循环；旧配置写了 `agent.sync` 报 `agent.sync has been removed`。
- 去掉 `agent.remote` 与配套的 `agent.workDir`：数据来源收敛为两种——`peers` 合并对端
  路由表，或不配 `peers` 直接渲染本机路由表。registry manifest + 版本化 bundle
  （`backends.json`、sha256 校验、`workDir/releases/<version>` 解包）是一套与 `peers`
  平行、更重的集中发布链路，最终产出的片段却和 `peers` 完全一样，等于为同一个渲染器
  维护两种输入。解析与安装代码（`AgentManifest`/`loadBackendsJson`/`parseAgentManifest`/
  `installBundle`/`downloadFile`/`resolveUrl`/`parseBackends` 等）随之删除；旧配置写了
  `agent.remote` 报 `agent.remote has been removed`，写了 `agent.workDir` 报
  `agent.workDir has been removed`，不静默忽略。
- 复核「本机才能写路由」这条边界，确认它挡不住本机代理：写接口的判断依据是 TCP 对端地址，
  `remote → haproxy(默认转发全部路径) → setline` 时对端就是 `127.0.0.1`。实测经 haproxy
  `PUT /_setline/routes?host=evil.test` 返回 200、新路由被持久化进配置文件，`GET` 也不看
  `adminToken`；对照的非回环直连仍是读 401 / 写 403。结论写进 `docs/configuration.md`
  （当时的 adminToken 一节，P2-9 起是 peerReaders 一节）、`docs/runtime-routes-api.md`、`docs/deployment.md`、
  `docs/project-constraints.md`；haproxy/nginx 接线文档补上必须的
  `http-request deny if { path_beg /_setline }` / `location ^~ /_setline { return 404; }`，
  e2e 的前置代理照此接线并新增断言（代理侧 403、本机管理口仍 200）。
- 收紧管理接口的「本机」判定：从「TCP 对端是回环」改为「回环对端 **且** 请求声明的 Host 是
  回环名（`Host` / `X-Forwarded-Host`，忽略端口）」。这一维借用 micdn `getOrigin` 的口径，
  专门盯本机代理转发的请求——转发过来的是浏览器看到的公开主机名，于是写接口 403（读接口当时要
  `X-Setline-Token`，P2-9 起读不看 Host）。没有 Host 的请求一律不算本机。代理改写 Host 仍可绕过，所以定位是纵深
  防御，haproxy/nginx 接线文档里的 `deny /_setline` 保留。单测覆盖 Host 解析与四种组合，
  e2e 新增 raw-socket 用例（回环 Host 写入 200 / 公开 Host 403 / 带 `X-Forwarded-Host` 403）。
- 读接口统一成一种凭据（P2-9 起连这一种也取消，改为按来源地址）：状态页与 `status.json`
  不再用 HTTP Basic，全部改成 `X-Setline-Token`（就是当时的 `adminToken`）；`sendBasicChallenge`、`isBasicAuthorized` 与
  `std.base64` 依赖随之删除。写接口不变，仍是只认本机。e2e 的 split 实例配上 `adminToken`，
  断言「公开 Host 无 token 401 / 带 token 200 / 回环 Host + `X-Forwarded-Host` 401」。
- 顺带补上管理接口的 body 上限：`completeHttpRequest` 过去按 `Content-Length` 无限读入内存，
  现在有 4 MiB 防御性上限，超限回 `413`（数据面本来就是流式转发，不受影响）；单测覆盖边界，
  e2e 加一条超大 body 用例。
- 片段只声明 backend：不再生成 `option httpchk`（会按状态码误判 DOWN）。
- 规则模式不再往请求里塞内部头：查找键改用 `set-var` + `concat` 存在事务变量里，
  请求原样透传给后端（2.0 起通用，无需 `set-var-fmt`）。
- 路由表变化不再无条件 reload：只有 `*.map` 变了时，`setline-apply` 用
  `setline --sync-map` 通过 admin socket 就地热同步（算差量、先增改后删、回读校验）。
  socket 自动探测（`stats socket` / 单元的 `-S` / 默认位置），探不到或同步失败一律回退
  reload；不引入任何配置项。
- HAProxy 规则模式统一为 2.0+ 单套写法，map 键剥掉 Host 端口，与 setline 自己的匹配口径一致。
- `listen` 的角色在文档里讲清：数据面由前置代理直连业务端口，setline 的监听只是控制面
  （单机渲染形态下也不会被写进片段）。
- `reload` 是否真的发生有了可核对的判据（master PID 不变、worker PID 换、`show proc` 的
  `<reloads>` 计数）。
- 优雅退出踩过并修掉的坑：`TCPListener` 是**按值**传进 drain task 的，副本调用
  `stopListening()` 只标记自己无效，`shutdownServer` 再调一次就会把同一个 eventcore 句柄
  release 两遍，第二次读到已释放的 `userData` → SIGSEGV（exit 139）。改成传指针、由 drain
  task 独占停监听后，`shutdownServer` 那次自然变成空操作。教训：这类「进程确实退了」的
  用例必须同时核对退出码。
- WebSocket 这条链路上，前置代理是**真的在管握手**：haproxy 3.0 对带 `Upgrade: websocket`
  的请求缺 `Sec-WebSocket-Key` 直接回 400，对 101 里缺 `Sec-WebSocket-Accept`（或算错）
  回 502，请求根本到不了 setline。e2e 的后端因此必须做一次真握手；这同时也说明 setline
  的「原样透传」是正确的分工——握手是后端的事，setline 只负责 101 之后的字节。
- 控制面与数据面分离靠**两个监听、按方法分挂**：管理口只认 `/_setline/*`（其余 404，
  且不走路由表，所以绑 `*` 不会顺手把业务端口暴露出去），承接状态页、`status.json` 与
  全部写；数据面只承接 peer 协议（`GET /_setline/routes`）这一个读端点，其余
  `/_setline/*` 一律 404 且不查路由表。写只在管理口、且管理口缺省绑回环，于是「只有本机
  能改路由」是 TCP 层事实，不再依赖可被代理改写的 `Host` 判定（该判定作为纵深防御保留）；
  路由表读两边都能走，外界只认业务端口也能读它。
  启动阶段就把两个地址的一致性校验掉（类型、是否与 `listen` 重合、是否与 `listen:false`
  同用），不留给运行时。
- 管理接口前缀从 `/__setline` 改为 `/_setline`：更短，仍带下划线以示「内部路径」。改动
  集中在 `adminPrefix` 一处常量，其余是文档、脚本、测试的引用同步；路由前缀不得占用该
  命名空间的校验与 e2e 断言不变。
- 进程退出时上游连接池里还挂着的空闲连接必须显式关闭，否则 eventcore 会打
  `leaking eventcore driver` 告警。关池子要 `foreach (ref conn; pool)`：按值遍历会让每条
  连接在临时副本上再 `addRef` 一次，第二次 `close` 就落到已释放的 `userData` 上。
- 测扩展性之前先把「不是被测对象」的部分排除掉：Python 后端有 GIL，`ab` 的请求缓冲只有
  8KB，两者都会先于 setline 饱和；`ab` 单进程在 c≥128 时还要留意临时端口。本机
  `/proc/sys/net/ipv4/ip_local_port_range` 只有 28k 个端口，TIME_WAIT 残留（60s）会让
  后续测量整体失真——这轮就有一次「4 实例 c128 只有 17k RPS、每请求 CPU 涨到 211µs」，
  等 TIME_WAIT 排空后重测是 65k RPS/48µs。**测之前先看 `ss -tan state time-wait | wc -l`。**

## 维护约定

- 新需求先回答两个问题：它服务的是「正确性」还是「性能」？它是否落在本文的定位之外？
  定位之外的直接进「不做清单」，并写清前提。
- 每次改进都要留下可复现证据（基准数值或 e2e 用例），并在上表勾掉。
- 定位声明必须同时出现在 `README.md`、`docs/configuration.md`、
  `docs/haproxy-integration.md`、`docs/nginx-integration.md`，本文是唯一权威版本。
