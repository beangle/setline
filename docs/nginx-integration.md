# Nginx 集成

本文交代 setline agent 生成的 Nginx 片段怎么接到 Nginx 上：生成什么、不生成什么、
文件布局、一次性接线步骤，以及校验/热加载和排错。

> **定位**：setline 永远部署在 haproxy/nginx **之后**，不是用户访问的第一站。推荐形态是
> nginx 直接回源业务端口、setline 只渲染片段（本文就是这套）；也可以让 setline 作为
> nginx 的下级代理承接数据面，但那样必须先满足 `docs/project-constraints.md` 的两个前提
> （`listen` 只绑回环、前置代理拒掉 `/_setline`）。两种形态下 setline 都不面对不可信
> 客户端。

## 生成范围：部分生成，不接管主配置

setline **只生成片段**，不生成也不改动 `/etc/nginx/nginx.conf`：

| 生成 | 不生成（始终归主配置） |
|---|---|
| `upstream` 段（后端 server 列表） | `events`、`http` 全局块、日志、`gzip`、调优 |
| `location` 段（含 `proxy_pass` 和 `proxy_set_header`） | TLS 证书/`listen 443 ssl`、`http2`、`ssl_*` |
| | 整个 `server` 段（含 `listen`/`server_name`）、其它与 setline 无关的 `server`/`location` |

理由：

- `listen`、TLS、证书、HSTS 这些是部署方自定义内容，生成器替你决定只会制造冲突；
- 校验强度不变：`nginx -t` 校验的是**整份**配置（含所有 include），片段模式不降低把关；
- 真正"全量生成"应该在外层用模板/配置管理渲染 `nginx.conf`，而不是让 setline 覆盖主文件。

## 文件布局

```
<output>/nginx/setline.conf                 # 只有 upstream，在 http {} 里 include
<output>/nginx/setline.<host>.conf          # 该 host 的 location，在对应 server {} 里 include
<output>/nginx/setline.default.conf         # host 为 * 的回退路由，放进默认 server
```

片段**永远不含 `server` / `listen`**：监听和 `server_name` 归你自己的主配置（曾经有个
`agent.bind` 开关让片段自带 `server`，已取消）。

`[agent] output` 是**根目录**，`nginx/` 子目录与文件名都由 setline 决定（不开放配置，
`setline-apply` 的 `[apply] fragmentDir` 与 nginx 的 `include` 按这套固定路径接线）。
例如 `output=/var/lib/setline` 会写出 `/var/lib/setline/nginx/setline.conf`（upstream）、
`/var/lib/setline/nginx/setline.app.example.com.conf` 与 `.../setline.default.conf`，
目录不存在时自动创建。

为什么规则模式必须拆成两个文件：`upstream` 只能出现在 `http` 上下文，`location` 只能出现
在 `server` 上下文，实测把 `upstream` 放进 `server` 会直接
`"upstream" directive is not allowed here`。所以"不写 `listen`、由你的 server 持有监听"
就只能拆开 include。

## 数据面与控制面：nginx 直接回源后端

setline **不在业务流量的路径上**。片段里的 upstream server 写的就是业务端口：

```
# 单机部署：回源主机固定 127.0.0.1
upstream app_example_com_api_edu {
  server 127.0.0.1:9002;
}
# peers 模式：回源主机取自 peer.url，端口取自对端的路由表
upstream app_example_com_api_edu {
  server 10.0.1.10:9002;
}
```

upstream 名与 haproxy 的 backend 名是同一个标识：host 分组名加路径前缀（`*` 分组写作
`default`，根路径 `/` 不占一段），与后端来自本机还是某个 peer 无关。

两个入口职责不同：

- `listen`：数据面，也是 peer 协议（`GET /_setline/routes`）的入口。`curl -H
  'Host: app.example.com' http://127.0.0.1:8080/<path>` 能直接调试本机解析和转发结果，
  路由表读也认它；nginx 的 `proxy_pass` 正常情况下**不要**指到这里——白白多一跳，还丢掉
  nginx 自己的负载均衡与健康检查。
- `adminListen`（缺省 `127.0.0.1:8081`）：**写**接口的唯一入口，也是状态页和
  `status.json` 的唯一入口。basctl 用 `PUT` / `DELETE /_setline/routes*` 登记本机路由；
  它缺省绑回环，所以改路由是纯本机操作。

