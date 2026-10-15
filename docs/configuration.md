# 配置文件参考

`setline` 的配置是一个 JSON 对象。默认路径是 `setline.json`，用 `-f` 指定其他路径：

```bash
setline -f /etc/setline/setline.json      # 启动本地代理或 agent
setline -c -f /etc/setline/setline.json   # 只校验配置，不启动
```

两个入口的差别很重要：

- **启动**（`-f`）时配置文件**可以不存在**，此时只打印一条提示并按空路由表启动，
  方便先起代理再用运行时 API 加路由。
- **校验**（`-c`）时文件**必须存在**，格式、字段类型、路由合法性任何一项不通过都会
  以非零退出并打印 `Config <path> is invalid: <原因>`。

完整可运行样例见 `config.example.json`。

> **定位**：setline 只部署在 haproxy/nginx 之后，不是用户访问的第一站（详见
> `docs/roadmap.md`）。作为数据面代理时 `listen` 必须只绑回环；TLS、请求头大小限制、
> 客户端超时、限流、访问日志都由前置代理负责，setline 不重复实现。

## 顶层字段

| 字段 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `listen` | 整数、字符串或 `false` | `127.0.0.1:8080` | 监听地址；`false` 表示不监听（纯渲染），见下节 |
| `adminListen` | 整数或字符串 | `127.0.0.1:10080` | 写操作的独立监听，见「adminListen」一节 |
| `peerReaders` | 字符串数组 | `[]` | 允许跨机读路由表与状态页的来源地址，见「peerReaders」一节 |
| `connectTimeoutMillis` | 整数 > 0 | `3000` | 连接后端的 TCP 超时 |
| `readTimeoutMillis` | 整数 > 0 | `15000` | 单次上游读取的不活动超时 |
| `reusePort` | 布尔 | `false` | 同地址多进程监听时启用 Linux `SO_REUSEPORT` |
| `accessLog` | 布尔 | `false` | 每个转发的请求打一行访问日志到 stderr |
| `upstreamIdleTimeoutMillis` | 整数 > 0 | `30000` | 空闲上游连接保留多久：客户端连接亲和挂着的连接和空闲池里的连接都用它 |
| `webSocketIdleTimeoutMillis` | 整数 ≥ 0 | `0` | WebSocket 隧道两个方向都静默多久后断开；`0` 表示不断开 |
| `maxConnections` | 整数 > 0 | `65535` | 并发客户端连接上限，超出返回 `503` |
| `healthCheck` | 对象 | 见下 | 后端健康检查（始终开启，只调参数） |
| `agent` | 对象 | 无 | 边缘代理片段渲染模式，见「agent」一节（配了 `peers` 才是纯渲染机） |
| `routes` | 对象 | `{}` | host → 路径前缀 → 端口，见「routes」一节 |

`maxConnections` 是并发**连接**上限，不是请求数上限：一条连接从 `accept` 到 `close` 一直
占一个名额（空闲的 keep-alive 连接、打开的 WebSocket 隧道都算），超出时在读取请求之前
直接返回 `503`。上游连接按客户端连接亲和，每条连接都挂着一条自己的上游连接，进程的
fd 预算按 `2 * maxConnections + 64` 配 `LimitNOFILE`；每一项的来历和「多端口时 64 不够」
的边界见 `docs/deployment.md` 的 File Descriptors 一节。

`readTimeoutMillis` 限制已经连上的后端在两次读操作之间可以停顿多久。最终响应尚未开始时
超时，setline 会回收客户端和上游连接并向客户端返回 `504`；响应头一旦发出，任何后续失败
（读超时、响应体被上游截断、客户端中途断开）都只回收连接，不会再补发状态码——原因见
「报文边界（framing）」一节。空闲连接池取出连接时会重新套用这个超时。

`accessLog` 默认关闭：正常部署靠 haproxy/nginx 的访问日志就够，setline 再打一份只会重复。
打开后每个转发到后端的请求打一行 `setline access host=... method=... path=... port=... status=... duration_ms=...`；
无路由、无健康端口、连接失败等没有落到后端的情形也会记一行（`port=0`），未拿到最终响应时
`status=0`。这一行是排障用的，不是计费/统计口径——那是前置代理的职责。

`upstreamIdleTimeoutMillis` 管的是「空闲的上游连接留多久」。setline 按客户端连接做上游
连接亲和（见 `docs/deployment.md` 的连接一节）：一条 keep-alive 的客户端连接会一直握着它的
上游连接，超过这个时间没有新请求就把连接交回空闲池，空闲池里的连接也用同一个时限过期
回收。调小能更快释放 fd 和临时端口，代价是「请求间隔大于该值」的客户端连接每次都要重新
握一次上游连接；默认 30s 足够覆盖前置代理的 `timeout server` 量级。

