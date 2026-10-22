#!/bin/bash
# 生成源码 SRPM，可在目标机器使用 rpmbuild --rebuild setline-*.src.rpm 重编。
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
fcheck tar
if [ "$E" -eq 1 ]; then
  ferror "Missing commands on your system:" "$LIST"
fi

MAINTAINER="duantihua <duantihua@163.com>"
# 版本以 git tag 为唯一来源（如 v0.0.4 -> 0.0.4），dub.json 里不再写 version。
TAG=$(git describe --tags --abbrev=0 2>/dev/null)
if [ -z "$TAG" ]; then
  ferror "Could not determine version from git tag" "Run this script in the git checkout, after the release tag exists."
fi
VERSION_RAW=$(sed 's/^v//' <<<"$TAG")
if [ "$(git describe --tags --exact-match 2>/dev/null)" != "$TAG" ]; then
  echo "WARNING: HEAD is not at $TAG; the package will still be labelled $VERSION_RAW." >&2
fi
VERSION_RPM=$(sed 's/-/~/' <<<"$VERSION_RAW")
REVISION=""
sys_release_version

DESTDIR="$SETLINE_HOME/target"
RPMDIR="$DESTDIR/rpmbuild-src"
SRPMFILE="setline-${VERSION_RPM}-${REVISION}.src.rpm"

# 不跳过已存在的产物，默认全量重建，理由见 build_rpm.sh。
rm -f "$DESTDIR/$SRPMFILE"
rm -rf "$RPMDIR"
mkdir -p "$RPMDIR"/{BUILD,RPMS,SOURCES,SPECS,SRPMS}

(
  cd "$(dirname "$SETLINE_HOME")" || exit 1
  tar czf "$RPMDIR/SOURCES/setline-${VERSION_RPM}.tar.gz" \
    --exclude='setline/.git' \
    --exclude='setline/target' \
    --exclude='setline/.dub' \
    --exclude='setline/.agents' \
    --exclude='setline/.codex' \
    --transform="s,^setline,setline-${VERSION_RPM}," \
    setline
)

DATE=$(LC_ALL=C date '+%a %b %d %Y')
changes="* $DATE $MAINTAINER - ${VERSION_RPM}-${REVISION}"$'\n'
changes+="  - setline source package"$'\n'

cat >"$RPMDIR/SPECS/setline.spec" <<EOF
# 包里只有已 strip 的二进制，不需要 debuginfo 子包；Fedora 的自动 debugsource
# 对 D 源码会算出空清单，让 rpmbuild 直接失败，所以显式关掉。
%global debug_package %{nil}
Name: setline
Version: ${VERSION_RPM}
Release: ${REVISION}
Summary: Beangle local HTTP path proxy
Group: Development/System
License: GPLv3+
Vendor: Beangle
Packager: ${MAINTAINER}
ExclusiveArch: x86_64
URL: https://github.com/beangle/setline
Source0: %{name}-%{version}.tar.gz
BuildRequires: ldc dub git gcc make zlib-devel openssl-devel binutils
Requires: systemd util-linux
Provides: setline(x86_64) = %{version}-%{release}

%description
setline is a small local HTTP path router and transparent proxy.
It routes by host and URL path prefix to local backend ports.

%prep
%setup -q

%build
dub fetch
dub build --build=release-nobounds --compiler=ldc2
dub build --build=release-nobounds --compiler=ldc2 --config=agent

%install
rm -rf %{buildroot}
install -D -m 0755 target/setline %{buildroot}/usr/bin/setline
install -D -m 0755 target/setline-agent %{buildroot}/usr/bin/setline-agent
strip --strip-unneeded %{buildroot}/usr/bin/setline
strip --strip-unneeded %{buildroot}/usr/bin/setline-agent
install -D -m 0644 scripts/package/setline.json %{buildroot}/usr/share/setline/setline.json.default
install -D -m 0644 scripts/package/setline.conf.default %{buildroot}/usr/share/setline/setline.conf.default
install -D -m 0644 scripts/package/haproxy-setline-cfgdir.conf.example %{buildroot}/usr/share/setline/haproxy-setline-cfgdir.conf.example
# 用户文档整目录安装：与 build_rpm.sh 同一份清单，docs 全篇加上 CHANGELOG。
install -d -m 0755 %{buildroot}/usr/share/doc/setline
install -m 0644 docs/*.md %{buildroot}/usr/share/doc/setline/
install -m 0644 CHANGELOG.md %{buildroot}/usr/share/doc/setline/CHANGELOG.md
install -D -m 0755 scripts/package/setline-apply %{buildroot}/usr/lib/setline/setline-apply
install -D -m 0755 scripts/package/setline-agent-run %{buildroot}/usr/lib/setline/setline-agent-run
install -D -m 0644 scripts/package/setline.service %{buildroot}/usr/lib/systemd/system/setline.service
install -D -m 0644 scripts/package/setline-agent.service %{buildroot}/usr/lib/systemd/system/setline-agent.service
install -D -m 0644 scripts/package/setline-agent-interval.service %{buildroot}/usr/lib/systemd/system/setline-agent-interval.service
install -D -m 0644 scripts/package/setline-agent.timer %{buildroot}/usr/lib/systemd/system/setline-agent.timer
EOF

# 脚本段与 %files 来自共用片段，与 build_rpm.sh 的二进制包完全一致。
echo >>"$RPMDIR/SPECS/setline.spec"
cat "$SETLINE_HOME/scripts/package/setline.spec.common" >>"$RPMDIR/SPECS/setline.spec"

cat >>"$RPMDIR/SPECS/setline.spec" <<EOF
%changelog
$(printf '%s' "$changes")
EOF

check_spec "$RPMDIR/SPECS/setline.spec"
rpmbuild --define "_topdir $RPMDIR" -bs "$RPMDIR/SPECS/setline.spec"

mv -f "$RPMDIR/SRPMS/$SRPMFILE" "$DESTDIR/$SRPMFILE"
rm -rf "$RPMDIR"

echo "SRPM: $DESTDIR/$SRPMFILE"
