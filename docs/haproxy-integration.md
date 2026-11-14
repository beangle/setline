# HAProxy 集成

本文交代怎样让 HAProxy 把流量交给 setline：setline 部署在 HAProxy 之后，按
Host + 路径前缀把请求转发到本机后端端口。setline 不生成、不修改、也不 reload
HAProxy 的配置；HAProxy 的主配置始终由部署方持有。

> **定位**：setline 永远部署在 haproxy/nginx **之后**，不是用户访问的第一站。
> 它只承接前置代理转发来的请求，TLS、限流、访问日志、客户端超时都由前置代理负责。
## 版本要求

本项目的 HAProxy 基线是 **HAProxy ≥ 2.0**（在 2.0.33、2.2.9、3.0.25 上实测过）。
低于 2.0 的版本（例如 CentOS 7 自带的 1.5.18）不在支持范围内，先跑 `haproxy -v`
确认。

## 数据面与控制面

setline 有两个监听：

- `listen`：数据面，按请求的 `Host` 和路径前缀在本机端口之间转发；同时提供
  `GET /_setline/routes` 路由表读取。
- `adminListen`（缺省 `127.0.0.1:8081`）：状态页、`status.json` 与
  `PUT` / `DELETE /_setline/routes*` 写接口的唯一入口。

HAProxy 的 backend 应该指向 `listen`（缺省 `127.0.0.1:8080`）；不要指向
`adminListen`。setline 再按自己的路由表把请求分发到业务端口。

## 接线示例

最小形态：HAProxy 接收入站请求，只把请求转给 setline。

```haproxy
global
  maxconn 4096
  # 其余 global 设置保持部署方原有内容

defaults
  mode http
  timeout connect 2s
  timeout client 30s
  timeout server 30s

frontend http_in
  bind *:80
  # setline 只按 TCP 对端判断「本机」，代理转发来的请求对端是回环。前置代理必须
  # 自己拒掉管理路径，否则任何能过 HAProxy 的客户端都能读路由表。
  http-request deny if { path_beg /_setline }
  default_backend setline

backend setline
  server s1 127.0.0.1:8080 check
```

对应的 `setline.json`：

```json
{
  "listen": "127.0.0.1:8080",
  "adminListen": "127.0.0.1:8081",
  "routes": {
    "app.example.com": {
      "/api/edu": [9002, 9003],
      "/api": 9001
    },
    "*": {
      "/": 9090
    }
  }
}
```

- setline 从请求 `Host` 头取 host（去端口、转小写），再在该 host 下按最长路径前缀
  匹配；`*` 是没有精确命中时的 fallback。
- 每个端口都固定映射到 `127.0.0.1:<port>`，setline 只代理本机后端。
- HAProxy 默认原样转发 `Host` 头，setline 的 host 路由才能生效；不要在中间改写
  Host 或路径。
- 同一个 host + 前缀的多个端口会随机选择，setline 不做加权。

也可以让 HAProxy 只把部分路径交给 setline，其余路径直接回源：

```haproxy
frontend http_in
  bind *:80
  http-request deny if { path_beg /_setline }
  acl is_api path_beg /api
  use_backend setline if is_api
  default_backend app_direct

backend app_direct
  server app1 127.0.0.1:9001 check
```

两种形态下 setline 都只看到 HAProxy 转来的请求，不直接面对客户端。

## 管理路径必须由前置代理拒绝

`GET /_setline/routes` 同时挂在 `listen` 和 `adminListen` 上，读准入只看来源地址。
经本机 HAProxy 转发的请求来源就是 `127.0.0.1`，所以前置代理不拒绝的话，任何能过
HAProxy 的客户端都能读到路由表：

```haproxy
http-request deny if { path_beg /_setline }
```

`http-request deny` 在转发前生效，被挡的请求连 setline 都不会连到。要放采集机进来
就按源地址开一条更窄的规则（`http-request deny if { path_beg /_setline } !{ src 10.0.1.0/24 }`），
而不是整条放行；也可以把规则收成精确匹配 `{ path /_setline/routes }`，只放采集机真正
要用的那一个端点。

写接口和状态页只挂在 `adminListen` 上，经 HAProxy 转发过来也只有 `404`。

## 校验与 reload

HAProxy 的配置由部署方维护，setline 不参与。改完配置后照常：

```bash
haproxy -c -f /etc/haproxy/haproxy.cfg
systemctl reload haproxy
```

用 `systemctl reload`（或发行版单元里的 `-sf`/`-x`）让新 worker 接流量，不要直接
kill 主进程。`haproxy -c` 校验的是整份配置，接线错误会在这里报出来。

## 权限

- 常驻 `setline` 以 `setline` 用户运行（`setline.service` 的 `User=setline`），
  只负责数据面；
- HAProxy 以 root 启动后降权，连接 `127.0.0.1:8080` 不需要额外权限；
- setline 不以 root 运行是硬性要求，见 `docs/project-constraints.md` 的
  Privilege Model。需要绑定 1024 以下端口时用
  `AmbientCapabilities=CAP_NET_BIND_SERVICE`。

## 排错

| 现象 | 原因 |
|---|---|
| HAProxy 返回 `503`，setline 日志无请求 | HAProxy backend 没连上 `127.0.0.1:8080`：检查 setline 是否启动、`listen` 地址是否一致、健康检查是否通过 |
| 所有请求走成 `*` 路由 | `Host` 头在中途被改写，或 setline 的 `routes` 里没有对应 host |
| 请求命中了错误的 host | 检查 HAProxy 是否设置了会覆盖 Host 的规则；setline 只认请求里的 `Host` |
| 能读到 `/_setline/routes` | 前置代理漏了 `http-request deny if { path_beg /_setline }` |
| `PUT /_setline/routes` 经 HAProxy 返回 `404` | 正常：写接口只挂在 `adminListen` 上 |
| `PUT /_setline/routes` 直连管理口却被拒 | 写要求回环 TCP 对端 **且** Host 是回环名；用 `127.0.0.1` / `localhost` 访问 |
| `502 Bad Gateway` | 后端端口没在监听，或应用主动断开；setline 只做本机端口转发 |
| WebSocket 握手失败 | 检查前置代理和应用后端；setline 只透传升级后的字节流 |