`status.json` 里还有一组累计计数：`counters.poolHits`（上游连接复用：命中空闲池或客户端
连接亲和自带的连接）、`counters.upstreamConnects`（新建上游连接）、
`counters.upstreamTimeouts`（上游读超时）、`counters.unhealthyTransitions`（端口由健康变
离线）、`counters.portRequests`（每个后端端口的请求数）。其中 `counters.upstreamLeased`
（正挂在客户端连接上的上游连接数）和 `counters.upstreamIdle`（空闲池里的上游连接数）是
瞬时值，不是累计量。进程启动时清零，不持久化。

WebSocket 隧道单独一组：`activeWebSockets`（当前打开的隧道数）和
`counters.webSocketTunnels`（累计建立）、`counters.webSocketIdleTimeouts`（被空闲超时断开）、
`counters.webSocketBytesToUpstream` / `counters.webSocketBytesToClient`（两个方向的字节数，
不含 101 握手本身）。

`webSocketIdleTimeoutMillis` 默认 `0`：WebSocket 是长连接，空闲多久算超时由业务决定，
常规位置是前置代理的 `timeout tunnel`。设成正数时它只是资源回收的兜底，而且只在**两个
方向都没有字节**时才计时——只有一侧在动（例如后端只推、客户端不回）不算空闲。要注意
101 之后隧道不算「在途请求」：优雅退出不会等它自然结束，进程退出时隧道随之断开。

`reusePort` 只是监听能力开关：它把 Linux 的 `SO_REUSEPORT` 交给 `listenTCP`，让多个
setline 进程可以绑定完全相同的地址。默认关闭，避免无意间让多个拥有独立路由状态的进程
分摊管理接口。启用前必须让所有实例加载相同配置并维持路由同步；设置开关本身不等于已经
完成多实例扩展验证，见 `docs/deployment.md` 的多实例一节。

### healthCheck

| 字段 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `intervalMillis` | 整数 > 0 | `5000` | 检查周期 |
| `timeoutMillis` | 整数 > 0 | `1000` | 单次 TCP connect 超时 |
| `unhealthyThreshold` | 整数 > 0 | `2` | 连续失败多少次标记离线 |
| `healthyThreshold` | 整数 > 0 | `1` | 连续成功多少次标记恢复 |

健康检查是 TCP connect 到 `127.0.0.1:<port>`，只维护在线状态，不主动探测 HTTP 路径。
这个周期只管探测：空闲上游连接池的回收（过期和超容量）由独立的后台巡检按自己的 1s 节奏
做，高水位也按真实经过时间衰减，所以把 `intervalMillis` 调大不会让池里的连接多留那么久。

## listen 的写法

| 写法 | 结果 |
|---|---|
| `8080` 或 `"8080"` | 绑定 `127.0.0.1:8080` |
| `"127.0.0.1:8080"` | 绑定指定地址 |
| `"192.168.1.10:8080"` | 绑定指定网卡地址 |
| `"*:8080"` | 绑定所有 IPv4 地址（`0.0.0.0:8080`） |
| `false` | 不绑定任何监听：渲染片段后退出，必须同时配 `agent.type` |

只写端口时默认绑回环，不会意外对外暴露。要让别的机器直接连数据面（正常不该发生，前置
代理是本机的话不需要）才写 `*:port` 或具体地址——那时任何能连上端口的人都绕过前置代理，
直接按路由表打到本机业务端口，认证、限流、日志全都不再经过；**peer 协议的路由表读也搭在
`listen` 上**（见下节），这个绑定方式同时决定了「谁能读路由表」，所以要把读方写进 `peerReaders`，
或者由前置代理按来源放行 `/_setline`。

配了 `agent` 时业务流量根本不经过 setline：haproxy/nginx 按生成的片段直接回源业务端口。
所以 `listen` 绑回环即可；跨机采集要么经前置代理读 `listen` 上的 `/_setline`，要么把
`adminListen` 显式放开；两条路都要求把采集机地址写进 `peerReaders`。
这条跨机读只有 `/_setline/routes` 一个端点（见下节）：数据面上没有状态页。

**路由完全来自配置文件、不需要运行时下发时**，可以写 `"listen": false`：setline 不绑任何
端口，启动时按配置文件渲染一次片段就退出，没有管理接口，也没有数据面。适合「静态路由 +
片段渲染」和 `setline-apply.timer` 配合的部署；此时 `agent.type` 必填（否则进程无事可做），
单机部署下 `agent.output` 仍必填。

