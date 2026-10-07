# HAProxy 集成

本文交代 setline agent 生成的 HAProxy 片段怎么接到 HAProxy 上：生成什么、不生成什么、
两种模式的差别、一次性接线步骤，以及校验/热加载和排错。

## 生成范围：部分生成，不接管主配置

setline **只生成片段**，不生成也不改动 `/etc/haproxy/haproxy.cfg`：

| 生成 | 不生成（始终归主配置） |
|---|---|
| `backend` 段（含 `server`、`option httpchk`） | `global`、`defaults`、日志、`stats socket` |
| 路由规则：自包含模式的 `frontend`，或规则模式的 map 文件 | TLS 证书/`bind ssl`、`crt-list`、超时、调优 |
| | 其它与 setline 无关的 `frontend`/`backend` |

理由：

- HAProxy 的 `global`/`defaults` 和 TLS、证书、日志、统计页都是部署方自定义内容，
  生成器无法替它们做决定；片段 + `-f <dir>` 已经能覆盖路由与后端这两件事。
- 校验成本不变：`haproxy -c` 永远校验**整份**配置（含片段），片段模式并不会降低把关强度。
- 真要"全量生成"，正确做法是在外层用模板/配置管理工具渲染 `haproxy.cfg`，再把 setline
  片段作为其中一段拼进去；让 setline 覆盖主文件与"保留自定义内容"的目标冲突，所以不做。

## 两种模式

`agent.bind` 决定模式：

| `agent.bind` | 模式 | 片段内容 | 监听端口归属 |
|---|---|---|---|
| 有值（如 `*:80`） | 自包含 | `frontend http_in`（含 `bind`）+ `backend` | 片段（setline 配置） |
| 留空（推荐） | 规则 | 只有 `backend` + 一份 `.map` 路由表 | 主配置 |

### 自包含模式的文件布局

```
<agent.output>            # frontend + backend，一份文件
```

### 规则模式的文件布局

```
<agent.output>            # 只有 backend 段（必须是 *.cfg，见下）
<output 同目录>/<stem>.map # 路由表：host~path → backend 名
```

`stem` 是 `agent.output` 去掉扩展名的文件名，例如
`output=/var/lib/setline/haproxy/setline.cfg` 会写出 `setline.cfg` 和 `setline.map`。

## 接线（一次性）

### 1. 让 haproxy 加载片段目录

HAProxy 没有 `include`，只能用额外的 `-f`。发行版单元里的 `-f $CFGDIR` 无法通过
`Environment=CFGDIR="a b"` 追加目录（systemd 只会拆成 `-f a b`，haproxy 直接报错），
所以要整段覆盖 `ExecStart`/`ExecReload`，见
`scripts/package/haproxy-setline-cfgdir.conf.example`：

```ini
[Service]
ExecStart=
ExecStart=/usr/sbin/haproxy -Ws -f /etc/haproxy/haproxy.cfg -f /etc/haproxy/conf.d -f /var/lib/setline/haproxy -p /run/haproxy.pid $OPTIONS
ExecReload=
ExecReload=/usr/sbin/haproxy -f /etc/haproxy/haproxy.cfg -f /etc/haproxy/conf.d -f /var/lib/setline/haproxy -c -q $OPTIONS
ExecReload=/bin/kill -USR2 $MAINPID
```

`-f <目录>` **只加载 `*.cfg`**，所以 backend 片段必须叫 `*.cfg`；同目录的 `.map` 是数据
文件，不会被当成配置解析，两者可以放在一起。

### 2. 规则模式：在主配置的 frontend 里加三行

规则模式不生成 frontend，路由靠 map 查询。在你自己持有 `bind` 的 frontend 里加：

```
frontend http_in
  bind *:80
  http-request set-var-fmt(txn.hp) %[req.hdr(host),lower]~%[path]
  use_backend %[var(txn.hp),map_beg(/var/lib/setline/haproxy/setline.map)] if { var(txn.hp),map_beg(/var/lib/setline/haproxy/setline.map) -m found }
  use_backend %[path,map_beg(/var/lib/setline/haproxy/setline.map)] if { path,map_beg(/var/lib/setline/haproxy/setline.map) -m found }
```

- 第一行把 `host` 和 `path` 拼成 `host~path` 作为 map 的查询键。
- 第二行处理精确 host 的路由（map_beg 取最长前缀匹配）。
- 第三行处理 `*` 回退路由：setline 的 `*` 命名空间落到这里，所以它必须排在第二行之后。
- 三行中的路径就是上面那份 `.map`，setline 也会把这三行以注释形式写在 map 文件头部，
  方便直接复制。

setline 生成的 map 形如：

```
app.example.com~/api/edu be_app1_app_example_com_api_edu
/ be_app2_default
```

backend 名由服务名转换而来，不要手写 backend 段；map 文件与 backend 片段由 setline
一起生成、一起原子替换。

## 校验与热加载

片段落盘后由 root 的 `setline-apply` 负责（`setline-apply.timer` 周期驱动，自动按
`agent.type` 选中 haproxy；手工排查时可显式跑 `setline-apply haproxy`）。它按顺序做：

1. 静默窗口（默认 15s）内没有新写入才动手；
2. 片段目录整体内容哈希没变就直接退出（幂等）；
3. `haproxy -f ... -c -q` 校验整份配置；
4. **接线检查**：单元确实加载了片段目录；规则模式下每个 `*.map` 都被主配置引用（否则
   配置合法但路由静默失效）；
5. `systemctl reload haproxy`；
6. 任一步失败就把整个片段目录回滚到 last-known-good。

退出码：`1` 片段本身不合法（已回滚），`3` 接线错误（片段留在磁盘上，等修接线），
`2` 用法错误。为什么用 `systemctl reload` 而不是 `-sf`/`-x`/`SIGHUP`，见
`docs/agent-reload.md`。

## 权限

- `setline` 以 `setline` 用户运行，只写 `/var/lib/setline/haproxy/`，不碰 `/etc/haproxy`；
- `setline-apply` 以 root 运行（`nginx -t`、`haproxy` reload 都要 root）；
- haproxy 以 root 启动后降权，读 `-f <dir>` 里的片段没有问题，目录保持 `0755` 即可。

## 排错

| 现象 | 原因 |
|---|---|
| `wiring error: ... does not load /var/lib/setline/haproxy` | 单元没加 `-f <片段目录>`，或 `apply.conf` 的 `HAPROXY_CONFIGS` 与实际单元不一致 |
| `wiring error: .../setline.map is not referenced` | 主配置 frontend 缺 `map_beg(...)` 那几行（规则模式） |
| `Configuration file has no error but will not start (no listener)` | 自包含片段里 `bind` 为空；规则模式不会出现，因为监听段归主配置 |
| `/api/xxx` 返回 503 且日志无异常 | map 命中了 backend，但 backend 里 `server` 健康检查失败（对端不可达） |
| 改了路由但流量没变 | 片段没写出（agent 未运行/未同步）、静默窗口还没过，或 `*.map` 未被引用 |
