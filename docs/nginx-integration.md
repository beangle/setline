# Nginx 集成

本文交代怎样让 Nginx 把流量交给 setline：setline 部署在 Nginx 之后，按
Host + 路径前缀把请求转发到本机后端端口。setline 不生成、不修改、也不 reload
Nginx 的配置；Nginx 的主配置始终由部署方持有。

> **定位**：setline 永远部署在 haproxy/nginx **之后**，不是用户访问的第一站。
> 它只承接前置代理转发来的请求，TLS、限流、访问日志、客户端超时都由前置代理负责。
## 数据面与控制面

setline 有两个监听：

- `listen`：数据面，按请求的 `Host` 和路径前缀在本机端口之间转发；同时提供
  `GET /_setline/routes` 路由表读取。
- `adminListen`（缺省 `127.0.0.1:8081`）：状态页、`status.json` 与
  `PUT` / `DELETE /_setline/routes*` 写接口的唯一入口。

Nginx 的 `proxy_pass` 应该指向 `listen`（缺省 `127.0.0.1:8080`）；不要指向
`adminListen`。setline 再按自己的路由表把请求分发到业务端口。

## 接线示例

最小形态：Nginx 接收入站请求，只把请求转给 setline。

```nginx
server {
  listen 80;
  server_name _;

  # setline 只按 TCP 对端判断「本机」，代理转发来的请求对端是回环。前置代理必须
  # 自己拒掉管理路径，否则任何能过 Nginx 的客户端都能读路由表。
  location ^~ /_setline { return 404; }

  location / {
    proxy_pass http://127.0.0.1:8080;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header Connection "";
  }
}

# WebSocket 与长连接：按业务路径单独放宽读超时
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
- `proxy_set_header Host $host;` 保证 setline 拿到原始主机名（`$host` 已去掉端口）；
  不要改写成 setline 的监听地址，否则 host 路由会全部落到 `*`。
- `proxy_http_version 1.1` 让 Nginx 用 HTTP/1.1 连 setline；setline 只支持 HTTP/1.x。
- `proxy_set_header Connection "";` 避免把客户端的 `Connection` 头原样传给 setline；
  setline 自己会处理 framing 和 keep-alive。

也可以让 Nginx 只把部分路径交给 setline，其余路径直接回源：

```nginx
server {
  listen 80;
  server_name app.example.com;

  location ^~ /_setline { return 404; }

  location /api/ {
    proxy_pass http://127.0.0.1:8080;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header Connection "";
  }

  location / {
    proxy_pass http://127.0.0.1:9001;
  }
}
```

## 管理路径必须由前置代理拒绝

`GET /_setline/routes` 同时挂在 `listen` 和 `adminListen` 上，读准入只看来源地址。
经本机 Nginx 转发的请求来源就是 `127.0.0.1`，所以前置代理不拒绝的话，任何能过
Nginx 的客户端都能读到路由表：

```nginx
location ^~ /_setline { return 404; }
```

`^~` 让这条前缀匹配优先于正则 location，被挡的请求连 setline 都不会连到。要放采集机
进来就把这条换成按源地址限制（`allow 10.0.1.0/24; deny all;`），而不是整条放行；
也可以把 `location` 收成精确匹配（`location = /_setline/routes`），只放采集机真正要
用的那一个端点。

写接口和状态页只挂在 `adminListen` 上，经 Nginx 转发过来也只有 `404`。

## 校验与 reload

Nginx 的配置由部署方维护，setline 不参与。改完配置后照常：

```bash
nginx -t -c /etc/nginx/nginx.conf    # 需要能读到实际加载的全部 include
systemctl reload nginx
```

`nginx -t` 校验的是整份配置；接线错误会在这里报出来。WebSocket 路径需要单独放宽
`proxy_read_timeout` 并显式转发 `Upgrade` / `Connection` 头，这部分由业务 server
决定，setline 只透传升级后的连接。

## 权限

- 常驻 `setline` 以 `setline` 用户运行（`setline.service` 的 `User=setline`），
  只负责数据面；
- Nginx 的 master 以 root 启动后降权，连接 `127.0.0.1:8080` 不需要额外权限；
- setline 不以 root 运行是硬性要求，见 `docs/project-constraints.md` 的
  Privilege Model。需要绑定 1024 以下端口时用
  `AmbientCapabilities=CAP_NET_BIND_SERVICE`。

## 排错

| 现象 | 原因 |
|---|---|
| Nginx 返回 `502`，setline 日志无请求 | `proxy_pass` 没连上 `127.0.0.1:8080`：检查 setline 是否启动、`listen` 地址是否一致 |
| 所有请求走成 `*` 路由 | `Host` 头被改写，或 setline 的 `routes` 里没有对应 host |
| 请求命中了错误的 host | 检查 `proxy_set_header Host`；`$host` 是去端口后的原始主机名 |
| 能读到 `/_setline/routes` | 前置代理漏了 `location ^~ /_setline { return 404; }` |
| `PUT /_setline/routes` 经 Nginx 返回 `404` | 正常：写接口只挂在 `adminListen` 上 |
| `PUT /_setline/routes` 直连管理口却被拒 | 写要求回环 TCP 对端 **且** Host 是回环名；用 `127.0.0.1` / `localhost` 访问 |
| WebSocket 升级失败 | 业务 server 没转发 `Upgrade` / `Connection`，或 `proxy_read_timeout` 太短 |
| 响应被缓冲、流式输出延迟 | 检查 `proxy_buffering`；setline 本身不缓存，只做流式透传 |
