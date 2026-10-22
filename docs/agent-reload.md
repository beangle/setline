# Agent 片段的渲染、热加载（setline-agent / setline-apply）

本文交代 `scripts/package/setline-agent-run`、`scripts/package/setline-apply` 与配套
systemd 单元的设计考虑。常驻的 `setline.service` 负责监听和代理，`setline-agent`
是一轮渲染入口，root 的 `setline-agent-run` 编排渲染和 apply，`setline-apply` 处理
片段落盘之后的校验、热加载和失败回滚。
片段本身怎么接到 haproxy/nginx 上
（两种模式、文件布局、一次性接线）见 `docs/haproxy-integration.md` 与
`docs/nginx-integration.md`。

## 职责边界

| 组件 | 负责 | 不负责 |
|---|---|---|
| `setline`（service，`User=setline`） | 只读 `setline.json`；监听、代理 | 不读 `setline.conf`、不渲染片段、不发信号、不 reload |
| `setline-agent render`（`User=setline`） | 只读 `setline.conf`；合并 `[routes]`/peers 并原子写出片段，然后退出 | 不监听端口、不发信号、不 reload |
| `setline-agent-run`（root，oneshot） | 启动/reload 时做一次远端 manifest 检查；降权执行 `setline-agent render`，然后调用 apply | 不在 root 进程解析远端响应、不直接 reload |
| `setline-agent-interval`（root，oneshot） | timer 每轮只编排 `[routes]`/peers 渲染和 apply | 不访问 bashub、没有 pull/check 入口 |
| `setline-apply`（root，helper） | 校验、map 热同步、reload、回滚 | 不生成片段、不做服务发现 |
| `haproxy` / `nginx` | 按各自方式加载片段 | 不感知 setline |

`setline` **不得以 root 运行**，这是硬性要求而不是部署偏好：它监听网络，接受任意
客户端 HTTP、解析请求头、还做 WebSocket 隧道，这条路径上任何一个解析或内存 bug 都会
直接变成 root 失陷。渲染 peer 路由表同样要解析远端 HTTP/JSON，所以也不能放进
root 编排进程；`setline-agent-run` 必须用 `runuser` 把它降权到 `setline` 用户。

`setline-agent.service` 在启动或 reload 时做一次远端 manifest 检查；下载仍由
`setline` 用户执行，root 的 `setline-agent pull --install` 只读本机 `<agent.output>/remote-stage`、
核对本地哈希并写最终文件，不打开远端 URL。真正的远程下载、manifest/peers 解析和渲染都用
`runuser -u setline -g beangle` 降权到 `setline` 用户。timer 驱动的
`setline-agent-interval.service` 不访问 `[remote]`，只做 peers/本地路由的 render/apply。
`setline-agent pull --check --stage` 和 `pull --install` 分别拒绝 root 与非 root 调用，避免把下载
误跑到 root 或把安装误跑到服务账号。
代码里以 root 启动代理或渲染 agent 会打印一行拒绝并退出（退出码 `2`，对上 unit 的
`RestartPreventExitStatus=2`）。`setline-apply` 以 root 调用的几个只读出口
`setline-agent --agent-type`、`--agent-peers`、`--sync-map`，以及 `-c`、`--help`
不受这条判据约束。
完整条目见 `docs/project-constraints.md` 的 Privilege Model。

## 启用与使用

包只**安装** `setline.service`、`setline-agent.service`、
`setline-agent-interval.service`、`setline-agent.timer` 和
`/usr/lib/setline/{setline-agent-run,setline-apply}` 和 `/usr/bin/setline-agent`，
**不会**替你 enable。写了 `[agent] type` 的机器装完后要自己把 timer 拉起来；需要数据面
代理时再单独启动常驻服务：

