# HAProxy 集成

本文交代 setline agent 生成的 HAProxy 片段怎么接到 HAProxy 上：生成什么、不生成什么、
文件布局、一次性接线步骤，以及校验/热加载和排错。

> **定位**：setline 永远部署在 haproxy/nginx **之后**，不是用户访问的第一站。推荐形态是
> haproxy 直接回源业务端口、setline 只渲染片段（本文就是这套）；也可以让 setline 作为
> haproxy 的下级代理承接数据面，但那样必须先满足 `docs/roadmap.md` 的前置条件。两种形态
> 下 setline 都不面对不可信客户端。

## 版本要求

**最低要求 HAProxy ≥ 2.0**，2.0 以上任意版本都能跑（本仓库在 2.0.33、2.2.9、3.0.25 上
实测过）。低于 2.0 的版本（CentOS 7 自带的 1.5.18 就是）不在支持范围内。先跑
`haproxy -v` 对一下。下面这些门槛来自官方手册和源码（不是经验值），低版本会以各种
「配置打不开 / 未知关键字」的面目失败：

| 能力 | 需要 | 依据 |
|---|---|---|
| `-f <目录>`（加载片段目录） | ≥ 1.7，本项目基线取 2.0 | 1.6 手册写 `-f <cfgfile>`，1.7 起写 `-f <cfgfile\|cfgdir>`；1.8.30 源码即 `cfgfiles_expand_directories()` |
| `-W` / `-Ws`（master-worker，`kill -USR2` 重载） | ≥ 1.8 | 1.6 手册没有 `-W`，1.8 起才有 |
| **规则模式**的四行 map（`set-var` + `concat` + `map_beg`） | ≥ 2.0 | `set-var`、`concat`、`map_beg` 都是老指令和转换器，没有新关键字；已在 2.0.33、2.2.9、3.0.25 实测 |

所以门槛就是 **HAProxy ≥ 2.0**：片段只用 2.0 起就有的老指令，不需要 2.6+，也不需要
为不同版本准备两套写法。老平台要么升 haproxy，要么换 nginx。

CentOS 7 上还有两个坑，报错时很容易误判成「配置写错」：

- CentOS 7 **没有** `/etc/haproxy/conf.d`（那是 Fedora/RHEL 更新的单元才有的 `CFGDIR`），
  照抄本文的 `-f` 列表会直接报
  `[ALERT] ... Could not open configuration file /etc/haproxy/conf.d : No such file or directory`；
- CentOS 7 自带的 **1.5.18 也不认目录**，把目录传给 `-f` 同样是上面那句（1.5 把它当普通
  文件打开）。它低于最低要求，要么升 haproxy，要么直接换 nginx。

## 生成范围：部分生成，不接管主配置

setline **只生成片段**，不生成也不改动 `/etc/haproxy/haproxy.cfg`：

| 生成 | 不生成（始终归主配置） |
|---|---|
| `backend` 段（`server` + TCP `check`；**从不**生成 `option httpchk`） | `global`、`defaults`、日志、`stats socket` |
| 路由规则：一份 map 文件（主配置的 frontend 用它查 backend） | TLS 证书/`bind ssl`、`crt-list`、超时、调优、`frontend` 的 `bind` |
| | 其它与 setline 无关的 `frontend`/`backend` |

理由：

- HAProxy 的 `global`/`defaults` 和 TLS、证书、日志、统计页都是部署方自定义内容，
  生成器无法替它们做决定；片段 + `-f <dir>` 已经能覆盖路由与后端这两件事。
- 校验成本不变：`haproxy -c` 永远校验**整份**配置（含片段），片段模式并不会降低把关强度。
- 健康检查固定只做 TCP `check`（端口能连上就算健康），和 setline 自己的 `healthCheck`
  口径一致，**永远不发 `option httpchk`**。HTTP 检查按响应状态码判健康，应用根路径返回
  404/401 太常见，只会把本来能用的后端判成 DOWN；要按业务路径探活请在主配置里自己写。
- 真要"全量生成"，正确做法是在外层用模板/配置管理工具渲染 `haproxy.cfg`，再把 setline
  片段作为其中一段拼进去；让 setline 覆盖主文件与"保留自定义内容"的目标冲突，所以不做。