所以 `listen` 平时绑回环（`"127.0.0.1:8080"`）就够；跨机采集走 `listen` 上的路由表读，
要么**在 nginx 上按源地址放行**，要么直接把采集机的地址写进被读端的 `peerReaders`
（读方不带任何凭据，见 `docs/configuration.md` 的「peerReaders」一节）。

真的要把 setline 当下级代理（客户端 → nginx → setline）时，**server 块必须自己拒掉管理
路径**：路由表读搭在 `listen` 上，而读只看来源地址——经 nginx 转发的请求来源是回环，
不拒的话任何能过 nginx 的客户端都能读到路由表。写和状态页不用担心：`PUT` 和
`status.json` 只挂在管理口上，转发过来也只有 `404`。接线：

```nginx
server {
  ...
  location ^~ /_setline { return 404; }   # 放在其它 location 之前
  location / { proxy_pass http://127.0.0.1:8080; }
}
```

`^~` 让这条前缀匹配优先于正则 location，被挡的请求连 setline 都不会连到。要放采集机进来
就把这条换成按源地址限制（`allow 10.0.1.0/24; deny all;`），而不是整条放行；也可以把
`location` 收成精确匹配（`location = /_setline/routes`），只放采集机真正要用的那一个端点。

读写分挂在两个监听上（`adminListen` 缺省 `127.0.0.1:8081`，见 `docs/configuration.md`
的「adminListen」一节）：nginx 的 `proxy_pass` 只该指向 `listen`，写请求留在本机。

落盘后一眼自检：

```bash
grep -n '^  server ' /var/lib/setline/nginx/setline.conf
```

每行都应是 `127.0.0.1:<业务端口>`（单机）或 `<peer 主机>:<业务端口>`（peers）。出现
`<某主机>:8080` 就是配错了，8080 是 setline 的管理端口，不是业务端口。

## setline 配置示例

先选数据来源：**边缘机聚合多台 setline** 用 `peers`（下面第一个例子）；nginx 与
setline、basctl **同机**时不配 `peers`，setline 边收 basctl 推的路由边渲染片段
（见「单机部署」）。

### 聚合多台 setline（peers）

跑 nginx 这台机器上，本机参数和远端 peers 都写在 `/etc/setline/setline.conf`；
如果这台机器同时运行 `setline.service`，就照常提供 `listen` / `routes`；只跑 agent 的
纯渲染机可以不提供 `setline.json`，也不要启用 `setline.service`。配了 `[agent] type`
后，`setline-agent` 负责把 peer 路由渲染成片段。

```ini
[agent]
type = nginx
output = /var/lib/setline
peers = app1=http://10.0.1.10:8080, app2=http://10.0.1.11:8080
```

各字段在这里的作用：

| 字段 | 值 | 说明 |
|---|---|---|
| `[agent] type` | `nginx` | 决定片段语法，也是 `setline-apply auto` 的分派依据 |
| `[agent] output` | `/var/lib/setline` | 片段落盘**根目录**（绝对路径），setline 在其下建 `nginx/` 并写固定文件名 `setline.conf`（upstream）与 `setline.<host>.conf` / `setline.default.conf` |
| `peers[].url` | `http://10.0.1.10:8080` | 对端 setline 的基地址：既用于读路由表，也提供回源主机（**只取主机、丢掉端口**，业务端口由每条路由自带） |

渲染入口 `setline render` **跑一轮就退出**：进程里没有调度循环，重渲染和 apply 由包里的
`setline-agent.timer`（每 30s）拉起 `setline-agent-interval.service` 完成一轮；
启动/reload `setline-agent.service` 时会先做一次 bashub manifest 检查。只要 `listen`
不是 `false`，`setline.service` 仍作为常驻监听/代理进程一起运行：

```bash
sudo systemctl enable --now setline.service      # 监听/代理
sudo systemctl enable --now setline-agent.timer  # 远程检查 + 周期渲染/校验/reload
```

某一台 peer 暂时读不到只会在这一轮打一行 `setline agent render failed: ...` 并以非 0
退出，下一轮照常再试，片段保持上一轮的内容（写文件是按内容哈希幂等的）。

### 单机部署（nginx 与 setline 同机）

