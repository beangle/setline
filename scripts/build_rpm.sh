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

mkdir -p usr/bin usr/share/setline usr/lib/systemd/system
cp -f "$SETLINE_HOME/target/setline" usr/bin/setline
strip --strip-unneeded usr/bin/setline
cp -f "$SETLINE_HOME/scripts/package/setline.json" usr/share/setline/setline.json.default
cp -f "$SETLINE_HOME/scripts/package/setline.service" usr/lib/systemd/system/setline.service

chmod -R 0755 .
chmod 0644 usr/share/setline/setline.json.default usr/lib/systemd/system/setline.service
chmod 0755 usr/bin/setline

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
mkdir -p /var/lib/setline /var/log/setline

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
systemctl daemon-reload 2>/dev/null || :

%preun
if [ "\$1" = 0 ]; then
  systemctl stop setline 2>/dev/null || :
fi

%postun
systemctl daemon-reload 2>/dev/null || :

# /etc/setline/setline.json is created in %post, not tracked in %files,
# so package removal preserves the local runtime config.
%files
%attr(0755,root,root) /usr/bin/setline
%attr(0644,root,root) /usr/share/setline/setline.json.default
%attr(0644,root,root) /usr/lib/systemd/system/setline.service

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
