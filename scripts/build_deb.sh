#!/bin/bash
# Debian/Ubuntu 打包脚本。需在 Debian 系系统运行，或安装 dpkg：apt install dpkg-dev fakeroot
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

dub build --build=release-nobounds --compiler=ldc2

E=0
LIST=""
fcheck() {
  if ! command -v "$1" >/dev/null 2>&1; then
    LIST=$LIST" "$1
    E=1
  fi
}
fcheck dpkg-deb
fcheck fakeroot
fcheck strip
if [ "$E" -eq 1 ]; then
  ferror "Missing commands on your system:" "$LIST"
fi

MAINTAINER="duantihua <duantihua@163.com>"
VERSION=$(awk -F'"' '/"version"/{print $4; exit}' "$SETLINE_HOME/dub.json")
REVISION="1"
if [ "$1" = "-f" ]; then
  FORCE=1
elif [ -n "$1" ]; then
  REVISION="$1"
fi
DESTDIR="$SETLINE_HOME/target"
ARCH="amd64"
DEBFILE="setline_${VERSION}-${REVISION}_${ARCH}.deb"
PKGDIR="$DESTDIR/setline_${VERSION}-${REVISION}_${ARCH}"

if [ -f "$DESTDIR/$DEBFILE" ] && [ "$FORCE" != "1" ]; then
  echo "$DEBFILE - already exist"
  exit 0
fi

rm -f "$DESTDIR/$DEBFILE"
rm -rf "$PKGDIR"

mkdir -p "$PKGDIR"
pushd "$PKGDIR" >/dev/null

mkdir -p usr/bin usr/share/setline usr/lib/systemd/system
cp -f "$SETLINE_HOME/target/setline" usr/bin/setline
strip --strip-unneeded usr/bin/setline
cp -f "$SETLINE_HOME/scripts/package/setline.json" usr/share/setline/setline.json.default
cp -f "$SETLINE_HOME/scripts/package/setline.service" usr/lib/systemd/system/setline.service

chmod 0755 usr usr/bin usr/share usr/share/setline usr/lib usr/lib/systemd usr/lib/systemd/system
chmod 0755 usr/bin/setline
chmod 0644 usr/share/setline/setline.json.default usr/lib/systemd/system/setline.service

mkdir -p DEBIAN

# 不设 conffiles：/etc/setline/setline.json 由 postinst 首次生成，不由包跟踪，卸载时保留。

cat >DEBIAN/control <<EOF
Package: setline
Version: ${VERSION}-${REVISION}
Section: web
Priority: optional
Architecture: ${ARCH}
Maintainer: ${MAINTAINER}
Homepage: https://github.com/beangle/setline
Depends: adduser
Description: Beangle local HTTP path proxy
 setline is a small local HTTP path router and transparent proxy.
 It routes by host and URL path prefix to local backend ports.
EOF

cat >DEBIAN/preinst <<'PREINST'
#!/bin/sh
set -e
if ! getent group beangle >/dev/null 2>&1; then
  addgroup --system beangle
fi
if ! getent passwd setline >/dev/null 2>&1; then
  adduser --system --ingroup beangle --home /var/lib/setline --no-create-home --disabled-login setline 2>/dev/null || \
  useradd -r -g beangle -d /var/lib/setline -s /usr/sbin/nologin -c "Setline proxy" setline
else
  usermod -g beangle setline 2>/dev/null || true
fi
mkdir -p /var/lib/setline /var/log/setline
PREINST

cat >DEBIAN/postinst <<'POSTINST'
#!/bin/sh
set -e
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
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
fi
POSTINST

cat >DEBIAN/prerm <<'PRERM'
#!/bin/sh
set -e
if [ "$1" = "remove" ] && command -v systemctl >/dev/null 2>&1; then
  systemctl stop setline 2>/dev/null || true
fi
PRERM

cat >DEBIAN/postrm <<'POSTRM'
#!/bin/sh
set -e
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload || true
fi
POSTRM

chmod 0555 DEBIAN/preinst DEBIAN/postinst DEBIAN/prerm DEBIAN/postrm

popd >/dev/null

fakeroot dpkg-deb --build -Zxz "$PKGDIR" "$DESTDIR/$DEBFILE" 2>/dev/null || \
fakeroot dpkg-deb --build "$PKGDIR" "$DESTDIR/$DEBFILE"

rm -rf "$PKGDIR"

echo "Built: $DESTDIR/$DEBFILE"