nginx、setline、basctl 装在同一台机器上时，upstream 就是 setline 调度的同机后端，
不配 `peers` 即可：setline 监听 `listen` 接收 basctl 推的路由
（控制面，业务流量不经过它），同时把本机路由表渲染成片段（upstream 服务器固定
`127.0.0.1`）。

```ini
[agent]
type = nginx
output = /var/lib/setline
```

```json
{
  "listen": "127.0.0.1:8080",
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
| `listen` / `routes` | 配（setline.service 监听/代理） | 配（控制面入口，basctl 推到这里） |
| upstream 名前缀 | peer 的 `name` | `local` |
| 回源地址 | 各 peer 的 `url` 主机 | `127.0.0.1` |
| 重渲染时机 | `setline-agent` 周期聚合 peers | 启动一次 + 每次管理接口改路由，另有 agent 周期兜底 |

`setline-agent.timer` 两种模式都照用；interval 轮次调用 `setline render` 后执行 apply，
片段变了才 reload（见「校验与热加载」）。远程配置只在 `setline-agent.service` 启动或
reload 时检查。

写完先校验，这一步不需要 peer 在线：

```bash
setline -c
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
`setline.conf` 里 `[apply] configs` 的默认值）。单元自己指定了 `-c` 时以单元为准，
`[apply] configs` 也要跟着改（见 `docs/agent-reload.md` 的「启用与使用」）。

### 2. 加 include

在它的 `http {}` 里：

```nginx
http {
  # upstream 定义
  include /var/lib/setline/nginx/setline.conf;

  # 每个 vhost 里 include 自己那份 location
  server {
    listen 443 ssl;
    server_name app.example.com;          # listen/TLS 都由你决定
    include /var/lib/setline/nginx/setline.app.example.com.conf;
  }

  # * 回退路由放进默认 server
  server {
    listen 443 ssl default_server;
    server_name _;
    include /var/lib/setline/nginx/setline.default.conf;
  }
}
```

不要用 `include /var/lib/setline/nginx/*.conf;` 这种通配：规则模式下 location 文件也会被
匹配到，在 `http` 上下文里 include 一个含 `location` 的文件会直接加载失败。按文件名
include，和上面示例一致。

`*` 回退在 nginx 里是 **server 级**的：nginx 只把「Host 没匹配上任何 `server_name`」的
请求交给默认 server，所以在有 `server_name app.example.com` 的 vhost 里，该 host 下没命中
location 的路径**不会**落到 `*`，而是走这个 server 自己的 `root` / `location /`（通常
404）。要与 haproxy 和 setline 自己匹配时一致（精确 host 没有该 path 的 location 才回退
`*`），把 `setline.default.conf` **也 include 进每个 vhost 的 server 块**——location 之间
按最长前缀匹配，`/api` 仍然优先于 `/`：

```nginx
  server {
    listen 443 ssl;
    server_name app.example.com;
    include /var/lib/setline/nginx/setline.app.example.com.conf;
    include /var/lib/setline/nginx/setline.default.conf;   # 该 host 未命中的路径回退到 *
  }
```

## 校验与热加载

片段落盘后由 root 的 `setline-apply` 负责（`setline-agent.timer` 周期驱动 interval，
自动按
`[agent] type` 选中 nginx；手工排查时可显式跑 `/usr/lib/setline/setline-apply nginx`）：

1. 静默窗口（默认 15s）内没有新写入才动手；
2. 片段目录整体内容哈希没变就直接退出（幂等）；
3. `nginx -t -c <主配置>` 校验（**必须 root**：非 root 会因打不开
   `/run/nginx.pid`、`/var/lib/nginx/tmp` 直接 permission denied）；
4. **接线检查**：用 `nginx -T` 的输出了解实际加载了哪些文件，片段目录里每个文件都必须
   出现，否则说明有文件没被 include；
5. `systemctl reload nginx`；
6. 任一步失败就把整个片段目录回滚到 last-known-good。

退出码：`1` 片段不合法（已回滚），`3` 接线错误（片段留在磁盘，等修接线），`2` 用法错误。
**timer 装完不会自动启用**，要 `sudo systemctl enable --now setline-agent.timer`；手工
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
| 请求落到别的 vhost | 有多个 `server` 抢同一个 `server_name` + 端口：检查主配置里的 `default_server` 与 `server_name` |
| 改了路由但流量没变 | 片段没写出（agent 未同步）、静默窗口未过，或有片段文件没被 include |
