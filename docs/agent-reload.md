# setline-agent 手工刷新、渲染与 apply

`setline-agent` 是**手工执行的命令**，不是常驻进程，也不再安装 systemd timer。

需要刷新远端配置或重建片段时，手工执行：

```bash
# 1. 以 setline 用户下载并核对 manifest
sudo -u setline -g beangle -- \
  setline-agent pull --check --stage --config /etc/setline/setline.conf

# 2. root 安装已核对的文件
sudo setline-agent pull --install --config /etc/setline/setline.conf

# 3. 以 setline 用户渲染 routes 缓存
sudo -u setline -g beangle -- \
  setline-agent render --config /etc/setline/setline.conf

# 4. root 校验并 reload
sudo setline-apply
```

或者用一次性编排入口：

```bash
sudo setline-agent-run
```

`setline-agent-run` 按 `setline.conf` 执行上面的 pull、render、apply，不带
`--remote`，也不读取额外参数。

## manifest

`pull --check --stage` 先 GET manifest，再按哈希下载变化的资源：

```text
/api/bashub/config/{project}/setline-manifest
```

manifest 只包含 proxy 和证书的 SHA-256；`routes` 在每次手工刷新时重新下载。

## 文件

```text
/usr/bin/setline-agent
/usr/lib/setline/setline-agent-run
/usr/lib/setline/setline-apply
/etc/setline/setline.conf
/etc/setline/certs/
<agent.output>/routes.json
<agent.output>/remote.manifest.json
```

## 权限

- 下载、解析 manifest、render：`setline` 用户
- `pull --install`、`setline-apply`：root
- `setline-agent-run`：root 编排，用 `runuser` 把下载/渲染降权到 `setline`
- 不在 root 进程里解析远端响应

## 没有 timer

包不再安装：

```text
setline-agent.service
setline-agent.timer
```

不会自动轮询 bashub，也不会自动 render。配置变化后需要手工执行上面的命令。

`setline.service` 仍然可以独立运行；它与 `setline-agent` 不互相读取配置，也不依赖
agent 的刷新节奏。

## apply

`setline-apply` 根据 `[agent] type` 选择 haproxy/nginx，校验片段，
执行 `systemctl reload`，失败时回滚片段目录。`--force` 用于 proxy 主配置或证书
变化后强制走一次完整校验。