### adminListen：写操作的独立入口

管理接口分挂在两个监听上——**数据面 `listen` 只承接 peer 协议一个端点**，其余都在管理口。
缺省配置不用写任何东西：

```json
{
  "listen": "127.0.0.1:8080",
  "adminListen": "127.0.0.1:10080",
  "peerReaders": ["10.0.1.7"]
}
```

| 接口 | 挂在哪 | 谁能访问 |
|---|---|---|
| `GET /_setline/routes`（peer 协议） | `listen` **和** `adminListen` | 本机来源，或来源地址在 `peerReaders` 里 |
| `GET /_setline/status`、`/status.html`、`/status.json` | 只有 `adminListen` | 本机来源，或来源地址在 `peerReaders` 里 |
| `PUT` / `DELETE /_setline/routes*`（写） | 只有 `adminListen` | 只接受本机请求（回环对端 + 回环 Host） |

为什么这么分：

- **路由表读搭在业务端口上**：跨机采集（`agent.peers`）只需要知道 `listen`（它本来就
  知道——那是代理回源的地址）就能读路由表，不用额外知道管理口在哪。它的准入是**来源地址**：
  对端是远端机器，所以要把那台机器的地址写进 `peerReaders`。
- **状态页和 `status.json` 只在管理口上**：它们没有跨机消费者，内容却是监听地址、超时、
  `maxConnections`、健康检查调参、计数器和整张路由表。挂在数据面上只会放大暴露面——前置
  代理漏掉 `deny /_setline` 时，泄露的东西从「一份路由表」变成「整幅运行画像」。跨机监控
  要读 `status.json` 就直连管理口（显式放开并把采集机写进 `peerReaders`），或者在代理本机采集。
- **写只在管理口上，而管理口缺省绑回环**：拨不动 `127.0.0.1:10080` 就改不了路由，
  「只有本机能改流量走向」成了 TCP 层事实，不再依赖「回环对端 + 回环 Host」那两维判定
  （Host 是请求头，前置代理改写它就能骗过判定；那两维只是纵深防御，不是边界）。
- 数据面收到除 `GET /_setline/routes` 之外的任何 `/_setline/*` 一律回 `404`，不查路由表、
  也不做写操作；配置校验另外禁止路由前缀以 `/_setline` 开头。
- 管理口绑在哪只在**状态页 HTML** 和**启动日志**里写明（`status.json` 面向机器读取，
  不暴露管理入口）；启动日志在绑非回环时还会补一行读接口的可达性说明。
- `"adminListen": false` 不再表示「和数据面共用」，它已经是配置错误；`"listen": false`
  的纯渲染部署则不要写 `adminListen`（写完就退出，没有进程服务它）。
- `adminListen` 和 `listen` 不能落在同一个地址上（`10080` 是管理口的缺省端口，给数据面
  用会直接报错）。
- 跨机读还有一条路：把 `adminListen` 显式放开（例如 `*:10080`）并把读方写进 `peerReaders`。
  缺省绑回环是因为路由表读已经能从 `listen` 走；真要读状态页就得开管理口，或者本机采集。

同机的工具（basctl 等）照旧访问 `adminListen`：写请求只有那一个入口。

## peerReaders：读接口的准入

setline 不持有任何凭据：读接口的准入**只看来源地址**，写接口只看「是不是本机」。

| 请求 | 来源 | 结果 |
|---|---|---|
| `GET /_setline/routes`（`listen` 或 `adminListen` 都认） | 本机 | 放行 |
| `GET /_setline/routes` | 其他主机，地址在 `peerReaders` 里 | 放行 |
| `GET /_setline/routes` | 其他主机，地址不在名单里 | `403` |
| `GET /_setline/status`、`/status.html`、`/status.json`（只有 `adminListen`） | 本机，或 `peerReaders` 里的地址 | 放行，其余 `403` |
| `PUT` / `DELETE /_setline/routes*`（只有 `adminListen`） | 仅本机 | 不在此列：写接口自己判定，非本机一律 `403` |

```json
{
  "listen": "127.0.0.1:8080",
  "adminListen": "127.0.0.1:10080",
  "peerReaders": ["10.0.1.7", "10.0.1.8"]
}
```

几条规则要记住：

- **为什么用地址而不是 token。** 这条链路上唯一的跨机读方是另一个 setline（`setline -f`
  按 `agent.peers[].url` 拉路由表），机器对机器、读方固定。给它配一份要在两台机器上同步的
  秘密，换不来比来源地址更实在的东西——token 走的是明文 HTTP，能抓到这条流量的中间人直接
  拿到并可复用；地址无法被「嗅探复用」，只能被伪造，而伪造 TCP 源地址需要位置且拿不到回程。
  代价是名单本身要维护：换机器要改被读端（读端只要 URL）。
