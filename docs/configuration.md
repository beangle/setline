# 配置文件参考

setline 只读一份配置：`setline.json`（默认 `/etc/setline/setline.json`）。
它描述本地数据面：监听地址、超时、健康检查和运行时路由。

```bash
setline -f /etc/setline/setline.json
setline -c -f /etc/setline/setline.json     # 只校验配置
```

配置不存在时启动会打印提示并使用空路由表，之后可以通过管理接口动态增加路由；
`-c` 校验则要求文件必须存在。

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

未知的顶层键既不报错也不生效。历史版本里的 `agent` 字段不再有含义，新部署不要写。

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
- host 不能带端口；`*` 是 fallback 命名空间。
- 前缀不能以 `/_setline` 开头。
- 端口必须在本机监听，统一映射为 `127.0.0.1:<port>`。

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
| `listen must be port or host:port` | `listen` 写了 `true` / `false` 或非法字符串 |
| `adminListen must differ from listen` | 两个监听地址冲突 |
| `route prefix must not start with /_setline` | 管理路径不能作为业务路由前缀 |
| `route host must not include port` | 路由 host 带端口 |
| `route port must be 1..65535` | 端口越界 |
