# HAProxy 集成

本文交代 setline agent 生成的 HAProxy 片段怎么接到 HAProxy 上：生成什么、不生成什么、
两种模式的差别、一次性接线步骤，以及校验/热加载和排错。

## 版本要求

**最低要求 HAProxy ≥ 2.0**，2.0 以上任意版本都能跑（本仓库在 2.0.33、2.2.9、3.0.25 上
实测过）。低于 2.0 的版本（CentOS 7 自带的 1.5.18 就是）不在支持范围内。先跑
`haproxy -v` 对一下。下面这些门槛来自官方手册和源码（不是经验值），低版本会以各种
「配置打不开 / 未知关键字」的面目失败：

| 能力 | 需要 | 依据 |
|---|---|---|
| `-f <目录>`（加载片段目录） | ≥ 1.7，本项目基线取 2.0 | 1.6 手册写 `-f <cfgfile>`，1.7 起写 `-f <cfgfile\|cfgdir>`；1.8.30 源码即 `cfgfiles_expand_directories()` |
| `-W` / `-Ws`（master-worker，`kill -USR2` 重载） | ≥ 1.8 | 1.6 手册没有 `-W`，1.8 起才有 |
| **规则模式**的三行 map（`set-header` + `req.hdr` + `map_beg`） | ≥ 2.0 | 用的都是 1.5 起就有的指令和转换器，没有新关键字；已在 2.0.33、2.2.9、3.0.25 实测 |
| 自包含模式（`acl` + `use_backend`） | ≥ 2.0 | 同样都是老指令 |

所以门槛就是 **HAProxy ≥ 2.0**：两种模式（规则模式 / 自包含模式）在这条线以上通用，
不需要 2.6+，也不需要为不同版本准备两套写法。老平台要么升 haproxy，要么换 nginx。

CentOS 7 上还有两个坑，报错时很容易误判成「配置写错」：

- CentOS 7 **没有** `/etc/haproxy/conf.d`（那是 Fedora/RHEL 更新的单元才有的 `CFGDIR`），
  照抄本文的 `-f` 列表会直接报
  `[ALERT] ... Could not open configuration file /etc/haproxy/conf.d : No such file or directory`；
- CentOS 7 自带的 **1.5.18 也不认目录**，把目录传给 `-f` 同样是上面那句（1.5 把它当普通
  文件打开）。它低于最低要求，只能用自包含模式 + 单个 `-f <文件>` 硬撑，或者直接换
  nginx。

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

## setline 配置示例

先选数据来源：**边缘机聚合多台 setline** 用 `peers`（下面第一个例子）；haproxy 与
setline、basctl **同机**时不配 `peers`/`remote`，setline 边当本机代理边渲染片段
（见「单机部署」）。

### 聚合多台 setline（peers）

跑 haproxy 这台机器上，`/etc/setline/setline.json` 只有 `agent` 一段，**没有 `listen`、
没有 `routes`**：配了 `agent` 就不再启动本地代理，它只负责渲染片段。

```json
{
  "agent": {
    "type": "haproxy",
    "output": "/var/lib/setline/haproxy/setline.cfg",
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
| `type` | `haproxy` | 决定片段语法，也是 `setline-apply auto` 的分派依据 |
| `output` | `.../setline.cfg` | 片段落盘路径，**必须是 `.cfg`**（`-f <dir>` 只加载 `*.cfg`），同目录派生 `setline.map` |
| `bind` | `""` | 留空 = 规则模式（监听段归主配置）；写 `"*:80"` = 自包含模式 |
| `token` | `shared-token` | 所有 peer 的默认 `X-Setline-Token`，单个 peer 可用自己的 `token` 覆盖 |
| `peers[].url` | `http://10.0.1.10:8080` | 对端 setline 的基地址：既用于读路由表，也提供回源主机（**只取主机、丢掉端口**，业务端口由每条路由自带） |
| `sync` | `interval` / 10000 | 常驻，每 10s 重渲染一次；缺省 `once` 是跑一轮就退出 |

自包含模式只改 `bind`，其余不动：