- **只认数值地址**：`10.0.1.7`、`fe80::1` 这种写法，不支持主机名（配置解析会变成一次 DNS
  查询，且名字解析出的地址未必是 TCP 对端地址）与 CIDR（要按位比较，规则就不再是「一行
  地址」）。写法会归一化：去空白、转小写、去掉 IPv4-mapped 前缀，所以双栈监听上
  `::ffff:10.0.1.7` 与配置里的 `10.0.1.7` 是同一个地址。
- **本机来源永远放行**，不需要写进名单（写了会报错：`127.0.0.1` 是个空操作）。同机的工具
  （如 basctl）因此什么都不用配。
- **读不看 `Host`，写才看。** 本机调用方可能按公开主机名访问，所以读只认来源地址；写要求
  「TCP 对端是回环 **且** 请求声明的 Host 是回环名」（`Host` 或 `X-Forwarded-Host`，
  忽略端口，没有 Host 一律不算本机）。
- **前置代理必须自己拒掉管理路径。** 代理转发的请求来源是回环（代理在本机），读侧只看
  来源，所以代理漏掉 deny 就等于把路由表（`listen` 上）或状态页（管理口上）转发出去：

  ```haproxy
  http-request deny if { path_beg /_setline }
  ```
  ```nginx
  location ^~ /_setline { return 404; }
  ```

  写侧还有 Host 这一维兜底（代理通常原样转发浏览器的 Host），但它依赖代理行为，不算边界。
- **写接口不区分本机上的用户或进程。** 只要能和 setline 的监听端口建立 TCP 连接，就能改
  路由；不要把 setline 和不可信的进程放在同一台机器或同一个网络命名空间里。
- 来源判定的是**连接的对端地址**，所以读方经 NAT/L4 代理接入时，名单要写代理的地址（那一跳
  之后的客户端都会被当成读方），这种拓扑下地址判定就不再合适。
- 管理接口的请求体有 4 MiB 防御性上限（整体替换路由表也远够用），超限回 `413`。

读路由表：

```bash
# 本机，走管理口或数据面都行
curl http://127.0.0.1:10080/_setline/routes
curl -H 'Host: app.example.com' http://127.0.0.1:8080/_setline/routes

# 其他主机：把来源地址写进被读端的 peerReaders 即可，客户端不带任何凭据
curl http://setline.internal:8080/_setline/routes
```

读方（`setline -f`）那一侧只需要 `agent.peers[].url`，没有配套的凭据字段（见「agent」一节）。
浏览器地址栏看状态页只在本机可行；远程读状态页同样靠 `peerReaders`。

## routes

`routes` 是两层对象：`host → 路径前缀 → 端口`。端口值可以是单个整数，也可以是非空数组。

```json
{
  "routes": {
    "app.example.com": {
      "/api/edu": [9002, 9003],
      "/m/edu/learning": 5173,
      "/api": 9001
    },
    "admin.example.com": {
      "/": 9090
    },
    "*": {
      "/": 8081
    }
  }
}
```

### 匹配规则

1. 取请求的 `Host` 头，去掉端口、转小写。
2. 在该 host 下按**最长前缀**匹配路径，所以 `/api/edu` 优先于 `/api`。
3. 该 host 下没有能匹配该路径的路由时，回退到 `*` 命名空间。

### host 的写法

- 普通主机名，**不带端口**（带端口会报 `route host must not include port`）。
- 大小写不敏感，加载时统一转小写。
- `*` 是 fallback 命名空间，不是通配后缀：`*.example.com` 没有特殊含义。

### prefix 的写法

- 必须以 `/` 开头（`route prefix must start with /`）。
- 除根路径外尾部 `/` 会被去掉：`/api/edu/` 与 `/api/edu` 等价。
- 不能以 `/_setline` 开头（会和管理接口冲突）。
- 不做 URL 重写：命中后原样转发给后端。

### 端口

- 必须是 `1..65535` 的整数。
- 数组必须非空；多个端口之间是随机选择，不支持权重。
- 每个端口固定映射到 `127.0.0.1:<port>`。**不能写完整的后端 URL**，
  这是本项目的约束：setline 只代理本机后端，跨机路由交给 haproxy/nginx。

## 报文边界（framing）

setline 不做业务解析，但必须知道「请求体和响应体到哪里结束」，否则透传会串包：

- `Content-Length` 只接受 `1*DIGIT`（RFC 9110）：同一个头重复出现且值完全相同算合法；值
  不同、带符号（`+5`、`-1`）、带其他字符或超出 `long` 范围都算非法。
