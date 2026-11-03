# 配置文件参考

setline 使用两份互不读取的配置：

| 程序 | 文件 | 职责 | 默认路径 |
|---|---|---|---|
| `setline` | `setline.json` | 数据面：监听、超时、运行时路由 | `/etc/setline/setline.json` |
| `setline-agent` | `setline.conf` | 控制面：远端下载、片段渲染、reload 参数 | `/etc/setline/setline.conf` |

`setline` 不读 `setline.conf`；`setline-agent` 不读 `setline.json`。`setline.json` 中出现
`agent` 字段会被拒绝。

```bash
setline -f /etc/setline/setline.json
setline -c -f /etc/setline/setline.json

setline-agent --config /etc/setline/setline.conf
setline-agent render --config /etc/setline/setline.conf
setline-agent pull --check --stage --config /etc/setline/setline.conf
setline-agent -c --config /etc/setline/setline.conf
setline-agent init --config /etc/setline/setline.conf
```

## setline.conf

INI 格式：

```ini
[remote]
url = http://127.0.0.1:8082
project = openurp.prod
token = <Project.key>

[agent]
type = haproxy
output = /var/lib/setline
```

| 段 | 键 | 默认值 | 说明 |
|---|---|---|---|
| `[remote]` | `url` | 无 | bashub 根地址，不带 `/api` 或 Project；仅显式 `pull` / `setline-agent-run` 使用 |
| | `project` | 无 | `org.name` |
| | `token` | 无 | Project.key，发送为 `Bearer <project>:<key>` |
| `[proxy]` | `file` | 按代理类型推导 | `pull` 写入的代理主配置；仅非标准路径时填写 |
| `[agent]` | `type` | 空 | `haproxy` / `nginx`；空表示不渲染 |
| | `output` | `/var/lib/setline` | 片段根目录 |
| `[apply]` | `type` | 取 `[agent] type` | reload 的代理类型 |
| | `configs` | 按类型推导 | 代理主配置和片段目录列表 |
| | `fragmentDir` | `<output>/<type>` | 片段目录 |
| | `service` | 按类型推导 | `systemctl reload` 的服务名 |
| | `runtimeDir` | `/run` | 锁文件目录 |
| | `owner` | `setline:beangle` | 片段目录属主 |

`[apply]` 可省略，标准部署从 `[agent] type` 推导。没有 peers、peerReaders、本地路由配置。`setline-agent` 从 bashub 下载：

```text
routes
proxy
certificate
certificate-key
```

`routes` 由 bashub 根据 basagent 的 `report:bas` 生成，缓存为 `<agent.output>/routes.json`。`[remote] ip` 可选，用于在多台
agent 中选择本机；不写时要求该 project 只有一台在线 agent。


证书目录固定为 `/etc/setline/certs`，与 bashub 生成的 nginx/haproxy 配置一致。

### 远端刷新

```bash
setline-agent pull --check --stage --config /etc/setline/setline.conf
setline-agent pull --install --config /etc/setline/setline.conf
```

agent 先读 manifest，按 SHA-256 只下载变化资源到 `remote-stage`；root 安装前再次核对哈希。
网络失败或安装失败时保留上次成功的文件。

`pull --check` 返回 `10` 表示代理主配置或证书变化，需要：

```bash
setline-apply --force
```

`setline-agent-run` 会串起条件检查、安装、渲染和 apply。

## setline.json

数据面配置示例：

```json
{
  "listen": "127.0.0.1:8080",
  "adminListen": "127.0.0.1:8081",
  "connectTimeoutMillis": 3000,
  "readTimeoutMillis": 15000,
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
      "/api": 9001,
      "/api/edu": [9002, 9003]
    },
    "*": {
      "/": 8081
    }
  }
}
```

| 字段 | 默认值 | 说明 |
|---|---|---|
| `listen` | `127.0.0.1:8080` | 数据面监听地址 |
| `adminListen` | `127.0.0.1:8081` | 管理接口独立监听，必须与 `listen` 不同 |
| `connectTimeoutMillis` | `3000` | 连接后端的 TCP 超时 |
| `readTimeoutMillis` | `15000` | 单次上游读取的不活动超时 |
| `reusePort` | `false` | 是否启用 `SO_REUSEPORT` |
| `upstreamIdleTimeoutMillis` | `30000` | 空闲上游连接保留时间 |
| `webSocketIdleTimeoutMillis` | `0` | WebSocket 空闲回收；`0` 表示不回收 |
| `maxConnections` | `65535` | 并发客户端连接上限 |
| `healthCheck` | 见上 | 后端 TCP 健康检查 |
| `routes` | `{}` | host → 路径前缀 → 端口或端口数组 |

### listen

| 写法 | 结果 |
|---|---|
| `8080` / `"8080"` | `127.0.0.1:8080` |
| `"127.0.0.1:8080"` | 指定地址 |
| `"*:8080"` | `0.0.0.0:8080` |

只写端口默认绑回环。数据面只应部署在 haproxy/nginx 之后；TLS、限流、访问日志由前置代理负责。

### adminListen

管理接口：

| 接口 | 监听 | 权限 |
|---|---|---|
| `GET /_setline/routes` | `listen` 和 `adminListen` | 仅本机 |
| `GET /_setline/status`、`status.html`、`status.json` | `adminListen` | 仅本机 |
| `PUT` / `DELETE /_setline/routes*` | `adminListen` | 仅本机 |

写接口还要求请求的 Host 是回环名。数据面除 `GET /_setline/routes` 外的 `/_setline/*`
返回 404。前置代理应拒绝转发管理路径：

```haproxy
http-request deny if { path_beg /_setline }
```

```nginx
location ^~ /_setline { return 404; }
```

### routes

`host → 路径前缀 → 端口`，端口可为单值或非空数组：

```json
{
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

- host 小写化；前缀去掉尾部 `/`。
- 前缀不能以 `/_setline` 开头。
- `*` 是 fallback。
- 端口必须在本机监听。

### healthCheck

TCP connect 到 `127.0.0.1:<port>`，只维护在线状态，不探测 HTTP 路径。

| 字段 | 默认值 |
|---|---|
| `intervalMillis` | `5000` |
| `timeoutMillis` | `1000` |
| `unhealthyThreshold` | `2` |
| `healthyThreshold` | `1` |

## 常见错误

| 错误 | 原因 |
|---|---|
| `setline.json must not contain agent` | `agent` 只能写进 `setline.conf` |
| `adminListen must differ from listen` | 两个监听地址冲突 |
| `route prefix must not start with /_setline` | 管理路径不能作为业务路由前缀 |
| `control config not found` | `setline.conf` 路径不存在 |
| `[agent] type is required` | 需要渲染但没有代理类型 |
