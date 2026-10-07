# Nginx 集成

本文交代 setline agent 生成的 Nginx 片段怎么接到 Nginx 上：生成什么、不生成什么、
两种模式的文件布局、一次性接线步骤，以及校验/热加载和排错。

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

## 接线（一次性）

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