- `Transfer-Encoding` 与 `Content-Length` 同时出现、或 `Transfer-Encoding` 里没有
  `chunked`，都算非法。
- **请求侧**出现上述非法组合时，在入口直接返回 `400`，报文不转发给后端。
- **响应侧**优先原样透传：上游的响应头不会被改写；framing 冲突的响应仍会转发给前置代理，
  但 setline 不会再用这条上游连接承载下一个请求。
- 响应体在代理过程中被上游截断（声明的 `Content-Length` 没读完就 EOF、chunk 未正常结束）
  时，setline 只关掉 client 连接，**不会**再补一个 `502`。响应头已经发出去了，补发只会把
  状态行和错误文本混进响应体；前置代理看到的是「响应被截断」，由它决定回什么给客户端。

## agent

`agent` 让 setline 渲染供边缘代理（haproxy / nginx）使用的配置片段。数据来源有两种，
由是否配置 `peers` 决定：

| 配置 | 形态 | setline 自身 | 触发重渲染的时机 |
|---|---|---|---|
| `peers` | 纯渲染机：合并多台对端 setline 的路由表 | **不监听**，跑一轮就退出 | `setline-render.timer` 周期驱动（包内 unit） |
| 不配 `peers`（**单机部署**） | haproxy/nginx、setline、basctl 同机 | **照常监听**，但只当控制面入口 | 启动时渲染一次，之后每次经管理接口改路由立即重渲染 |

单机部署下 setline 是路由表的**登记处**（接收 basctl 推来的路由）和**渲染器**，同时
保留一个本机代理用于调试：业务流量并不经过它，同机的 haproxy/nginx 按片段直接回源
业务端口（见 `docs/haproxy-integration.md` 与 `docs/nginx-integration.md` 的
「数据面与控制面」）。因此不需要 `peers`（不要求边缘代理和管理入口互相访问），也不需要
外部 timer —— 路由一变片段就重渲染。此时 `output` 必填。

如果连「登记处」都不需要（路由只在配置文件里，没有 basctl 推），在这套基础上加
`"listen": false`：setline 不绑监听，启动时渲染一次片段后退出。

纯渲染机（`peers`）也走「跑一轮就退出」：**setline 进程里没有调度循环**，
周期刷新由 systemd timer 驱动（包里的 `setline-render.timer`，每 30s 拉起一次
`setline-render.service`）。节奏统一由 systemd 管，`systemctl list-timers` / `journalctl`
里看得见，配置里也不再需要 `sync`。纯渲染机启用 `setline-render.timer`；单机部署启用
`setline.service` 常驻，两者不要同时开（两个渲染器写同一批文件是多余的）。
三种形态的 `listen` 取值归纳如下：

| 数据来源 | `listen` | 进程行为 |
|---|---|---|
| `peers` | 不用写（写了也不监听） | 渲染一轮后退出，由 `setline-render.timer` 周期拉起 |
| 配置文件（单机部署，需运行时改路由） | 地址或端口 | 监听控制面，改路由立即重渲染 |
| 配置文件（纯渲染，无运行时变更） | `false` | 渲染一次后退出，不监听 |

| 字段 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `type` | 字符串 | 无 | `haproxy` 或 `nginx`，**必填** |
| `peers` | 数组 | `[]` | 被聚合的远端 setline 实例；留空即单机部署 |
| `output` | 字符串 | 空 | 片段落盘**根目录**（绝对路径）；留空打到标准输出（**单机部署必填**） |

`peers`/单机两种形态的边界：单机形态漏写 `output` 报
`agent.output is required when agent.peers is not set`；`"peers": []`（空数组）报
`agent.peers must not be empty`。都靠 `setline -c -f <cfg>` 就能看到，不用起服务。

`output` 只给一个根目录即可，里面放什么由 setline 决定：按 `type` 落到
`<output>/haproxy/` 或 `<output>/nginx/`，文件名固定为 `setline.cfg`（haproxy）或
`setline.conf`（nginx）；haproxy 另写一份路由 map，nginx 按 host 再分几个 location
文件（见「output 的目录布局」）。目录不存在时会逐级创建，因此运维只要保证根目录可写（`setline-apply` 的
`HAPROXY_FRAGMENT_DIR`/`NGINX_FRAGMENT_DIR` 默认正是 `/var/lib/setline/haproxy` 与
`/var/lib/setline/nginx`）。

完整可跑的 agent 配置见 `docs/haproxy-integration.md` 与 `docs/nginx-integration.md`
的「setline 配置示例」。