```json
{
  "agent": {
    "type": "haproxy",
    "output": "/var/lib/setline/haproxy/setline.cfg",
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

### 单机部署（haproxy 与 setline 同机）

haproxy、setline、basctl 装在同一台机器上时，回源目标和 setline 调度的后端是同一批
进程，不配 `peers` 也**不需要** `remote`：setline 照常监听 `listen` 接收 basctl 推的
路由，同时把本机路由表渲染成片段（回源主机固定 `127.0.0.1`）。

```json
{
  "listen": "127.0.0.1:8080",
  "agent": {
    "type": "haproxy",
    "output": "/var/lib/setline/haproxy/setline.cfg",
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
| `listen` / `routes` | 不配（纯渲染机，不监听） | 配（本机代理，basctl 推到这里） |
| 服务名前缀 | peer 的 `name` | `local` |
| 回源主机 | 各 peer 的 `url` 主机 | `127.0.0.1` |
| 重渲染时机 | `sync` 周期 / 外层 timer | 启动一次 + 每次管理接口改路由 |

`setline-apply.timer` 仍然照用：片段变了才 reload（见「校验与热加载」）。

写完先校验，这一步不需要 peer 在线：

```bash
setline -c -f /etc/setline/setline.json
```

片段落盘后的校验与热加载见「校验与热加载」一节。

## 接线（一次性）

### 1. 让 haproxy 加载片段目录

HAProxy 没有 `include`，只能用额外的 `-f`。先看清发行版单元长什么样，别凭印象
（RHEL/Fedora、Debian、容器镜像都不一样）：

```bash
systemctl cat haproxy                                  # 主文件 + 所有 drop-in，每段前有 # 路径
systemctl show -p FragmentPath -p DropInPaths haproxy  # 只要路径
systemctl status haproxy | head -3                     # Loaded: 行也会带路径
rpm -ql haproxy | grep /systemd/system/                # rpm 系（deb 系换 dpkg -L haproxy）
```

`FragmentPath` 就是那个「systemd 的 haproxy 文件」：RHEL/Fedora 上是
`/usr/lib/systemd/system/haproxy.service`，Debian 上是
`/lib/systemd/system/haproxy.service`。**不要直接改它**——包升级会覆盖，`rpm -V` 也会
一直报文件被改动。要改就在 `/etc/systemd/system/haproxy.service.d/` 放 drop-in，
它优先于发行版文件，升级不动。

为什么必须整段覆盖 `ExecStart`/`ExecReload`：单元里的 `-f $CFGDIR` 只能带**一个**目录，
`Environment=CFGDIR="a b"` 只会被 systemd 拆成 `-f a b`，haproxy 把 `b` 当多余参数报错
（实测 exit 1）。所以只能把两个 `-f` 都写进命令行。包里的模板
`/usr/share/setline/haproxy-setline-cfgdir.conf.example` 就是给这一步用的：

```bash
sudo install -d /etc/systemd/system/haproxy.service.d
sudo cp /usr/share/setline/haproxy-setline-cfgdir.conf.example \
        /etc/systemd/system/haproxy.service.d/setline.conf
sudo systemctl daemon-reload && sudo systemctl restart haproxy
```

等价的手工写法是 `sudo systemctl edit haproxy`（默认落到
`/etc/systemd/system/haproxy.service.d/override.conf`，可以和上面的 `setline.conf` 并存），
把下面两段贴进去。注意**先写空的 `ExecStart=` / `ExecReload=`**（空行就是把发行版那份
清掉），漏了就变成一条命令写两次，systemd 直接拒绝：
`Service has more than one ExecStart= setting, which is only allowed for Type=oneshot
services. Refusing.`

```ini
[Service]
ExecStart=
ExecStart=/usr/sbin/haproxy -Ws -f /etc/haproxy/haproxy.cfg -f /etc/haproxy/conf.d -f /var/lib/setline/haproxy -p /run/haproxy.pid $OPTIONS
ExecReload=
ExecReload=/usr/sbin/haproxy -f /etc/haproxy/haproxy.cfg -f /etc/haproxy/conf.d -f /var/lib/setline/haproxy -c -q $OPTIONS
ExecReload=/bin/kill -USR2 $MAINPID
```

**照抄发行版单元**：上面这几行要以 `systemctl cat haproxy` 输出的原行为准（`-Ws`、
`-p <pidfile>`、`$OPTIONS` 一个都不能少；`$CONFIG`/`$PIDFILE`/`$CFGDIR`/`$OPTIONS` 由
单元自己定义，照抄变量名即可），只在中间插一个 `-f <片段目录>`。
发行版升级后如果原行变了，`setline-apply` 的接线自检会以退出码 3 提醒（见「校验与
热加载」）。

改完验证两件事：

```bash
systemctl cat haproxy | grep setline                       # drop-in 被读到了
systemctl show -p ExecStart -p ExecReload haproxy | grep -F /var/lib/setline/haproxy
```

第二条正是 `setline-apply` 接线自检做的事（它 grep `systemctl show -p ExecStart -p
Environment`），命令能搜到就说明自检能过。

RHEL/Fedora 的单元把额外参数交给 `/etc/sysconfig/haproxy` 的 `OPTIONS`（Debian 是
`/etc/default/haproxy` 的 `EXTRAOPTS`），写 `OPTIONS="-f /var/lib/setline/haproxy"`
haproxy 也会接受；但那来自 `EnvironmentFile`，不出现在 `systemctl show` 的
`Environment`/`ExecStart` 里，接线自检看不见它会误报 wiring error，所以本文统一用
drop-in。

`-f <目录>` **只加载 `*.cfg`**，所以 backend 片段必须叫 `*.cfg`；同目录的 `.map` 是数据
文件，不会被当成配置解析，两者可以放在一起。

### 2. 规则模式：在主配置的 frontend 里加三行

规则模式不生成 frontend，路由靠 map 查询。在你自己持有 `bind` 的 frontend 里加：

```
frontend http_in
  bind *:80
  http-request set-header X-Setline-Route %[req.hdr(host),lower,field(1,:)]~%[path]
  use_backend %[req.hdr(X-Setline-Route),map_beg(/var/lib/setline/haproxy/setline.map)] if { req.hdr(X-Setline-Route),map_beg(/var/lib/setline/haproxy/setline.map) -m found }
  use_backend %[path,map_beg(/var/lib/setline/haproxy/setline.map)] if { path,map_beg(/var/lib/setline/haproxy/setline.map) -m found }
```

- 第一行把 host 和 path 拼成 `host~path` 作为 map 的查询键：`req.hdr(host)` 原样保留
  大小写，所以先 `lower`；`field(1,:)` 去掉 Host 里的端口（浏览器/curl 访问
  `http://localhost:8080/...` 时 Host 是 `localhost:8080`，不剥就永远对不上 map 里的
  `localhost`——setline 自己匹配时也剥端口，这里必须一致）；`path` 是大小写敏感的，
  不能跟着一起 lower。
- 第二行处理精确 host 的路由（map_beg 取最长前缀匹配）。
- 第三行处理 `*` 回退路由：setline 的 `*` 命名空间落到这里，所以它必须排在第二行之后。
- 三行中的路径就是上面那份 `.map`，setline 也会把这三行以注释形式写在 map 文件头部，
  方便直接复制。
- **为什么用 `set-header` 而不是 `set-var-fmt`**：`set-var-fmt` 是 2.6 才加的动作，
  2.0–2.5 上会以 `invalid variable 'set-var-fmt(txn.hp)'` 直接拒绝启动；而
  `set-header` 的 log-format、`req.hdr`、`map_beg` 加动态 `use_backend` 这套组合 1.5
  起就存在，2.0 以上通用，所以规则模式只保留这一种写法。Map 查询、`*` 回退、host 大小写
  三条语义都不变。
- 代价是请求里多了一个内部头。**setline 生成的 backend 会自己加
  `http-request del-header X-Setline-Route` 把它删掉**（已实测 2.0/2.2/3.0 都不会传给
  应用）；如果你把 map 的某条路由指到 setline 之外的 backend，需要自己补一行
  `del-header`。

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
`docs/agent-reload.md`。**timer 装完不会自动启用**，要 `sudo systemctl enable --now
setline-apply.timer`；手工执行、日志与参数覆盖见 `docs/agent-reload.md` 的「启用与使用」。

## 权限

- `setline` 以 `setline` 用户运行，只写 `/var/lib/setline/haproxy/`，不碰 `/etc/haproxy`；
- `setline-apply` 以 root 运行（`nginx -t`、`haproxy` reload 都要 root）；
- haproxy 以 root 启动后降权，读 `-f <dir>` 里的片段没有问题，目录保持 `0755` 即可。

## 排错

| 现象 | 原因 |
|---|---|
| `wiring error: ... does not load <片段目录>` | 单元没给 `-f` 片段目录（见「接线（一次性）」），或 `HAPROXY_CONFIGS` 与实际单元不一致 |
| `wiring error: .../setline.map is not referenced` | 主配置 frontend 缺 `map_beg(...)` 那几行（规则模式） |
| `Configuration file has no error but will not start (no listener)` | 自包含片段里 `bind` 为空；规则模式不会出现，因为监听段归主配置 |
| `Could not open configuration file <目录>` | 目录不存在（老发行版没有 `conf.d`），或 HAProxy < 1.7 根本不认 `-f <目录>`（本项目最低要求 2.0，见「版本要求」） |
| `invalid variable 'set-var-fmt(txn.hp)'` | 用了 2.6+ 才有的写法；换成上面的 `set-header` 三行（2.0 起通用） |
| `/api/xxx` 返回 503 且日志无异常 | map 命中了 backend，但 backend 里 `server` 健康检查失败（对端不可达） |
| 改了路由但流量没变 | 片段没写出（agent 未运行/未同步）、静默窗口还没过，或 `*.map` 未被引用 |
