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
- `/usr/lib/systemd/system/setline.service`
- `/etc/setline/setline.json`

首次安装时会从 `/usr/share/setline/setline.json.default` 复制配置到
`/etc/setline/setline.json`。运行时路由更新需要写回配置文件，所以该文件归
`setline:beangle` 所有，并对所属组可写。

`/etc/setline/setline.json` 不作为 deb/rpm 包文件跟踪，卸载软件包时保留。
