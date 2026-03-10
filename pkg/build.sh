#!/bin/sh
# gl-tailscale-fix: Build IPK package without OpenWrt SDK
# Copyright (c) 2026 RemoteToHome Consulting (https://remotetohome.io)
# https://github.com/RemoteToHome-io/gl-tailscale-fix
# Usage: ./pkg/build.sh [version]
set -eu

for cmd in tar gzip sed install du cut; do
	command -v "$cmd" >/dev/null 2>&1 || {
		echo "Error: required command not found: $cmd" >&2
		exit 1
	}
done

if [ -n "${1:-}" ]; then
	RAW_VERSION="$1"
elif [ -n "${VERSION:-}" ]; then
	RAW_VERSION="$VERSION"
elif [ "${GITHUB_REF_TYPE:-}" = "tag" ] && [ -n "${GITHUB_REF_NAME:-}" ]; then
	RAW_VERSION="$GITHUB_REF_NAME"
else
	RAW_VERSION="0.1.0"
fi

# Strip optional leading 'v' from Git tags like v1.2.3.
VERSION="${RAW_VERSION#v}"
PKG_NAME="gl-tailscale-fix"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$ROOT_DIR/build"
OUT_DIR="$ROOT_DIR/build/out"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR/control" "$BUILD_DIR/data" "$OUT_DIR"

# -- Build data.tar.gz (installed files) --

DATA="$BUILD_DIR/data"

# RPC module
install -d "$DATA/usr/lib/oui-httpd/rpc"
install -m 644 "$ROOT_DIR/src/rpc/ts-fix" "$DATA/usr/lib/oui-httpd/rpc/ts-fix"

# UCI config (default template — postinst copies to /etc/config/ on first install)
install -d "$DATA/etc/config"
install -m 644 "$ROOT_DIR/src/config/ts-fix" "$DATA/etc/config/ts-fix.default"

# Hotplug
install -d "$DATA/etc/hotplug.d/iface"
install -m 755 "$ROOT_DIR/src/hotplug/20-ts-fix" "$DATA/etc/hotplug.d/iface/20-ts-fix"

# Procd init script (UCI reload trigger)
install -d "$DATA/etc/init.d"
install -m 755 "$ROOT_DIR/src/init.d/ts-fix" "$DATA/etc/init.d/ts-fix"

# Nginx config + Lua filters
install -d "$DATA/etc/nginx/gl-conf.d"
install -m 644 "$ROOT_DIR/src/nginx/ts-fix.conf" "$DATA/etc/nginx/gl-conf.d/ts-fix.conf"
install -d "$DATA/usr/share/ts-fix"
install -m 644 "$ROOT_DIR/src/nginx/ts-fix-body-filter.lua" "$DATA/usr/share/ts-fix/ts-fix-body-filter.lua"
install -m 644 "$ROOT_DIR/src/nginx/ts-fix-header-filter.lua" "$DATA/usr/share/ts-fix/ts-fix-header-filter.lua"

# Frontend JS (version-stamped + gzipped — nginx has gzip_static on)
install -d "$DATA/usr/share/ts-fix/www"
sed "s/{{VERSION}}/$VERSION/" "$ROOT_DIR/src/www/ts-fix.js" | gzip -c > "$BUILD_DIR/ts-fix.js.gz"
install -m 644 "$BUILD_DIR/ts-fix.js.gz" "$DATA/usr/share/ts-fix/www/ts-fix.js.gz"

# Scripts
install -d "$DATA/usr/bin"
install -m 755 "$ROOT_DIR/src/scripts/ts-fix-update" "$DATA/usr/bin/ts-fix-update"
install -m 755 "$ROOT_DIR/src/scripts/ts-fix-reapply" "$DATA/usr/bin/ts-fix-reapply"
install -m 755 "$ROOT_DIR/src/scripts/ts-fix-watchdog" "$DATA/usr/bin/ts-fix-watchdog"

# Sysupgrade persistence
install -d "$DATA/lib/upgrade/keep.d"
install -m 644 "$ROOT_DIR/src/upgrade/keep.d/gl-tailscale-fix" "$DATA/lib/upgrade/keep.d/gl-tailscale-fix"

# -- Build control.tar.gz (package metadata) --

CTRL="$BUILD_DIR/control"
sed "s/{{VERSION}}/$VERSION/" "$SCRIPT_DIR/control" > "$CTRL/control"
install -m 755 "$SCRIPT_DIR/postinst" "$CTRL/postinst"
install -m 755 "$SCRIPT_DIR/prerm" "$CTRL/prerm"

# -- Assemble ipk --

echo "2.0" > "$BUILD_DIR/debian-binary"

(cd "$CTRL" && tar czf "$BUILD_DIR/control.tar.gz" .)
(cd "$DATA" && tar czf "$BUILD_DIR/data.tar.gz" .)

IPK="$OUT_DIR/${PKG_NAME}_${VERSION}_all.ipk"
# OpenWrt opkg expects tar-based IPK (not ar-based .deb style)
(cd "$BUILD_DIR" && tar czf "$IPK" ./debian-binary ./control.tar.gz ./data.tar.gz)

# Show result
SIZE=$(du -h "$IPK" | cut -f1)
echo "Built: $IPK ($SIZE)"
echo ""
echo "Install on router:"
echo "  scp $IPK root@<router>:/tmp/"
echo "  ssh root@<router> opkg install /tmp/$(basename "$IPK")"
