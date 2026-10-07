# 构建与打包脚本

| 路径 | 用途 |
|------|------|
| `build_deb.sh` | 构建 Debian/Ubuntu `.deb` 安装包 |
| `build_rpm.sh` | 构建二进制 `.rpm` 安装包 |
| `build_srpm.sh` | 构建源码 `.src.rpm`，可在目标机器重编 |
| `package/` | systemd 安装包使用的默认配置和服务文件 |

安装包默认布局：

- `/usr/bin/setline`
- `/usr/share/setline/setline.json.default`
- `/usr/share/setline/apply.conf.example`
- `/usr/share/setline/haproxy-setline-cfgdir.conf.example`
- `/usr/share/doc/setline/*.md`（`docs/` 下的全部文档：配置参考、reload 设计、部署、API 等）
- `/usr/lib/setline/setline-apply`
- `/usr/lib/systemd/system/setline.service`
- `/usr/lib/systemd/system/setline-apply@.service`
- `/usr/lib/systemd/system/setline-apply@.timer`
- `/etc/setline/setline.json`
- `/var/lib/setline/haproxy/`、`/var/lib/setline/nginx/`、`/var/lib/setline/apply/`

首次安装时会从 `/usr/share/setline/setline.json.default` 复制配置到
`/etc/setline/setline.json`。运行时路由更新需要写回配置文件，所以该文件归
`setline:beangle` 所有，并对所属组可写。

`/etc/setline/setline.json` 不作为 deb/rpm 包文件跟踪，卸载软件包时保留。

## 片段热加载

`setline` 只负责把 HAProxy/Nginx 片段原子写到 `/var/lib/setline/<proxy>/`，
校验与 reload 由 root 的 `setline-apply` 完成（timer 驱动、按内容哈希幂等、
失败整体回滚）。接线方式：

- nginx：主配置里 `include /var/lib/setline/nginx/*.conf;`
- haproxy：片段目录作为额外的 `-f`（目录内只加载 `*.cfg`），需要按
  `haproxy-setline-cfgdir.conf.example` 覆盖单元的 `ExecStart`/`ExecReload`，
  因为 `-f $CFGDIR` 无法通过 `Environment=` 追加第二个目录。

启用某个代理的自动应用：

```bash
systemctl enable --now setline-apply@nginx.timer
systemctl enable --now setline-apply@haproxy.timer
```

设计与取舍（为什么不用 `-sf`/`-x`/`SIGHUP`、为什么用 timer 而不是 path 单元、
回滚粒度等）见 `docs/agent-reload.md`。
