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

## 顶层字段

| 字段 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `listen` | 整数或字符串 | `127.0.0.1:8080` | 监听地址，见下节 |
| `adminToken` | 字符串 | 空 | 管理读接口的凭据，见「adminToken」一节 |
| `connectTimeoutMillis` | 整数 > 0 | `3000` | 连接后端的 TCP 超时 |
| `maxConnections` | 整数 > 0 | `65535` | 并发客户端连接上限，超出返回 `503` |
| `healthCheck` | 对象 | 见下 | 后端健康检查（始终开启，只调参数） |
| `agent` | 对象 | 无 | 边缘代理片段渲染模式，配了就不启动本地代理 |
| `routes` | 对象 | `{}` | host → 路径前缀 → 端口，见「routes」一节 |

### healthCheck

| 字段 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `intervalMillis` | 整数 > 0 | `5000` | 检查周期 |
| `timeoutMillis` | 整数 > 0 | `1000` | 单次 TCP connect 超时 |
| `unhealthyThreshold` | 整数 > 0 | `2` | 连续失败多少次标记离线 |
| `healthyThreshold` | 整数 > 0 | `1` | 连续成功多少次标记恢复 |

健康检查是 TCP connect 到 `127.0.0.1:<port>`，只维护在线状态，不主动探测 HTTP 路径。

## listen 的写法

| 写法 | 结果 |
|---|---|
| `8080` 或 `"8080"` | 绑定 `127.0.0.1:8080` |
| `"127.0.0.1:8080"` | 绑定指定地址 |
| `"192.168.1.10:8080"` | 绑定指定网卡地址 |
| `"*:8080"` | 绑定所有 IPv4 地址（`0.0.0.0:8080`） |

只写端口时默认绑回环，不会意外对外暴露。要对外提供服务必须显式写 `*:port` 或具体地址，
此时务必同时设置 `adminToken`（原因见下）。

## adminToken

`adminToken` 只保护**读**接口的**非本机**来源，这是最容易误解的一点，分三种情况：

| 请求 | 来源 | 凭据 |
|---|---|---|
| `GET /__setline/routes` | 本机 | 不需要 |
| `GET /__setline/routes` | 其他主机 | `X-Setline-Token: <adminToken>` |
| `GET /__setline/status.json`、`/__setline/status` | 本机 | 不需要 |
| `GET /__setline/status.json`、`/__setline/status` | 其他主机 | HTTP Basic，用户名固定 `setline`，密码为 `adminToken` |
| `PUT` / `DELETE /__setline/routes*` | 仅本机 | 不需要，且**不看 token** |

几条规则要记住：

- **空 `adminToken` 等于放行。** 开发时绑回环没关系；一旦 `listen` 绑 `*` 又不设 token，
  路由表对所有能访问到该端口的人可读，必须设置。
- **写接口从不使用 token。** 改路由等于改流量走向，它的访问控制是「TCP 对端必须解析为
  `127.0.0.1`、`::1` 或 `::ffff:127.0.0.1`」，用 `Forwarded` / `X-Forwarded-For` 伪造无效。
- **本机读免凭据**，与写同一条门，所以同机的工具（如 basctl）不需要存任何密码。

读路由表：

```bash
# 本机，不需要凭据
curl http://127.0.0.1:8080/__setline/routes

# 其他主机，用 token
curl -H 'X-Setline-Token: change-me' http://setline.internal:8080/__setline/routes

# 状态页，其他主机用 Basic（用户名 setline）
curl -u setline:change-me http://setline.internal:8080/__setline/status.json
```

token 也是 `agent.peers` 读取对端路由表时使用的凭据（见「agent」一节）。

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
- 不能以 `/__setline` 开头（会和管理接口冲突）。
- 不做 URL 重写：命中后原样转发给后端。

### 端口

- 必须是 `1..65535` 的整数。
- 数组必须非空；多个端口之间是随机选择，不支持权重。
- 每个端口固定映射到 `127.0.0.1:<port>`。**不能写完整的后端 URL**，
  这是本项目的约束：setline 只代理本机后端，跨机路由交给 haproxy/nginx。

## agent

配了 `agent.type` 时，`setline -f` 不再启动本地代理，而是渲染一份供边缘代理使用的
配置片段。两种数据来源，二选一：

| 字段 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `type` | 字符串 | 无 | `haproxy` 或 `nginx`；配 `peers` 时必填 |
| `peers` | 数组 | `[]` | 被聚合的远端 setline 实例 |
| `remote` | 字符串 | 无 | registry manifest 的 URL 或本地路径（另一种来源） |
| `output` | 字符串 | 空 | 片段落盘路径；留空打到标准输出 |
| `bind` | 字符串 | `"*:80"` | haproxy 的 `bind`，nginx 取其端口 |
| `token` | 字符串 | 空 | peers 未单独设置 token 时的默认值 |
| `workDir` | 字符串 | `/tmp/setline-agent` | `remote` 模式的下载与解包目录 |
| `sync` | 对象 | `{"mode":"once"}` | 同步机制，见下 |

