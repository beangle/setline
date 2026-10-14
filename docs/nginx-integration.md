# Nginx 集成

本文交代 setline agent 生成的 Nginx 片段怎么接到 Nginx 上：生成什么、不生成什么、
两种模式的文件布局、一次性接线步骤，以及校验/热加载和排错。

> **定位**：setline 永远部署在 haproxy/nginx **之后**，不是用户访问的第一站。推荐形态是
> nginx 直接回源业务端口、setline 只渲染片段（本文就是这套）；也可以让 setline 作为
> nginx 的下级代理承接数据面，但那样必须先满足 `docs/roadmap.md` 的前置条件。两种形态
> 下 setline 都不面对不可信客户端。

## 生成范围：部分生成，不接管主配置

setline **只生成片段**，不生成也不改动 `/etc/nginx/nginx.conf`：

| 生成 | 不生成（始终归主配置） |
|---|---|
| `upstream` 段（后端 server 列表） | `events`、`http` 全局块、日志、`gzip`、调优 |
| `location` 段（含 `proxy_pass` 和 `proxy_set_header`） | TLS 证书/`listen 443 ssl`、`http2`、`ssl_*` |
| 自包含模式下的整个 `server` 段 | 其它与 setline 无关的 `server`/`location` |

理由：

- `listen`、TLS、证书、HSTS 这些是部署方自定义内容，生成器替你决定只会制造冲突；
- 校验强度不变：`nginx -t` 校验的是**整份**配置（含所有 include），片段模式不降低把关；
- 真正"全量生成"应该在外层用模板/配置管理渲染 `nginx.conf`，而不是让 setline 覆盖主文件。

## 两种模式

`agent.bind` 决定模式：

| `agent.bind` | 模式 | 片段内容 | `listen` 归属 |
|---|---|---|---|
| 有值（如 `*:80`） | 自包含 | `upstream` + `server { listen ...; }` | 片段（setline 配置，只取端口部分） |
| 留空（推荐） | 规则 | `upstream` + 每个 host 一份 `location` 文件 | 你自己的 `server {}` |

### 自包含模式的文件布局

```
<agent.output>            # upstream + server，在 http {} 里 include
```

### 规则模式的文件布局

```
<agent.output>                 # 只有 upstream，在 http {} 里 include
<output 同目录>/<stem>.<host>.conf    # 该 host 的 location，在对应 server {} 里 include
<output 同目录>/<stem>.default.conf   # host 为 * 的回退路由，放进默认 server
```

`stem` 是 `agent.output` 去掉扩展名的文件名。例如
`output=/var/lib/setline/nginx/setline.conf` 会写出 `setline.conf`（upstream）、
`setline.app.example.com.conf` 与 `setline.default.conf`。

为什么规则模式必须拆成两个文件：`upstream` 只能出现在 `http` 上下文，`location` 只能出现
在 `server` 上下文，实测把 `upstream` 放进 `server` 会直接
`"upstream" directive is not allowed here`。所以"不写 `listen`、由你的 server 持有监听"
就只能拆开 include。

## 数据面与控制面：nginx 直接回源后端

setline **不在业务流量的路径上**。片段里的 upstream server 写的就是业务端口：

```
# 单机部署：回源主机固定 127.0.0.1
upstream local_app_example_com_api_edu {
  server 127.0.0.1:9002;
}
# peers 模式：回源主机取自 peer.url，端口取自对端的路由表
upstream app_app_example_com_api_edu {
  server 10.0.1.10:9002;
}
```

顶层 `listen` 是 setline 的**控制面**入口，只承担三件事：

- basctl 用 `PUT` / `DELETE /__setline/routes*` 登记本机路由；
- 采集机用 `GET /__setline/routes` 拉别的主机的路由表；
- 直接用 `curl http://127.0.0.1:8080/<path>` 调试本机解析结果。

nginx 的 `server { listen ...; }` 跟它没有关系：**不要把 `proxy_pass` 指到 setline 的
`listen` 端口**，那样等于白白多一跳，还丢掉 nginx 自己的负载均衡与健康检查。所以
`listen` 平时绑回环（`"127.0.0.1:8080"`）就够；只有采集机在别的机器上时才绑 `*` 并设置
`adminToken`。

配了 `adminListen` 后，上面三件事的地址就换成 `adminListen`：数据面可以稳定只绑回环，
管理入口单独绑 `*`（见 `docs/configuration.md` 的「adminListen」一节）。同机的 basctl
也要跟着改地址——两个监听是两个入口。

