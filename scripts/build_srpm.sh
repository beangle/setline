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
VERSION_RAW=$(awk -F'"' '/"version"/{print $4; exit}' "$SETLINE_HOME/dub.json")
VERSION_RPM=$(sed 's/-/~/' <<<"$VERSION_RAW")
REVISION=""
sys_release_version

DESTDIR="$SETLINE_HOME/target"
RPMDIR="$DESTDIR/rpmbuild-src"
SRPMFILE="setline-${VERSION_RPM}-${REVISION}.src.rpm"
FORCE=0
[ "$1" = "-f" ] && FORCE=1

if [ -f "$DESTDIR/$SRPMFILE" ] && [ "$FORCE" != "1" ]; then
  echo "$SRPMFILE - already exist (use -f to rebuild)"
  exit 0
fi

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
Name: setline
Version: ${VERSION_RPM}
Release: ${REVISION}
Summary: Beangle local HTTP path proxy
License: GPLv3+
Vendor: Beangle
URL: https://github.com/beangle/setline
Source0: %{name}-%{version}.tar.gz
BuildRequires: ldc dub git gcc make zlib-devel openssl-devel binutils
Requires: systemd

%description
setline is a small local HTTP path router and transparent proxy.
It routes by host and URL path prefix to local backend ports.

%prep
%setup -q

%build
dub fetch
dub build --build=release-nobounds --compiler=ldc2

%install
rm -rf %{buildroot}
install -D -m 0755 target/setline %{buildroot}/usr/bin/setline
strip --strip-unneeded %{buildroot}/usr/bin/setline
install -D -m 0644 scripts/package/setline.json %{buildroot}/usr/share/setline/setline.json.default
install -D -m 0644 scripts/package/setline.service %{buildroot}/usr/lib/systemd/system/setline.service

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
$(printf '%s' "$changes")
EOF

rpmbuild --define "_topdir $RPMDIR" -bs "$RPMDIR/SPECS/setline.spec"

mv -f "$RPMDIR/SRPMS/$SRPMFILE" "$DESTDIR/$SRPMFILE"
rm -rf "$RPMDIR"

echo "SRPM: $DESTDIR/$SRPMFILE"