片段**固定只出规则和后端定义**，不含任何监听段：`bind` / `listen` 归代理主配置，
`agent` 下没有让片段自带监听的开关。接线步骤（haproxy 的 `-f <dir>` 与四条 map 查询、
nginx 的 `include`）见 `docs/haproxy-integration.md` 与 `docs/nginx-integration.md`。

`type` 也是热加载分派的依据：`setline-apply.timer` 只启用一个，`setline-apply auto`
会对每份配置执行 `setline -f <cfg> --agent-type`，按这里填的 `haproxy`/`nginx` 决定
校验和 reload 谁。所以改 `type` 之后不需要动 systemd。timer 装完不会自动启用：
`sudo systemctl enable --now setline-apply.timer`（启用、手工执行与参数见
`docs/agent-reload.md` 的「启用与使用」）。

### peers

```json
{
  "agent": {
    "type": "nginx",
    "output": "/var/lib/setline",
    "peers": [
      { "name": "app1", "url": "http://10.0.1.10:8080" },
      { "name": "app2", "url": "http://10.0.1.11:8080" }
    ]
  }
}
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `url` | 是 | 对端 setline 的基地址，既用于读路由表，也提供回源主机；见下节 |
| `name` | 否 | 只影响生成的服务名，便于人工阅读 |

peer 对象只认这两个字段，写错字段名（例如写一个不存在的 `address`）会在
`setline -c` 时报错，而不是被默默忽略。

peer 不带凭据：读方只需 URL，被读端按来源地址放行。这里没有存凭据的字段，
也就没有要在两台机器之间同步的秘密。

每个 peer 路由表里的本机端口会被改写成 `<url 的主机>:<port>`；不同 peer 上 host 与
前缀相同的路由会合并成同一个 upstream/backend 的多台 server。

#### 回源主机来自 url，没有单独的 address 字段

`url` 一个字段承担两个方向：它既是 agent 拉取路由表的管理入口，也是边缘代理回源的
目标主机。取值时只取主机部分，并且会**丢掉端口**——因为 URL 端口是管理端口，而业务
端口由每条路由自带。上面 `url` 里的 `8080` 和业务端口 `9002` 无关：

```text
{ "url": "http://10.0.1.10:8080" }   →  回源主机 = 10.0.1.10
                                     →  后端     = 10.0.1.10:9002
```

因此 `url` 必须带主机。这两类写法在 `setline -c` 时就会报错：

- `file:///tmp/peer`：没有主机；
- `/tmp/peer`：本地路径，也没有主机。

如果管理入口和业务入口不在同一个地址（管理网、NAT、隧道等），就让 `url` 指向边缘
代理能连到业务主机的那个地址：读路由表和管理入口共用同一条通路即可。

`name` 留空时也取这个主机，只影响生成的服务名，便于人工阅读。

### 单机部署（不配 peers）

haproxy/nginx、setline、basctl 在同一台机器上时，边缘代理要回源的后端和 setline 要
调度的后端是同一批进程，没有必要让 setline 绕一圈去拉自己的路由表。`agent` 里只写
`type` 和 `output`，不写 `peers`，setline 就进入单机模式：

```json
{
  "listen": "127.0.0.1:8080",
  "agent": {
    "type": "haproxy",
    "output": "/var/lib/setline"
  },
  "routes": {
    "app.example.com": {
      "/api/edu": [9002, 9003]
    }
  }
}
```

和纯渲染机（配了 `peers`）的三点区别：

- setline **照常监听** `listen`，作为 basctl 推路由的登记处（控制面，业务流量不经过它）；
- 片段在**启动时渲染一次**，之后每次经管理接口（`PUT` / `DELETE /_setline/routes*`）
  改路由就**立即重渲染**，不需要外部 timer，也不依赖外面再跑一个 `setline -f`；
- `output` **必填**：没有外部驱动，留空只会把片段反复打到标准输出。

写片段失败（根目录不可写、磁盘满等）只打一行 `setline agent render failed: ...`，setline
照常运行（业务流量本来就不经过它），下次改路由会再试——不会因为片段写不出去而让业务断掉。
子目录（`haproxy/`、`nginx/`）由 setline 按需创建，不需要事先手建。

回源主机固定为 `127.0.0.1` —— 单机部署下路由端口都在本机。生成的服务名用 `local`
前缀（例如 `local_app_example_com_api_edu`），与 peer 模式的服务名区分开。

单机模式下 `setline-apply.timer` 仍然有用：片段变了就 reload 代理，片段没变则无动作。

### output 的目录布局

`output` 是**根目录**，下面的目录名和文件名都由 setline 决定，不开放配置——它们同时是
`setline-apply` 与代理主配置接线的约定（`include` / `-f` 的路径写死了），运维只需要给
一个可写的根目录，别再手工拼文件名。目录不存在时逐级创建。