### peers

```json
{
  "agent": {
    "type": "nginx",
    "output": "/var/lib/setline/nginx/setline.conf",
    "token": "shared-token",
    "peers": [
      { "name": "app1", "url": "http://10.0.1.10:8080" },
      { "name": "app2", "url": "http://10.0.1.11:8080", "token": "app2-token" }
    ]
  }
}
```

| 字段 | 必填 | 说明 |
|---|---|---|
| `url` | 是 | 对端 setline 的基地址，既用于读路由表，也提供回源主机；见下节 |
| `name` | 否 | 只影响生成的服务名，便于人工阅读 |
| `token` | 否 | 该 peer 的 `X-Setline-Token`，缺省回退到 `agent.token` |

peer 对象只认这三个字段，写错字段名（例如写一个不存在的 `address`）会在
`setline -c` 时报错，而不是被默默忽略。

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

### sync

| 字段 | 类型 | 默认值 | 说明 |
|---|---|---|---|
| `mode` | 字符串 | `once` | `once` 渲染一轮即退出；`interval` 常驻按周期重复 |
| `intervalMillis` | 整数 > 0 | `30000` | `interval` 模式的周期 |

`interval` 需要同时配置 `output`；没有 `output` 时会退化成跑一轮就退出。

### output 的文件名

片段文件名按目标代理选扩展名，这个不是风格问题：

- haproxy 的 `-f <dir>` **只加载 `.cfg`**，所以片段要叫 `*.cfg`（例如 `setline.cfg`）。
- nginx 的 `include` 通常写成 `*.conf`，所以片段要叫 `*.conf`（例如 `setline.conf`）。

写好后还需要一次性接线（nginx 加 `include`，haproxy 加 `-f`），校验与热加载由
`setline-apply` 负责，见 `docs/agent-reload.md`。

## 示例

### 最小本地开发

绑回环、开路由表读、不需要 token：

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

### 生产：对外监听 + 管理 token

```json
{
  "listen": "*:8080",
  "adminToken": "please-change-me",
  "connectTimeoutMillis": 3000,
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

写接口只接受本机来源，不传 token：

```bash
# 新增/替换一条
curl -X PUT 'http://127.0.0.1:8080/__setline/routes?host=app.example.com' \
  -d '{"/api/edu":[9002,9003]}'

# 替换某 host 的全部路由
curl -X PUT 'http://127.0.0.1:8080/__setline/routes/all?host=app.example.com' \
  -d '{"routes":{"/api":9001}}'

# 删除一条 / 清空某 host
curl -X DELETE 'http://127.0.0.1:8080/__setline/routes?host=app.example.com&prefix=/api'
curl -X DELETE 'http://127.0.0.1:8080/__setline/routes?host=app.example.com'
```

改动会写回配置文件顶层 `routes` 字段（其余字段原样保留），重启后仍然生效。
完整接口见 `docs/runtime-routes-api.md`。

### agent：聚合多台 setline 生成 nginx 片段

```json
{
  "agent": {
    "type": "nginx",
    "output": "/var/lib/setline/nginx/setline.conf",
    "bind": "*:80",
    "token": "shared-token",
    "sync": { "mode": "interval", "intervalMillis": 30000 },
    "peers": [
      { "name": "app1", "url": "http://10.0.1.10:8080" },
      { "name": "app2", "url": "http://10.0.1.11:8080" }
    ]
  }
}
```

### agent：生成 haproxy 片段

```json
{
  "agent": {
    "type": "haproxy",
    "output": "/var/lib/setline/haproxy/setline.cfg",
    "bind": "*:80",
    "token": "shared-token",
    "sync": { "mode": "once" },
    "peers": [
      { "name": "app1", "url": "http://10.0.1.10:8080" }
    ]
  }
}
```

## 常见校验错误

`-c` 会把下面这类消息打在 `Config <path> is invalid: ` 之后：

| 消息 | 原因 |
|---|---|
| `listen must be port or host:port` | `listen` 既不是整数也不是字符串 |
| `listen must be host:port` | 字符串里的冒号不止一个 |
| `connectTimeoutMillis must be positive` | 超时或连接上限写成 0 / 负数 |
| `route prefix must start with /` | 前缀没以 `/` 开头 |
| `route prefix conflicts with admin API` | 前缀以 `/__setline` 开头 |
| `route value must be port or ports` | 路由值不是整数也不是数组 |
| `route port must be 1..65535` | 端口越界 |
| `route host must not include port` | host 里写了端口 |
| `agent.remote or agent.peers is required` | 配了 `agent` 但没有数据来源 |
| `agent.type is required when agent.peers is set` | 用 `peers` 时没写 `type` |
| `agent.sync.mode must be once or interval` | 同步模式拼错 |