## 数据面与控制面：haproxy 直接回源后端

setline **不在业务流量的路径上**。片段里的 `server` 写的就是业务端口：

```
# 单机部署：回源主机固定 127.0.0.1
server local_app_example_com_api_edu_0 127.0.0.1:9002 check
# peers 模式：回源主机取自 peer.url，端口取自对端的路由表
server app_app_example_com_api_edu_0 10.0.1.10:9002 check
```

两个入口职责不同：

- `listen`：数据面，也是 peer 协议（`GET /_setline/routes`）的入口。`curl -H
  'Host: app.example.com' http://127.0.0.1:8080/<path>` 能直接调试本机解析和转发结果，
  路由表读也认它；haproxy 的 backend 正常情况下**不要**指到这里——白白多一跳，还丢掉
  haproxy 自己的负载均衡与健康检查。
- `adminListen`（缺省 `127.0.0.1:10080`）：**写**接口的唯一入口，也是状态页和
  `status.json` 的唯一入口。basctl 用 `PUT` / `DELETE /_setline/routes*` 登记本机路由；
  它缺省绑回环，所以改路由是纯本机操作。

所以 `listen` 平时绑回环（`"127.0.0.1:8080"`）就够；跨机采集走 `listen` 上的路由表读，
要么**在 haproxy 上按源地址放行**，要么直接把采集机的地址写进被读端的 `peerReaders`
（读方不带任何凭据，见 `docs/configuration.md` 的「peerReaders」一节）。

真的要把 setline 当下级代理（客户端 → haproxy → setline）时，**frontend 必须自己拒掉
管理路径**：路由表读搭在 `listen` 上，而读只看来源地址——经 haproxy 转发的请求来源是回环，
不拒的话任何能过 haproxy 的客户端都能读到路由表。写和状态页不用担心：`PUT` 和
`status.json` 只挂在管理口上，转发过来也只有 `404`。接线：

```
frontend http_in
  bind *:80
  http-request deny if { path_beg /_setline }
```

haproxy 的 `http-request deny` 在转发前生效，被挡的请求连 setline 都不会连到。要放采集机
进来就按源地址开一条更窄的规则（`http-request deny if { path_beg /_setline } !{ src 10.0.1.0/24 }`），
而不是整条放行；也可以把规则收成精确匹配 `{ path /_setline/routes }`，只放采集机真正要用的
那一个端点。

读写分挂在两个监听上（`adminListen` 缺省 `127.0.0.1:10080`，见 `docs/configuration.md`
的「adminListen」一节）：haproxy 的 backend 只该指向 `listen`，写请求留在本机。

落盘后一眼自检：

```bash
grep -n '^  server ' /var/lib/setline/haproxy/setline.cfg
```

每行都应是 `127.0.0.1:<业务端口>`（单机）或 `<peer 主机>:<业务端口>`（peers）。出现
`<某主机>:8080` 就是配错了，8080 是 setline 的管理端口，不是业务端口。

## 文件布局

```
<agent.output>/haproxy/setline.cfg     # 只有 backend 段（必须是 *.cfg，见下）
<agent.output>/haproxy/setline.map     # 路由表：host~path → backend 名
```

片段**永远不含 `frontend` / `bind`**：监听归你自己的主配置（曾经有个 `agent.bind`
开关让片段自带监听，已取消）。

`agent.output` 是**根目录**，`haproxy/` 子目录与两个文件名都由 setline 决定（不开放
配置，`setline-apply` 与 `-f <dir>` 按这套固定路径接线）。例如
`output=/var/lib/setline` 会写出 `/var/lib/setline/haproxy/setline.cfg` 和
`/var/lib/setline/haproxy/setline.map`，目录不存在时自动创建。

## setline 配置示例

先选数据来源：**边缘机聚合多台 setline** 用 `peers`（下面第一个例子）；haproxy 与
setline、basctl **同机**时不配 `peers`，setline 边收 basctl 推的路由边渲染片段
（见「单机部署」）。

### 聚合多台 setline（peers）

跑 haproxy 这台机器上，`/etc/setline/setline.json` 只有 `agent` 一段，**没有 `listen`、
没有 `routes`**：配了 `agent` 就不再启动本地代理，它只负责渲染片段。

