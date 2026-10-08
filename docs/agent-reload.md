# Agent 片段的热加载（setline-apply）

本文交代 `scripts/package/setline-apply` 与配套 systemd 单元的设计考虑。
它处理的是「片段已经在磁盘上之后」的那一段：校验、热加载、失败回滚。
片段本身怎么接到 haproxy/nginx 上（两种模式、文件布局、一次性接线）见
`docs/haproxy-integration.md` 与 `docs/nginx-integration.md`。

## 职责边界

| 组件 | 负责 | 不负责 |
|---|---|---|
| `setline`（`User=setline`） | 读 peer 路由表、合并、原子写出片段 | 不碰系统配置目录、不发信号、不 reload |
| `setline-apply`（root，oneshot） | 校验、reload、回滚 | 不生成片段、不做服务发现 |
| `haproxy` / `nginx` | 按各自方式加载片段 | 不感知 setline |

`setline` 监听网络，不应持有 root。特权只留在 `setline-apply` 这一个短命进程里。

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
OnUnitInactiveSec=20s
```

代价是最多一个周期的延迟；配置同步不差这几秒。同时 `setline-apply.service`
设 `StartLimitInterval=0`，因为这个 unit 就是被周期触发的，幂等动作不怕重复
（为什么不是 `StartLimitIntervalSec=`，见 [deployment.md](deployment.md) 的
「systemd 版本兼容」）。

## 处理哪个代理：由 agent.type 决定

timer 只有一个，跑 `setline-apply auto`，代理由配置决定，不需要人工挑实例：

```bash
setline -f /etc/setline/setline.json --agent-type   # 打印 haproxy / nginx / 空
```

- `--agent-type` 让 setline 自己解析 JSON（复用同一套配置校验），shell 侧只做字符串
  比较，避免在 bash 里手写 JSON 解析；
- `auto` 遍历 `SETLINE_CONFIGS`（默认 `/etc/setline/setline.json`，可在
  `/etc/setline/apply.conf` 里加多份），把选中的代理解重去重后逐个交给
  `setline-apply <proxy>` 执行，每个代理各自持锁、各自记录状态；
- 配置里没有 `agent`（普通代理机器）→ 什么都不做，直接退出 0；
- 配置的 `agent.type` 指向本机没装的代理 → 打警告跳过，不算失败；
- 退出码取更严重的那个：片段不合法（1）优先于接线错误（3）。

## 幂等与防抖

- **幂等**：`setline-apply` 先算片段目录的内容哈希，与 `applied.sha256` 相同就
  `exit 0`。重复触发是免费的，不需要精确防抖。
- **静默窗口**：片段最后一次修改距今不足 `SETLINE_APPLY_QUIET_SECONDS`（默认 15s）
  就跳过，等下一拍。滚动发布时多台 peer 先后更新，窗口能避免按中间态反复 reload，
  对「摘除」尤其重要。
- **不在脚本里 sleep 等稳定**：那会占住 oneshot，和 systemd 的记账、超时打架。
  用 mtime 判断，不阻塞。

## 回滚粒度

回滚以**整个片段目录**为单位，而不是单个文件：

- 当前 agent 只写一个文件，但 `-f dir` 模型下目录里可能有别的内容，将来也可能多文件。
- per-file 的 `.prev` 有漏洞：新增的文件不会被删掉、被删的文件不会被补回，回滚后
  可能残留半新半旧，校验继续失败。

实现上维护 `lastgood/` 目录快照（`/var/lib/setline/apply/<proxy>/lastgood`）：

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
  见 `haproxy-setline-cfgdir.conf.example`。

## 权限模型

```
/var/lib/setline/haproxy/   setline:beangle 0755   setline 写，root 读
/var/lib/setline/nginx/     同上
/var/lib/setline/apply/     状态与 lastgood 快照
/etc/haproxy/haproxy.cfg    root，只被读
/etc/nginx/nginx.conf       root，只被读（加 include 行）
```

片段目录归 setline 自己，因此不需要给 `/etc/haproxy` 或 `/etc/nginx` 放权，发行版
升级也不会重置。跨文件系统 rename 不会出问题：`writeSnippet` 在目标同目录写 tmp 再
rename，只要片段目录本身可写即可。

## 已知边界

- 重载命令目前写死为 `systemctl reload <service>`，服务名可用 `HAPROXY_SERVICE` /
  `NGINX_SERVICE` 覆盖；如果部署不用 systemd，需要自行替换。
- SELinux 开启时，nginx 读 `/var/lib/setline/nginx` 需要合适的标签
  （本机 SELinux 为 Disabled，未验证）。
- `setline-apply` 依赖 `flock`、`sha256sum`、`find -printf`（GNU），仅面向 Linux。
- 这是「片段生成」之后的半段；重新生成片段仍由 `setline -f` 完成。