```bash
# 1. 启用代理和渲染：开机自启 + 立刻跑第一轮
sudo systemctl enable --now setline.service
sudo systemctl enable --now setline-agent.timer

# 2. 确认它在转：下次触发时间、上一次的结果
systemctl list-timers setline-agent.timer
systemctl status setline-agent.service --no-pager -l
systemctl status setline-agent-interval.service --no-pager -l

# 3. 看日志：渲染和 apply 的输出都进同一个 journal
journalctl -u setline-agent -u setline-agent-interval -n 30 -o cat
journalctl -u setline-agent -u setline-agent-interval -f
```

`setline-agent.timer` 的 `[Unit] Wants=setline-agent.service` 会让第一次启用 timer 时
也执行一次远程检查；之后 timer 只触发 interval 轮次。需要再次检查远端配置时执行
`sudo systemctl reload setline-agent.service`。

普通代理机器（`setline.conf` 没有 `[agent] type`）不需要启用 timer；就算开着也只是一轮
打一行 `no [agent] type in ..., nothing to do` 后退出 0，没有别的副作用。纯渲染机只启用
timer，不启用 `setline.service`；需要数据面时再单独启用服务。两者互不依赖。

### 手工执行

timer 跑的是 `setline-agent-run --interval`（不访问 bashub）；排查时可以分别跑：

```bash
sudo /usr/lib/setline/setline-agent-run --interval      # 本地一轮（render + apply，不访问远端）
sudo /usr/lib/setline/setline-agent-run --remote        # 远端检查 + render + apply
sudo systemctl start setline-agent.service          # 启动时执行 --remote
sudo systemctl reload setline-agent.service         # 重新执行 --remote
sudo -u setline -g beangle -- /usr/bin/setline-agent render --config /etc/setline/setline.conf
# 以下是手工分步刷新
sudo -u setline -g beangle -- /usr/bin/setline-agent pull --check --stage --config /etc/setline/setline.conf
sudo /usr/bin/setline-agent pull --install --config /etc/setline/setline.conf
sudo /usr/lib/setline/setline-apply auto            # 按 [agent] type 做校验 + reload
sudo /usr/lib/setline/setline-apply --now auto      # 刚渲染完，跳过静默窗口立即 apply
sudo /usr/lib/setline/setline-apply --now --force auto  # 远程主配置/证书已更新，强制 apply
sudo /usr/lib/setline/setline-apply haproxy         # 只处理 haproxy，跳过探测
sudo /usr/lib/setline/setline-apply nginx           # 只处理 nginx
```

日志前缀分别是 `setline-agent-run: ` 和 `setline-apply[<proxy>]: `。常见几行：

| 日志 | 含义 |
|---|---|
| `no [agent] type in ..., nothing to do` | 普通代理机，没有 agent 配置 |
| `fragment changed Ns ago (< 15s), deferring` | 单机/手工 apply 还在静默窗口内，等下一拍 |
| `no fragment in <dir>, nothing to apply` | setline 还没写出片段（agent 没跑起来或没写出） |
| `reloaded haproxy` | 校验、接线检查、reload 全部成功 |
| `validation FAILED for the new fragment` + `restored last known good config` | 片段不合法，已整体回滚 |
| `wiring error: ...` | 片段没被代理真正加载/引用，片段留在磁盘上等修接线 |
| `<service> is not active; keeping validated fragment, skipping reload` | 代理没在跑，只记录不 reload |

`setline-apply` 退出码：`0` 无事可做或成功；`1` 片段不合法、reload 失败（已回滚）或
片段目录取值本身有问题；`2` 用法错误（参数不是 `haproxy`/`nginx`/`auto`）；`3` 接线错误。

`setline-agent pull --check --stage` 的退出码：`0` 无变化或远程配置不完整（命令静默跳过）；
`1` 下载、校验或写 staging 失败；`10` proxy 主配置或证书对已更新。`10` 是 agent 与 apply
之间的操作约定：`setline-agent-run --remote` 看到 `10` 并成功安装 staging 后，会执行
`setline-apply --now --force`，确保代理真正验证并 reload 一次；`--force` 同时跳过 map
热同步，避免把主配置变化误判成纯路由变化。`setline-agent pull --install` 成功返回 `0`，本地
staging 损坏或无法写入最终路径时返回 `1`；缺少清单表示本轮没有变化，只清理残留 staging。