```json
{
  "agent": {
    "type": "haproxy",
    "output": "/var/lib/setline",
    "peers": [
      { "name": "app1", "url": "http://10.0.1.10:8080" },
      { "name": "app2", "url": "http://10.0.1.11:8080" }
    ]
  }
}
```

各字段在这里的作用：

| 字段 | 值 | 说明 |
|---|---|---|
| `type` | `haproxy` | 决定片段语法，也是 `setline-apply auto` 的分派依据 |
| `output` | `/var/lib/setline` | 片段落盘**根目录**（绝对路径），setline 在其下建 `haproxy/` 并写固定文件名 `setline.cfg`（`-f <dir>` 只加载 `*.cfg`）与 `setline.map` |
| `peers[].url` | `http://10.0.1.10:8080` | 对端 setline 的基地址：既用于读路由表，也提供回源主机（**只取主机、丢掉端口**，业务端口由每条路由自带） |

纯渲染机上 `setline` **跑一轮就退出**：进程里没有调度循环，重渲染由包里的
`setline-render.timer`（每 30s）拉起 `setline-render.service` 再来一轮。所以要启用的是 timer，不是
常驻服务：

```bash
sudo systemctl enable --now setline-render.timer      # 纯渲染机：周期重渲染
sudo systemctl enable --now setline-apply.timer # 片段变了就校验 + reload
```

某一台 peer 暂时读不到只会在这一轮打一行 `setline agent render failed: ...` 并以非 0
退出，下一轮照常再试，片段保持上一轮的内容（写文件是按内容哈希幂等的）。

### 单机部署（haproxy 与 setline 同机）

haproxy、setline、basctl 装在同一台机器上时，回源目标和 setline 调度的后端是同一批
进程，不配 `peers` 即可：setline 监听 `listen` 接收 basctl 推的路由
（控制面，业务流量不经过它），同时把本机路由表渲染成片段（回源主机固定 `127.0.0.1`）。

```json
{
  "listen": "127.0.0.1:8080",
  "agent": {
    "type": "haproxy",
    "output": "/var/lib/setline"
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
| 服务名前缀 | peer 的 `name` | `local` |
| 回源主机 | 各 peer 的 `url` 主机 | `127.0.0.1` |
| 重渲染时机 | `setline-render.timer` 周期拉起（跑一轮就退出） | 启动一次 + 每次管理接口改路由（进程常驻） |

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

### 2. 规则模式：在主配置的 frontend 里加四行

规则模式不生成 frontend，路由靠 map 查询。在你自己持有 `bind` 的 frontend 里加：

```
frontend http_in
  bind *:80
  http-request set-var(txn.setline_path) path
  http-request set-var(txn.setline_route) req.hdr(host),lower,field(1,:),concat(~,txn.setline_path)
  use_backend %[var(txn.setline_route),map_beg(/var/lib/setline/haproxy/setline.map)] if { var(txn.setline_route),map_beg(/var/lib/setline/haproxy/setline.map) -m found }
  use_backend %[path,map_beg(/var/lib/setline/haproxy/setline.map)] if { path,map_beg(/var/lib/setline/haproxy/setline.map) -m found }
```

- 前两行把 host 和 path 拼成 `host~path` 作为 map 的查询键，存进事务变量：
  `req.hdr(host)` 原样保留大小写，所以先 `lower`；`field(1,:)` 去掉 Host 里的端口
  （浏览器/curl 访问
  `http://localhost:8080/...` 时 Host 是 `localhost:8080`，不剥就永远对不上 map 里的
  `localhost`——setline 自己匹配时也剥端口，这里必须一致）；`path` 是大小写敏感的，
  不能跟着一起 lower。
- 第三行处理精确 host 的路由（map_beg 取最长前缀匹配）。
- 第四行处理 `*` 回退路由：setline 的 `*` 命名空间落到这里，所以它必须排在第三行之后。
- 四行中的路径就是上面那份 `.map`，setline 也会把这几行以注释形式写在 map 文件头部，
  方便直接复制。