落盘后一眼自检：

```bash
grep -n '^  server ' /var/lib/setline/nginx/setline.conf
```

每行都应是 `127.0.0.1:<业务端口>`（单机）或 `<peer 主机>:<业务端口>`（peers）。出现
`<某主机>:8080` 就是配错了，8080 是 setline 的管理端口，不是业务端口。

## setline 配置示例

先选数据来源：**边缘机聚合多台 setline** 用 `peers`（下面第一个例子）；nginx 与
setline、basctl **同机**时不配 `peers`/`remote`，setline 边收 basctl 推的路由边渲染片段
（见「单机部署」）。

### 聚合多台 setline（peers）

跑 nginx 这台机器上，`/etc/setline/setline.json` 只有 `agent` 一段，**没有 `listen`、
没有 `routes`**：配了 `agent` 就不再启动本地代理，它只负责渲染片段。

```json
{
  "agent": {
    "type": "nginx",
    "output": "/var/lib/setline/nginx/setline.conf",
    "bind": "",
    "token": "shared-token",
    "peers": [
      { "name": "app1", "url": "http://10.0.1.10:8080" },
      { "name": "app2", "url": "http://10.0.1.11:8080", "token": "app2-token" }
    ],
    "sync": { "mode": "interval", "intervalMillis": 10000 }
  }
}
```

各字段在这里的作用：

| 字段 | 值 | 说明 |
|---|---|---|
| `type` | `nginx` | 决定片段语法，也是 `setline-apply auto` 的分派依据 |
| `output` | `.../setline.conf` | 片段落盘路径，写成 `*.conf` 方便按文件名 include；同目录派生 `setline.<host>.conf` 与 `setline.default.conf` |
| `bind` | `""` | 留空 = 规则模式（`location` 归你的 `server {}`）；写 `"*:80"` = 自包含模式（只取端口） |
| `token` | `shared-token` | 所有 peer 的默认 `X-Setline-Token`，单个 peer 可用自己的 `token` 覆盖 |
| `peers[].url` | `http://10.0.1.10:8080` | 对端 setline 的基地址：既用于读路由表，也提供回源主机（**只取主机、丢掉端口**，业务端口由每条路由自带） |
| `sync` | `interval` / 10000 | 常驻，每 10s 重渲染一次；缺省 `once` 是跑一轮就退出 |

自包含模式只改 `bind`，其余不动：

```json
{
  "agent": {
    "type": "nginx",
    "output": "/var/lib/setline/nginx/setline.conf",
    "bind": "*:80",
    "peers": [
      { "name": "app1", "url": "http://10.0.1.10:8080" }
    ]
  }
}
```

`sync.mode` 怎么选：

- `interval`（推荐给边缘机）：`setline.service` 常驻，某一台 peer 暂时读不到只会打一行
  `setline agent sync failed: ...`，下一轮自动重试，片段保持上一轮的内容；
- `once`（缺省，用 `output` 才有效）：跑一轮就退出 0，需要外层周期驱动 —— 要么自己写
  `Type=oneshot` 的 timer，要么按 `setline-apply.timer` 那种「周期 + 幂等」的套路来。

### 单机部署（nginx 与 setline 同机）

nginx、setline、basctl 装在同一台机器上时，upstream 就是 setline 调度的同机后端，
不配 `peers` 也**不需要** `remote`：setline 监听 `listen` 接收 basctl 推的路由
（控制面，业务流量不经过它），同时把本机路由表渲染成片段（upstream 服务器固定
`127.0.0.1`）。

```json
{
  "listen": "127.0.0.1:8080",
  "agent": {
    "type": "nginx",
    "output": "/var/lib/setline/nginx/setline.conf",
    "bind": ""
  },
  "routes": {
    "app.example.com": {
      "/api/edu": [9002, 9003]
    }
  }
}
```

与上面 peers 模式的差别：

| 项 | peers 模式 | 单机模式 |
|---|---|---|
| `listen` / `routes` | 不配（纯渲染机，不监听） | 配（控制面入口，basctl 推到这里） |
| upstream 名前缀 | peer 的 `name` | `local` |
| 回源地址 | 各 peer 的 `url` 主机 | `127.0.0.1` |
| 重渲染时机 | `sync` 周期 / 外层 timer | 启动一次 + 每次管理接口改路由 |

`setline-apply.timer` 仍然照用：片段变了才 reload（见「校验与热加载」）。