### 频率与 reload 参数

timer 的节奏：开机 30s 后第一轮 interval，之后每轮**结束后** 30s 再跑
（`OnBootSec=30s` + `OnUnitInactiveSec=30s` + `AccuracySec=1s`）。改周期别直接改包里的
unit（升级会被覆盖），用 drop-in。interval 轮次不会请求 bashub，也没有 pull/check 入口；
这个间隔只决定 peers/本地路由的合并频率，不触发远端检查。
远端检查发生在 `setline-agent.service` 的启动/reload。需要立即同步时执行
`sudo systemctl reload setline-agent.service`。这条路径只发一次 manifest GET，资源哈希都
没变时不下载 peers、proxy 或证书。

```bash
sudo systemctl edit setline-agent.timer      # 写 [Timer] 段覆盖 OnUnitInactiveSec 等
```

`setline-apply` 的 reload 参数都在 `/etc/setline/setline.conf` 的 `[apply]` 段：片段目录、
`haproxy -f` / `nginx -c` 的配置列表、服务名和静默窗口 `quietSeconds`（默认 15s）。
`type`、`configs`、`fragmentDir`、`service` 省略时由 `[agent] type` 和 `[agent] output`
推导；自定义了片段根目录时要确认 `[apply] configs` 里的片段路径也跟着改，否则校验的不是
服务真正读的那份配置。

`setline-agent` 在同一轮里刚跑完渲染，调用的是 `setline-apply --now`，所以不受
`quietSeconds` 影响。`setline.service` 不再承担片段生成，管理接口修改 `setline.json`
也不会触发重渲染；周期刷新统一由 `setline-agent.timer` 完成。

## 为什么 reload 不能由 setline 做

以本机发行版单元为例（Fedora 的 `haproxy.service`）：

```
ExecStart=/usr/sbin/haproxy -Ws -f $CONFIG -f $CFGDIR -p $PIDFILE $OPTIONS
ExecReload=/usr/sbin/haproxy -f $CONFIG -f $CFGDIR -c -q $OPTIONS
ExecReload=/bin/kill -USR2 $MAINPID
```

- `/run/haproxy.pid` 归 root，master socket 归 root/haproxy；`nginx -s reload`
  要读 root 的 pid 并给 root master 发信号，非特权进程做不到。
- `nginx -t` 更是非 root 就跑不动：它会打开 `/run/nginx.pid`、`error_log` 和
  `/var/lib/nginx/tmp`，实测非 root 直接 `permission denied`。
- `haproxy -c` 是纯解析，非 root 可以；但 reload 不行。

所以校验和重载统一放在 root 的 `setline-apply` 里。

## 为什么用 `systemctl reload` 而不是自己拉进程

HAProxy 有两种 reload 模型，容易混：

- **非 master-worker**：reload = 起一个**新进程**，用 `-sf <old_pids>` 让新进程在
  启动后给旧进程发 FINISH；`-x <socket>` 让新进程从旧进程接管监听 socket。
- **master-worker（`-W` / `-Ws`）**：master 自己持有监听 socket，新 worker 继承，
  reload 只是让 master 重新加载配置。

本机单元是 `-Ws`，man 页写得很清楚：

```
-SIGUSR2  In master-worker mode, reloads the configuration and sends a
          soft-stop signal to old processes.
```

因此：

- **不要**自己执行 `haproxy -W -x ... -sf $(cat /run/haproxy.pid)`。`-sf` 的语义是
  「启动后给这些 pid 发 FINISH」，是给新进程做交接用的，不是让运行中的 master
  重载；`-x` 要的是旧进程暴露的 **fd 传递 socket**（`expose-fd listeners`），和
  配置里的 `stats socket` 不是一回事；而且绕过 systemd 再拉一个 haproxy 会打乱
  `$MAINPID` 跟踪。`-Ws` 下这些都不需要。