目录名按 `type` 取固定值 `haproxy`/`nginx`；文件名主干固定为 `setline`，扩展名按代理
区分，这个不是风格问题：

- haproxy 的 `-f <dir>` **只加载 `.cfg`**，所以主片段叫 `setline.cfg`；
- nginx 的 `include` 通常写成 `*.conf`，所以主片段叫 `setline.conf`。

除主片段外还会派生几个文件：

| 代理 | 文件（相对 `<output>`） | 作用 |
|---|---|---|
| haproxy | `haproxy/setline.cfg` | 只有 `backend` 段 |
| haproxy | `haproxy/setline.map` | 路由表，主配置 frontend 用 `map_beg()` 查它 |
| nginx | `nginx/setline.conf` | 只有 `upstream` 段，在 `http {}` 里 include |
| nginx | `nginx/setline.<host>.conf` | 该 host 的 `location`，在对应 `server {}` 里 include；`*` 回退路由是 `nginx/setline.default.conf` |

`output` 覆盖范围是**整个 `<type>` 子目录**，所以不要把别的文件放进
`<output>/haproxy/`（`setline-apply` 按目录整体校验和还原，见 `docs/agent-reload.md`）。

写好后还需要一次性接线（nginx 加 `include`，haproxy 加 `-f`），校验与热加载由
`setline-apply` 负责，见 `docs/haproxy-integration.md`、`docs/nginx-integration.md`
和 `docs/agent-reload.md`。

## 示例

### 最小本地开发

绑回环、无凭据；管理口用缺省值，本机直连 10080 读状态页和路由表：

```json
{
  "listen": 8080,
  "routes": {
    "*": {
      "/api": 9001,
      "/web": [5173, 5174]
    }
  }
}
```

### 生产：对外监听 + 读方名单

```json
{
  "listen": "*:8080",
  "adminListen": "127.0.0.1:10080",
  "peerReaders": ["10.0.1.7"],
  "connectTimeoutMillis": 3000,
  "readTimeoutMillis": 15000,
  "reusePort": false,
  "upstreamIdleTimeoutMillis": 30000,
  "webSocketIdleTimeoutMillis": 0,
  "maxConnections": 65535,
  "healthCheck": {
    "intervalMillis": 5000,
    "timeoutMillis": 1000,
    "unhealthyThreshold": 2,
    "healthyThreshold": 1
  },
  "routes": {
    "app.example.com": {
      "/api/edu": [9002, 9003],
      "/api": 9001
    },
    "*": {
      "/": 8081
    }
  }
}
```

### 运行时改路由

写接口只接受本机来源（回环对端 + 回环 Host），不需要任何凭据：

```bash
# 新增/替换一条
curl -X PUT 'http://127.0.0.1:10080/_setline/routes?host=app.example.com' \
  -d '{"/api/edu":[9002,9003]}'

# 替换某 host 的全部路由
curl -X PUT 'http://127.0.0.1:10080/_setline/routes/all?host=app.example.com' \
  -d '{"routes":{"/api":9001}}'

# 删除一条 / 清空某 host
curl -X DELETE 'http://127.0.0.1:10080/_setline/routes?host=app.example.com&prefix=/api'
curl -X DELETE 'http://127.0.0.1:10080/_setline/routes?host=app.example.com'
```

改动会写回配置文件顶层 `routes` 字段（其余字段原样保留），重启后仍然生效。
完整接口见 `docs/runtime-routes-api.md`。

### agent：聚合多台 setline 生成 nginx 片段

片段不含 `listen`，监听归你自己的 `server {}`。生成
`nginx/setline.conf`（upstream）加每个 host 一份 `nginx/setline.<host>.conf`
（location 文件）。

```json
{
  "agent": {
    "type": "nginx",
    "output": "/var/lib/setline",
    "peers": [
      { "name": "app1", "url": "http://10.0.1.10:8080" },
      { "name": "app2", "url": "http://10.0.1.11:8080" }
    ]
  }
}
```

### agent：生成 haproxy 片段

生成 `haproxy/setline.cfg`（backend）加 `haproxy/setline.map`（路由表），主配置的
frontend 加四行（`set-var` + `concat` + 两条 `map_beg()` 查询）即可。

```json
{
  "agent": {
    "type": "haproxy",
    "output": "/var/lib/setline",
    "peers": [
      { "name": "app1", "url": "http://10.0.1.10:8080" }
    ]
  }
}
```

### agent：单机部署（同机 haproxy + setline + basctl）

