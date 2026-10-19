#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export SETLINE_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$SETLINE_HOME"

set -e -o pipefail

ferror() {
  echo "==========================================================" >&2
  echo "$1" >&2
  echo "$2" >&2
  echo "==========================================================" >&2
  exit 1
}

sys_release_version() {
  local os_id
  os_id=$(source /etc/os-release && echo "$ID")
  if [ "$os_id" = "fedora" ]; then
    REVISION="1.fc$(source /etc/os-release && echo "$VERSION_ID")"
  else
    REVISION="1.el$(source /etc/os-release && echo "$VERSION_ID")"
  fi
}

# 老版 rpm（CentOS 7 的 4.11）会把注释行里的段名（百分号 + install/files/pre...）
# 当成段标记截断，剩下的文字被当作命令执行。生成的 spec 里除行首的段标记外，不允许
# 再出现这种写法。
check_spec() {
  local bad
  bad=$(awk '!/^%/ && /%[a-zA-Z_]/ {print "  line " NR ": " $0}' "$1")
  if [ -n "$bad" ]; then
    ferror "Generated spec has a section name outside the start of a line:" "$bad"
  fi
}

dub build --build=release-nobounds --compiler=ldc2

E=0
LIST=""
fcheck() {
  if ! command -v "$1" >/dev/null 2>&1; then
    LIST=$LIST" "$1
    E=1
  fi
}
fcheck gzip
fcheck rpmbuild
fcheck fakeroot
fcheck strip
if [ "$E" -eq 1 ]; then
  ferror "Missing commands on your system:" "$LIST"
fi

MAINTAINER="duantihua <duantihua@163.com>"
VENDOR="Beangle"
# 版本以 git tag 为唯一来源（如 v0.0.4 -> 0.0.4），dub.json 里不再写 version。
TAG=$(git describe --tags --abbrev=0 2>/dev/null)
if [ -z "$TAG" ]; then
  ferror "Could not determine version from git tag" "Run this script in the git checkout, after the release tag exists."
fi
VERSION=$(sed 's/^v//' <<<"$TAG")
if [ "$(git describe --tags --exact-match 2>/dev/null)" != "$TAG" ]; then
  echo "WARNING: HEAD is not at $TAG; the package will still be labelled $VERSION." >&2
fi
if [ -z "$REVISION" ]; then
  sys_release_version
fi
DESTDIR="$SETLINE_HOME/target"
VERSION=$(sed 's/-/~/' <<<"$VERSION")
ARCH="x86_64"

PKGDIR="setline-${VERSION}-${REVISION}.${ARCH}"
RPMFILE="setline-${VERSION}-${REVISION}.${ARCH}.rpm"
RPMDIR="$DESTDIR/rpmbuild"

# 不跳过已存在的产物：包名里的版本来自 git tag，开发期一个版本对应多次源码改动，
# 「已存在就退出 0」会让人以为重建过，手里却还是旧包。每次全量重建（与 micdn 一致）。
rm -f "$DESTDIR/$RPMFILE"
rm -rf "$DESTDIR/$PKGDIR"
mkdir -p "$DESTDIR/$PKGDIR"
pushd "$DESTDIR/$PKGDIR" >/dev/null

mkdir -p usr/bin usr/share/setline usr/share/doc/setline usr/lib/setline usr/lib/systemd/system
cp -f "$SETLINE_HOME/target/setline" usr/bin/setline
strip --strip-unneeded usr/bin/setline
cp -f "$SETLINE_HOME/scripts/package/setline.json" usr/share/setline/setline.json.default
cp -f "$SETLINE_HOME/scripts/package/setline.conf.default" usr/share/setline/setline.conf.default
cp -f "$SETLINE_HOME/scripts/package/haproxy-setline-cfgdir.conf.example" usr/share/setline/haproxy-setline-cfgdir.conf.example
# 用户文档整目录安装：配置参考、reload 设计、部署、API 说明与发布说明都在 docs 里，
# 只装其中一篇会让包内的 Documentation= 指向一份孤零零的文档。
cp -f "$SETLINE_HOME"/docs/*.md usr/share/doc/setline/
# 变更历史随包安装：升级前想知道「这一版动了什么」不该先去找仓库。
cp -f "$SETLINE_HOME/CHANGELOG.md" usr/share/doc/setline/CHANGELOG.md
cp -f "$SETLINE_HOME/scripts/package/setline-apply" usr/lib/setline/setline-apply
cp -f "$SETLINE_HOME/scripts/package/setline-agent" usr/lib/setline/setline-agent
cp -f "$SETLINE_HOME/scripts/package/setline.service" usr/lib/systemd/system/setline.service
cp -f "$SETLINE_HOME/scripts/package/setline-agent.service" usr/lib/systemd/system/setline-agent.service
cp -f "$SETLINE_HOME/scripts/package/setline-agent.timer" usr/lib/systemd/system/setline-agent.timer

chmod -R 0755 .
chmod 0644 usr/share/setline/setline.json.default usr/share/setline/setline.conf.default usr/share/setline/haproxy-setline-cfgdir.conf.example usr/share/doc/setline/*.md usr/lib/systemd/system/setline.service usr/lib/systemd/system/setline-agent.service usr/lib/systemd/system/setline-agent.timer
chmod 0755 usr/bin/setline usr/lib/setline/setline-apply usr/lib/setline/setline-agent

cd ..
DATE=$(LC_ALL=C date '+%a %b %d %Y')
changes="* $DATE $MAINTAINER - ${VERSION}-${REVISION}\n"
changes+="  - setline binary package\n"

cat >setline.spec <<EOF
# 包里只有已 strip 的二进制，不需要 debuginfo 子包；Fedora 的自动 debugsource
# 对 D 源码会算出空清单，让 rpmbuild 直接失败，所以显式关掉。
%global debug_package %{nil}
Name: setline
Version: ${VERSION}
Release: ${REVISION}
Summary: Beangle local HTTP path proxy
Group: Development/System
License: GPLv3+
URL: https://github.com/beangle/setline
Vendor: ${VENDOR}
Packager: ${MAINTAINER}
ExclusiveArch: ${ARCH}
Requires: systemd util-linux
Provides: setline(${ARCH}) = ${VERSION}-${REVISION}

%description
setline is a small local HTTP path router and transparent proxy.
It routes by host and URL path prefix to local backend ports.
EOF

# 脚本段与 %files 来自共用片段，保证 SRPM 重编出来的包与直接发布的包一致。
echo >>setline.spec
cat "$SETLINE_HOME/scripts/package/setline.spec.common" >>setline.spec

cat >>setline.spec <<EOF
%changelog
$(printf '%b' "$changes")
EOF

mkdir -p "$RPMDIR"
echo "%define _rpmdir $RPMDIR" >>setline.spec
check_spec setline.spec
fakeroot rpmbuild --quiet --buildroot="$DESTDIR/$PKGDIR" -bb --target "$ARCH" --define '_binary_payload w9.xzdio' setline.spec

popd >/dev/null
mv "$RPMDIR/$ARCH/setline-$VERSION-$REVISION.$ARCH.rpm" "$DESTDIR/$RPMFILE"
rm -rf "$RPMDIR" "$DESTDIR/$PKGDIR" "$DESTDIR/setline.spec"

echo "Built: $DESTDIR/$RPMFILE"