- **不要**用 `SIGHUP`——man 页里 `SIGHUP` 只是把 proxy/server 状态 dump 到日志。
- 正确做法是 `systemctl reload haproxy`。发行版单元的 `ExecReload` 已经内置
  「先 `-c -q` 校验，再 `kill -USR2 $MAINPID`」，校验不过就不会重载。
- nginx 单元的 `ExecReload=/usr/sbin/nginx -s reload` **没有**前置校验，所以
  `setline-apply` 自己先跑 `nginx -t`。

归纳一下「谁发信号」：`setline-apply` 自己**从不发信号、不碰 pid 文件**，只调用
`systemctl reload <service>`；发什么信号由单元的 `ExecReload=` 决定，由 root 的 systemd
代发（脚本里的 `reload()` 就一行 `systemctl reload "$SERVICE"`）：

| 代理 | 单元的 `ExecReload=` | systemd 实际发出的信号 |
|---|---|---|
| haproxy（RHEL/Fedora） | `-c -q $OPTIONS` 校验，然后 `/bin/kill -USR2 $MAINPID` | `SIGUSR2` 给 master |
| nginx | `/usr/sbin/nginx -s reload` | 由 nginx 自己发 `SIGHUP` 给 master |

haproxy 收到 `SIGUSR2` 后 master 重读配置、给老 worker 发软退出（man 页：
`In master-worker mode, reloads the configuration and sends a soft-stop signal to old
processes.`）；nginx 收到 `SIGHUP` 后重读配置、起新 worker、老 worker 优雅退出。
haproxy 那条 `-c -q` 排在 `kill` 之前，systemd 按顺序执行、前一条失败就不执行后一条
（实测：reload 返回 1，后面的 `ExecReload` 确实没跑），所以坏配置走不到发信号那一步。

## 路由表热同步：能不 reload 就不 reload

`setline-apply` 在决定 reload 之前会先试一次**热同步**。规则模式下真正决定走向的是
`*.map`，而 haproxy 支持通过 runtime socket 就地改 map，不用重载进程、不打断连接。

**触发条件**（两个都满足才热同步，任一不满足就回退 reload）：

1. 片段目录里**只有 `*.map` 变了**。`setline-apply` 单独记录 backend 片段（非 `*.map`）
   的内容哈希，只有它和上次应用过的一致，才说明本次是纯路由变更。新增或删除 backend
   必须 reload 才能让 haproxy 认识，热同步救不了。
2. 自动探测到一个**能用的 haproxy admin socket**。

**socket 从哪来**（全部自动发现，不引入任何配置项），按顺序试：

1. `[apply] configs` 里各配置文件的 `stats socket <path>`（worker 的 runtime API）；
2. 单元 `ExecStart` 里的 `-S <path>`（master CLI，命令集较小，所以排后面）；
3. 常见默认位置，如 `/run/haproxy/admin.sock`、`/run/haproxy.sock`、`/run/haproxy/master.sock`。

逐个试；**全都不可用、或某个 map 同步失败，就退回 `systemctl reload`**——行为与没有这个
功能时完全一致。

**同步怎么做**：`setline-agent --sync-map <socket> <mapfile>` 读现有 map（`show map <file>`）、
和文件算差量、下发、再回读校验：

- **只增改，最后才删**：`del map` 会让命中的路由立刻回落到 `default_backend`，所以删除
  排在最后，任何时刻都不会出现「路由突然不见」。
- 同名 key 已有重复条目时（`add map` 对已存在的 key 是**追加**而不是覆盖），先 `del`
  清干净再 `add`——重复条目下 haproxy 采用先插入的那个值，留着会让结果不可预期。