边缘代理和 setline 同机时省掉 `peers`：setline 仍监听控制面入口（basctl 推路由），
路由一变就重渲染片段；业务流量由 haproxy 按片段直接回源，不经过 setline。本例绑回环，
管理接口也只对本机开放。

```json
{
  "listen": "127.0.0.1:8080",
  "agent": {
    "type": "haproxy",
    "output": "/var/lib/setline"
  },
  "routes": {
    "app.example.com": {
      "/api/edu": [9002, 9003],
      "/": 9090
    }
  }
}
```

## 常见校验错误

`-c` 会把下面这类消息打在 `Config <path> is invalid: ` 之后：

| 消息 | 原因 |
|---|---|
| `listen must be port or host:port` | `listen` 既不是整数也不是字符串 |
| `listen must be host:port` | 字符串里的冒号不止一个 |
| `listen must be port, host:port or false` | `listen` 写成 `true` 或其他类型 |
| `adminListen must be port or host:port: the admin API always has its own listener` | `adminListen` 写成 `false`（不再支持共用 `listen`） |
| `adminListen must be port or host:port` | `adminListen` 写成 `true` 或其他类型 |
| `adminListen must differ from listen` | `adminListen` 和 `listen` 是同一个地址（含 `*:` 与具体地址同端口） |
| `listen must not use the default admin port 10080: set adminListen explicitly` | 没写 `adminListen`，而 `listen` 用了管理口的缺省端口 10080 |
| `adminListen cannot be combined with listen:false` | `"listen": false` 时进程渲染完就退出，没人来服务这个管理监听 |
| `listen:false requires agent.type` | 写了 `"listen": false` 却没配 `agent`（进程无事可做） |
| `connectTimeoutMillis must be positive` / `readTimeoutMillis must be positive` | 超时写成 0 / 负数 |
| `upstreamIdleTimeoutMillis must be positive` | 空闲上游连接保留时间写成 0 / 负数 |
| `maxConnections must be positive` | 连接上限写成 0 / 负数 |
| `reusePort must be boolean` | `reusePort` 不是 `true` / `false` |
| `webSocketIdleTimeoutMillis must not be negative` | `webSocketIdleTimeoutMillis` 写成负数 |
| `route prefix must start with /` | 前缀没以 `/` 开头 |
| `route updates are only allowed from localhost`（HTTP `403`） | 写接口的来源不是回环对端，或 Host 不是回环名（多为经本机代理转发的远端请求） |
| `route reads are only allowed from localhost or a peerReaders address`（HTTP `403`） | 读接口的来源不是本机，也不在 `peerReaders` 里 |
| `route prefix conflicts with admin API` | 前缀以 `/_setline` 开头 |
| `route value must be port or ports` | 路由值不是整数也不是数组 |
| `route port must be 1..65535` | 端口越界 |
| `route host must not include port` | host 里写了端口 |
| `adminToken has been removed: reads are admitted by source address (peerReaders)` | 写了已取消的 `adminToken`（读的准入改成来源地址，链路上不再有凭据） |
| `agent.remote has been removed: use agent.peers or local routes` | 写了已取消的 `agent.remote`（数据来源只剩 `peers` 与本机路由表） |
| `agent.workDir has been removed: agent.remote is gone` | 写了已取消的 `agent.workDir` |
| `agent.type is required: haproxy or nginx` | 配了 `agent` 但没写 `type`（或写错） |
| `agent.bind has been removed: the fragment never owns the listener` | 写了已取消的 `agent.bind`（监听段只归代理主配置） |
| `agent.token has been removed: peers are admitted by source address, not by a shared token` | 写了已取消的 `agent.token`（读的准入改成来源地址） |
| `agent.output is required when agent.peers is not set` | 单机模式没写 `output` |
| `agent.output must be an absolute directory path` | `output` 写成相对路径（会随 CWD 漂移，破坏固定布局） |
| `agent.output must not be empty` | `output` 写成空字符串（等同于没配） |
| `agent.peers must not be empty` | 写了 `"peers": []` |
| `agent.sync has been removed: drive setline from a systemd timer` | 写了已取消的 `agent.sync`（渲染节奏由 `setline-render.timer` 驱动） |
| `request body exceeds <n> bytes`（HTTP `413`） | 管理接口 PUT 的 body 超过 4 MiB 防御性上限 |
| `agent.peers[] has unknown field: <key>` | peer 里写了不存在的字段（peer 只认 `url` 与 `name`） |
| `agent.peers[].token has been removed: reads are admitted by source address` | 写了已取消的 `agent.peers[].token`（读的准入改成来源地址） |
| `cannot derive backend host from agent.peers[].url` | peer 的 `url` 没有主机（`file://`、本地路径） |
