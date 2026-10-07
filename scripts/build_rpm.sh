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
VERSION=$(awk -F'"' '/"version"/{print $4; exit}' "$SETLINE_HOME/dub.json")
if [ -z "$REVISION" ]; then
  sys_release_version
fi
DESTDIR="$SETLINE_HOME/target"
VERSION=$(sed 's/-/~/' <<<"$VERSION")
ARCH="x86_64"

PKGDIR="setline-${VERSION}-${REVISION}.${ARCH}"
RPMFILE="setline-${VERSION}-${REVISION}.${ARCH}.rpm"
RPMDIR="$DESTDIR/rpmbuild"

if [ -f "$DESTDIR/$RPMFILE" ] && rpm -qip "$DESTDIR/$RPMFILE" >/dev/null 2>&1 && [ "$1" != "-f" ]; then
  echo "$RPMFILE - already exist"
  exit 0
fi

rm -f "$DESTDIR/$RPMFILE"
rm -rf "$DESTDIR/$PKGDIR"
mkdir -p "$DESTDIR/$PKGDIR"
pushd "$DESTDIR/$PKGDIR" >/dev/null

mkdir -p usr/bin usr/share/setline usr/share/doc/setline usr/lib/setline usr/lib/systemd/system
cp -f "$SETLINE_HOME/target/setline" usr/bin/setline
strip --strip-unneeded usr/bin/setline
cp -f "$SETLINE_HOME/scripts/package/setline.json" usr/share/setline/setline.json.default
cp -f "$SETLINE_HOME/scripts/package/apply.conf.example" usr/share/setline/apply.conf.example
cp -f "$SETLINE_HOME/scripts/package/haproxy-setline-cfgdir.conf.example" usr/share/setline/haproxy-setline-cfgdir.conf.example
# 用户文档整目录安装：配置参考、reload 设计、部署与 API 说明都在 docs 里，
# 只装其中一篇会让包内的 Documentation= 指向一份孤零零的文档。
cp -f "$SETLINE_HOME"/docs/*.md usr/share/doc/setline/
cp -f "$SETLINE_HOME/scripts/package/setline-apply" usr/lib/setline/setline-apply
cp -f "$SETLINE_HOME/scripts/package/setline.service" usr/lib/systemd/system/setline.service
cp -f "$SETLINE_HOME/scripts/package/setline-apply.service" usr/lib/systemd/system/setline-apply.service
cp -f "$SETLINE_HOME/scripts/package/setline-apply.timer" usr/lib/systemd/system/setline-apply.timer

chmod -R 0755 .
chmod 0644 usr/share/setline/setline.json.default usr/share/setline/apply.conf.example usr/share/setline/haproxy-setline-cfgdir.conf.example usr/share/doc/setline/*.md usr/lib/systemd/system/setline.service usr/lib/systemd/system/setline-apply.service usr/lib/systemd/system/setline-apply.timer
chmod 0755 usr/bin/setline usr/lib/setline/setline-apply

cd ..
DATE=$(LC_ALL=C date '+%a %b %d %Y')
changes="* $DATE $MAINTAINER - ${VERSION}-${REVISION}\n"
changes+="  - setline binary package\n"

cat >setline.spec <<EOF
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
Requires: systemd
Provides: setline(${ARCH}) = ${VERSION}-${REVISION}

%description
setline is a small local HTTP path router and transparent proxy.
It routes by host and URL path prefix to local backend ports.

%pre
getent group beangle >/dev/null 2>&1 || groupadd -r beangle
if ! getent passwd setline >/dev/null 2>&1; then
  useradd -r -g beangle -d /var/lib/setline -s /sbin/nologin -c "Setline proxy" setline
else
  usermod -g beangle setline 2>/dev/null || :
fi
mkdir -p /var/lib/setline /var/log/setline /var/lib/setline/haproxy /var/lib/setline/nginx /var/lib/setline/apply

%post
mkdir -p /etc/setline
if [ ! -f /etc/setline/setline.json ]; then
  cp -f /usr/share/setline/setline.json.default /etc/setline/setline.json
fi
chown setline:beangle /etc/setline/setline.json
chmod 0664 /etc/setline/setline.json
chown setline:beangle /etc/setline
chmod 2775 /etc/setline
chown -R setline:beangle /var/lib/setline /var/log/setline
chmod 2775 /var/lib/setline /var/log/setline
chmod 0755 /var/lib/setline/haproxy /var/lib/setline/nginx /var/lib/setline/apply
systemctl daemon-reload 2>/dev/null || :

%preun
if [ "\$1" = 0 ]; then
  systemctl stop setline 2>/dev/null || :
  systemctl disable setline 2>/dev/null || :
  # setline-apply@*.timer 是老版本的按代理模板单元，升级上来的机器可能还开着。
  for unit in /etc/systemd/system/timers.target.wants/setline-apply.timer /etc/systemd/system/timers.target.wants/setline-apply@*.timer; do
    [ -e "\$unit" ] || continue
    systemctl disable --now "\$(basename "\$unit" .timer)" 2>/dev/null || :
  done
fi

%postun
systemctl daemon-reload 2>/dev/null || :

# /etc/setline/setline.json is created in %post, not tracked in %files,
# so package removal preserves the local runtime config.
%files
%attr(0755,root,root) /usr/bin/setline
%attr(0644,root,root) /usr/share/setline/setline.json.default
%attr(0644,root,root) /usr/share/setline/apply.conf.example
%attr(0644,root,root) /usr/share/setline/haproxy-setline-cfgdir.conf.example
%attr(0644,root,root) /usr/share/doc/setline/*.md
%attr(0755,root,root) /usr/lib/setline/setline-apply
%attr(0644,root,root) /usr/lib/systemd/system/setline.service
%attr(0644,root,root) /usr/lib/systemd/system/setline-apply.service
%attr(0644,root,root) /usr/lib/systemd/system/setline-apply.timer

%changelog
$(printf '%b' "$changes")
EOF

mkdir -p "$RPMDIR"
echo "%define _rpmdir $RPMDIR" >>setline.spec
fakeroot rpmbuild --quiet --buildroot="$DESTDIR/$PKGDIR" -bb --target "$ARCH" --define '_binary_payload w9.xzdio' setline.spec

popd >/dev/null
mv "$RPMDIR/$ARCH/setline-$VERSION-$REVISION.$ARCH.rpm" "$DESTDIR/$RPMFILE"
rm -rf "$RPMDIR" "$DESTDIR/$PKGDIR" "$DESTDIR/setline.spec"

echo "Built: $DESTDIR/$RPMFILE"