- 下发完回读一遍，条目总数与每个 key 的值都对得上才算成功。
- 出口码：`0` 成功、`2` 参数错误、`4` 不可用（socket 连不上、map 没被运行配置引用、
  回读不一致）。`setline-apply` 只在 `0` 时跳过 reload。

**怎么确认走了哪条路**（`journalctl -u setline-agent -o cat`）：

```
setline-apply[haproxy]: hot-synced 1 map file(s) via /run/haproxy/admin.sock (no reload)
```

出现这行就说明**没有** reload：haproxy 的 master PID 不变、worker 也不会换，和下面
`reloaded haproxy` 那行正好对照。

这条路不需要给 setline 开任何特权：socket 由 root 的 `setline-apply` 连，`setline`
（`setline` 用户）只负责把片段写到磁盘。

## 如何确认 reload 真的发生

先看 `setline-apply` 自己怎么说（最直接，且不需要额外接线）：

```bash
journalctl -u setline-agent -n 5 -o cat    # 成功时最后一行是 "reloaded <服务名>"
```

如果这一轮完全没有输出，通常说明片段没变、**故意没有** reload；可以用
`cat "$(dirname "$fragmentDir")/apply/<proxy>/applied.sha256"` 或下一轮真正变更时的
`hot-synced` / `reloaded` 日志确认。静默是对的行为，不是故障。

再确认 haproxy 侧。判断依据是 **master PID 不变、worker PID 换掉**——`-Ws` 下 master
持有监听 socket，reload 只是 fork 一个新 worker 接管，记在同一个 master 上：

```bash
systemctl show -p MainPID haproxy        # master PID，reload 前后不变
pgrep -a haproxy                         # worker 的 PID 会变
ps -o pid,ppid,lstart,cmd -C haproxy     # worker 的 STARTED 是刚才
journalctl -u haproxy -n 20 --no-pager   # reload 后会出现这几行
```

```
systemd[1]: Reloading HAProxy Load Balancer...
haproxy[<master>]: [NOTICE] (<master>) : New worker (<new pid>) forked
haproxy[<master>]: [NOTICE] (<master>) : Loading success.
haproxy[<master>]: [WARNING] (<master>) : Former worker (<old pid>) exited with code 0 (Exit)
```

`Former worker ... exited with code 0` 是软退出完成的正常提示，不是错误；只有 master
PID 变了才说明是重启（`systemctl restart`）而不是 reload。

**最精确的办法是看 reload 计数**，前提是给 haproxy 加了 master CLI socket
（`-S`，2.0 起有；它和配置里的 `stats socket` 是两个不同的 socket）。加在
`ExecStart` 的 `-Ws` 之后（照 `docs/haproxy-integration.md` 的「接线（一次性）」那样
整段覆盖 `ExecStart`，例如 `-S /run/haproxy/master.sock`）：

```bash
echo "show proc" | sudo socat stdio /run/haproxy/master.sock
```

```
#<PID>          <type>          <reloads>       <uptime>        <version>
1271904         master          1 [failed: 0]   0d00h00m05s     3.0.25
# workers
1271950         worker          0               0d00h00m01s     3.0.25
```

`master` 行的 `<reloads>` 每成功 reload 一次 +1，`[failed: N]` 是校验/加载失败的次数。
上面这个格式在 2.0.33 与 3.0.25 上都实测可用（2.0 的输出多一列 `<relative PID>`）。
没有 `-S` 时用上面的 `ps` + journal 判断即可；socket 默认只有 root 能连，所以查询要
`sudo`。

nginx 同理，只是没有 reload 计数可查：`systemctl reload nginx` 后 master PID 不变、
worker 全换，`error_log` 里依次出现
`signal 1 (SIGHUP) received from <pid>, reconfiguring` → `reconfiguring` →
`start worker process <新 pid>` → `worker process <旧 pid> exited with code 0`
（本机 nginx 1.30.4 实测；nginx 的日志默认在 `/var/log/nginx/error.log`）。

## 为什么用 timer 而不是 path 单元