写完先校验，这一步不需要 peer 在线：

```bash
setline -c -f /etc/setline/setline.json
```

片段的 include 接线见下一节。

## 接线（一次性）

### 1. 找到主配置

nginx 的 include 要加进**服务实际加载的那个**配置文件，先确认是哪个：

```bash
systemctl cat nginx | grep -E 'ExecStart|ExecReload'   # 单元有没有用 -c 指定路径
nginx -V 2>&1 | tr ' ' '\n' | grep -- --conf-path=     # 编译进去的默认路径
```

多数发行版不带 `-c`，用编译进去的默认值（通常是 `/etc/nginx/nginx.conf`，也就是
`setline-apply` 里 `NGINX_CONFIG` 的默认值）。单元自己指定了 `-c` 时以单元为准，
`NGINX_CONFIG` 也要跟着改（见 `docs/agent-reload.md` 的「启用与使用」）。

### 2. 加 include

在它的 `http {}` 里：

```nginx
http {
  # 后端定义（规则模式与自包含模式都是这一行）
  include /var/lib/setline/nginx/setline.conf;

  # 规则模式：每个 vhost 里 include 自己那份 location
  server {
    listen 443 ssl;
    server_name app.example.com;          # listen/TLS 都由你决定
    include /var/lib/setline/nginx/setline.app.example.com.conf;
  }

  # 规则模式：* 回退路由放进默认 server
  server {
    listen 443 ssl default_server;
    server_name _;
    include /var/lib/setline/nginx/setline.default.conf;
  }
}
```

自包含模式下只写第一行即可，`server { listen ...; }` 由片段提供；此时主配置里不要再写
占用了同一 `server_name` + 同一端口的 `server`，否则 nginx 会报重复或抢走匹配。

不要用 `include /var/lib/setline/nginx/*.conf;` 这种通配：规则模式下 location 文件也会被
匹配到，在 `http` 上下文里 include 一个含 `location` 的文件会直接加载失败。按文件名
include，和上面示例一致。

## 校验与热加载

片段落盘后由 root 的 `setline-apply` 负责（`setline-apply.timer` 周期驱动，自动按
`agent.type` 选中 nginx；手工排查时可显式跑 `setline-apply nginx`）：

1. 静默窗口（默认 15s）内没有新写入才动手；
2. 片段目录整体内容哈希没变就直接退出（幂等）；
3. `nginx -t -c <主配置>` 校验（**必须 root**：非 root 会因打不开
   `/run/nginx.pid`、`/var/lib/nginx/tmp` 直接 permission denied）；
4. **接线检查**：用 `nginx -T` 的输出了解实际加载了哪些文件，片段目录里每个文件都必须
   出现，否则说明有文件没被 include；
5. `systemctl reload nginx`；
6. 任一步失败就把整个片段目录回滚到 last-known-good。

退出码：`1` 片段不合法（已回滚），`3` 接线错误（片段留在磁盘，等修接线），`2` 用法错误。
**timer 装完不会自动启用**，要 `sudo systemctl enable --now setline-apply.timer`；手工
执行、日志与参数覆盖见 `docs/agent-reload.md` 的「启用与使用」。
reload 有没有发生（master PID 不变、worker PID 换掉、日志里的 `reconfiguring`）见
`docs/agent-reload.md` 的「如何确认 reload 真的发生」。

## 权限

- `setline` 以 `setline` 用户运行，只写 `/var/lib/setline/nginx/`，不碰 `/etc/nginx`；
- `setline-apply` 以 root 运行；nginx 的 reload 与 `nginx -t` 都需要 root；
- 片段目录保持 `0755`、文件 `0644`，nginx worker（非 root）能读即可。

## 排错

| 现象 | 原因 |
|---|---|
| `wiring error: ... does not include <file>` | 主配置漏了某个 include（规则模式最容易漏 location 文件） |
| `nginx: [emerg] "upstream" directive is not allowed here` | 在 `server`/`include` 里引入了 upstream 文件，或用了 `*.conf` 通配把 location 文件 include 到了 `http` |
| `nginx -t` 报 `permission denied` | 用非 root 跑了校验；交给 `setline-apply`（root） |
| 请求落到别的 vhost | 主配置里自包含片段与自己的 server 抢同一个 `server_name` + 端口 |
| 改了路由但流量没变 | 片段没写出（agent 未同步）、静默窗口未过，或有片段文件没被 include |