- **为什么用 `set-var` + `concat` 而不是 `set-header`**：`set-header` 会往请求里加一个
  内部头，跟请求一起到达应用，你还得记得在自己的 backend 里 `del-header`；`set-var`
  把查找键存在事务变量里，请求原样透传给后端，应用看不到任何 setline 的痕迹。拼字符串
  只能落在 `concat` 上，因为 `set-var` 接收的是 sample、**不吃 log-format**
  （`set-var(txn.x) %[...]~%[...]` 在 2.0/2.2/3.0 上都会报 `unknown fetch method`）。
- **为什么不用 `set-var-fmt`**：它是 2.6 才加的动作，2.0–2.5 上会以
  `invalid variable 'set-var-fmt(txn.hp)'` 直接拒绝启动。`set-var` + `concat` +
  `map_beg` + 动态 `use_backend` 这套组合 2.0 起就通用（已在 2.0.33、2.2.9、3.0.25
  实测），所以规则模式只保留这一种写法。Map 查询、`*` 回退、host 大小写三条语义都不变。

**路由表变化不必 reload。** 只是 `*.map` 的内容变了（backend 片段没变）时，
`setline-apply` 会自动通过 haproxy 的 admin socket 就地热同步，不打断连接；只有
新增/删除 backend 才需要 reload。socket 路径是自动探测的（配置文件里的
`stats socket`、单元的 `-S`、以及几个默认位置），探不到就老老实实回退 reload，
**不需要任何配置**。细节与怎么确认走了哪条路见 `docs/agent-reload.md`。

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
纯渲染机还要启用 `setline-render.timer`（周期重渲染），见「聚合多台 setline（peers）」。
reload 到底有没有发生（master PID 不变、worker PID 换掉、`show proc` 的 reload 计数）
见 `docs/agent-reload.md` 的「如何确认 reload 真的发生」。

## 权限

- `setline` 以 `setline` 用户运行，只写 `/var/lib/setline/haproxy/`，不碰 `/etc/haproxy`；
- `setline-apply` 以 root 运行（`nginx -t`、`haproxy` reload 都要 root）；
- haproxy 以 root 启动后降权，读 `-f <dir>` 里的片段没有问题，目录保持 `0755` 即可。

## 排错

| 现象 | 原因 |
|---|---|
| `wiring error: ... does not load <片段目录>` | 单元没给 `-f` 片段目录（见「接线（一次性）」），或 `HAPROXY_CONFIGS` 与实际单元不一致 |
| `wiring error: .../setline.map is not referenced` | 主配置 frontend 缺 `map_beg(...)` 那几行（规则模式） |
| `Configuration file has no error but will not start (no listener)` | 主配置里没有任何 `bind`；setline 的片段不含监听段（监听归主配置） |
| `Could not open configuration file <目录>` | 目录不存在（老发行版没有 `conf.d`），或 HAProxy < 1.7 根本不认 `-f <目录>`（本项目最低要求 2.0，见「版本要求」） |
| `invalid variable 'set-var-fmt(...)'` / `unknown fetch method` | 用了 2.6+ 的 `set-var-fmt`，或拿 log-format 去喂 `set-var`；换成上面的 `set-var` + `concat` 四行（2.0 起通用） |
| `/api/xxx` 返回 503 且日志无异常 | map 命中了 backend，但 backend 里 `server` 健康检查失败（对端不可达） |
| `Server be_xxx/... is DOWN, reason: Layer7 wrong status, code: 404` | 主配置（`defaults` 或你自己的 backend）里有 `option httpchk`：setline 片段只发 TCP `check`，不会产生这条例；把该 HTTP 检查挪走或换一个返回 2xx 的路径 |
| WebSocket 升级请求回 `400 Bad request` | haproxy 自己就要求带 `Upgrade: websocket` 的请求有合法的 `Sec-WebSocket-Key` 头；缺了它连 setline 都不会看到 |
| WebSocket 握手回 `502 Bad Gateway`（消息是 *invalid or incomplete response*） | 后端的 101 缺 `Sec-WebSocket-Accept`，或者算错。haproxy 3.0 起会校验它，setline 只是原样透传后端响应，所以问题在业务后端而不是代理 |
| 改了路由但流量没变 | 片段没写出（agent 未运行/未同步）、静默窗口还没过，或 `*.map` 未被引用 |