`writeSnippet` 是 tmp + rename 的原子替换，这对 inotify 不友好。实测：

```
watch 文件:  ATTRIB, DELETE_SELF            ← 一次 rename 后 watch 失效，之后收不到通知
watch 目录:  CREATE/MODIFY/CLOSE_WRITE out.cfg.tmp, MOVED_FROM/MOVED_TO out.cfg
```

- 监听**文件**：atomic rename 换掉 inode 之后监听就死了，第一次能触发、之后永久失灵。
- 监听**目录**：能触发，但单次写入会产生一串事件（tmp 的创建/写入/关闭 + 目标
  的 MOVED_TO），触发次数被放大。

再叠加 systemd 的两个限流默认值：

- `systemd.path` 的 `TriggerLimitIntervalSec=` 默认 2s、`TriggerLimitBurst=` 默认
  200，命中会把 path 单元置为 failed（设 0 可禁用）。
- unit 启动限流 `DefaultStartLimitIntervalSec=10s`、`DefaultStartLimitBurst=5`，
  高频触发会被直接拒绝启动。

所以这里不用 path 单元，改用**定时器 + 幂等动作**：

```
OnBootSec=30s
OnUnitInactiveSec=30s
```

代价是最多一个周期的延迟；配置同步不差这几秒。同时
`setline-agent-interval.service` 设 `StartLimitInterval=0`，因为这个 unit 就是被周期
触发的，幂等动作不怕重复
（为什么不是 `StartLimitIntervalSec=`，见 [deployment.md](deployment.md) 的
「systemd 版本兼容」）。

## 处理哪个代理：由 `[agent] type` 决定

timer 只有一个，跑 `setline-agent-run --interval`，代理由配置决定，不需要人工挑实例：

```bash
setline-agent --config /etc/setline/setline.conf --agent-type   # 打印 haproxy / nginx / 空
```

- `--agent-type` 让 `setline-agent` 自己解析 `setline.conf`（复用同一套配置校验），shell 侧只做
  字符串比较，避免在 bash 里手写 INI 解析；
- `--agent-peers` 返回 `[agent] peers` 的数量，便于诊断，但不再决定 agent 是否渲染；
- `setline-agent-run` 始终执行 `runuser -u setline -g beangle -- setline-agent render ...`；
  `[routes]` 总是参与，配了 peers 再把远端路由聚合进来；
- 渲染完成后执行 `setline-apply --now auto` 立即校验/reload；
- `[agent] type` 为空（普通代理机器）→ 什么都不做，直接退出 0；
- 配置的类型不是 `haproxy`/`nginx` 时在配置校验阶段就失败，不会静默跳过；
- 退出码：片段不合法或 reload 失败为 1，接线错误为 3。

## 幂等与防抖

- **幂等**：`setline-apply` 先算片段目录的内容哈希，与 `applied.sha256` 相同就
  `exit 0`。重复触发是免费的，不需要精确防抖。
- **静默窗口**：手工 apply 时，片段最后一次修改距今不足
  `[apply] quietSeconds`（默认 15s）就跳过，等下一拍。滚动发布时多台 peer 先后更新，
  窗口能避免按中间态反复 reload，对「摘除」尤其重要。`setline-agent` 在同一次
  oneshot 里渲染完成后调用 `setline-apply --now`，不需要再等窗口。
- **不在脚本里 sleep 等稳定**：那会占住 oneshot，和 systemd 的记账、超时打架。
  用 mtime 判断，不阻塞。

## 回滚粒度

回滚以**整个片段目录**为单位，而不是单个文件：

- 当前 agent 只写一个文件，但 `-f dir` 模型下目录里可能有别的内容，将来也可能多文件。
- per-file 的 `.prev` 有漏洞：新增的文件不会被删掉、被删的文件不会被补回，回滚后
  可能残留半新半旧，校验继续失败。

实现上维护 `lastgood/` 目录快照（`<agent.output>/apply/<proxy>/lastgood`，默认
`/var/lib/setline/apply/<proxy>/lastgood`）：

- 校验通过、reload 成功后，把当前片段目录快照为 lastgood；
- 校验失败或 reload 失败时，整体还原 lastgood 再 reload 一次，退出非零。

注意校验失败也必须还原：haproxy/nginx 此刻没有重载，坏片段只是躺在磁盘上，但**下一次
服务重启会读到它**，所以不能留在原处。

## 接线自检

片段目录必须是服务实际加载的配置的一部分，否则 reload 是「成功但没生效」的静默空转。
`setline-apply` 会检查并在不匹配时以退出码 3 报错（区别于片段本身不合法的 1）：

- haproxy：`systemctl show haproxy -p ExecStart -p Environment` 中必须出现片段目录。
- nginx：`nginx -T`（展开全部 include）的输出中必须出现片段目录。

两侧接线方式不同：

- **nginx** 有 `include`，主配置里加一行即可：
  `include /var/lib/setline/nginx/*.conf;`
- **haproxy** 没有 `include`，靠多个 `-f`（`-f` 可以指向目录，目录内**只加载 `.cfg`**
  扩展名的文件）。发行版单元的 `-f $CFGDIR` 只能带一个目录，**无法**用
  `Environment=CFGDIR="a b"` 追加第二个：systemd 的词拆分只产出 `-f a b`，haproxy
  会把 `b` 当多余参数报错（实测 exit 1）。所以要整段重写 `ExecStart`/`ExecReload`，
  用 drop-in 覆盖（不要改发行版文件），做法与验证见 `haproxy-integration.md` 的
  「接线（一次性）」第 1 步与 `haproxy-setline-cfgdir.conf.example`。

## 权限模型

```
/var/lib/setline/haproxy/   setline:beangle 0755   setline 写，root 读
/var/lib/setline/nginx/     同上
/var/lib/setline/apply/     <agent.output>/apply，状态与 lastgood 快照
/var/lib/setline/remote-stage/  setline 写，root 安装后删除
/etc/haproxy/haproxy.cfg    root，只被读
/etc/nginx/nginx.conf       root，只被读（加 include 行）
```

片段目录归 setline 自己，因此不需要给 `/etc/haproxy` 或 `/etc/nginx` 放权，发行版
升级也不会重置。跨文件系统 rename 不会出问题：`writeSnippet` 在目标同目录写 tmp 再
rename，只要片段目录本身可写即可。

远程配置同样遵守这条边界：manifest、peers、proxy 和证书只由 setline 用户下载并解析到
`remote-stage/`。root 的 `pull --install` 读取本地 staging，按清单复核 SHA-256 后写入
`setline.conf`、主代理配置和证书目录；安装会继承已有文件的属主和权限，避免把
`setline.conf` 的 `0640` 变成可被其他用户读取的临时文件权限。

片段目录的属主必须能写：`setline-apply` 以 root 跑，如果它在 setline 之前先建出了
目录（`mkdir -p` 在「片段为空就退出」的判断之前），目录会是 `root:root`，`setline`
之后就没法往里写片段。所以脚本在 `mkdir -p` 之后、以及每次回滚重建目录之后，都会检查
一次：**属主是 root 就改成 `[apply] owner`（默认 `setline:beangle`，0755），不是 root
就不动**——不覆盖部署方刻意设置的其他属主。

## 已知边界

- 重载命令目前写死为 `systemctl reload <service>`，服务名可用 `[apply] service` 覆盖；
  如果部署不用 systemd，需要自行替换。
- SELinux 开启时，nginx 读 `/var/lib/setline/nginx` 需要合适的标签
  （本机 SELinux 为 Disabled，未验证）。
- `setline-apply` 依赖 `flock`、`sha256sum`、`find -printf`（GNU），仅面向 Linux。
- 这是「片段生成」之后的半段；重新生成片段由 `setline-agent render --config ...` 完成。
