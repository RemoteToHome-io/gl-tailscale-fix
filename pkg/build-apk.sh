#!/bin/sh
# gl-tailscale-fix: derive an OpenWrt-25 (.apk) package from a built .ipk
# Copyright (c) 2026 RemoteToHome Consulting (https://remotetohome.io)
# https://github.com/RemoteToHome-io/gl-tailscale-fix
#
# OpenWrt 25.12 replaced opkg with apk (Alpine Package Keeper, apk-tools v3); ipk packages
# cannot be installed there. Rather than maintain a second staging path, this script unpacks
# the already-built .ipk and repacks it with `apk mkpkg`, so the .apk is content-identical to
# the .ipk by construction. The mkpkg invocation mirrors OpenWrt's own build system
# (include/package-pack.mk): --info fields, arch:noarch for arch-independent packages, and
# maintainer scripts via --script hooks. Hook mapping:
#   postinst -> post-install AND post-upgrade   (postinst is upgrade-agnostic by design)
#   prerm    -> pre-deinstall                    (removal only — apk upgrades never run it,
#                                                 which is exactly the PKG_UPGRADE=1 skip
#                                                 the opkg prerm implements by hand)
#
# Requirements: apk-tools >= 3 (apk mkpkg), run as root or under fakeroot — extraction must
# preserve the archive's 0/0 ownership or mkpkg records the build user instead (same failure
# class the ipk build fixed with tar --owner=0). CI runs this inside an alpine:edge container.
#
# Usage: build-apk.sh <path/to/package.ipk> [out-dir]
set -eu

IPK="$1"
OUT_DIR="${2:-$(dirname "$IPK")}"

command -v apk >/dev/null 2>&1 || { echo "ERROR: apk not found (need apk-tools >= 3)" >&2; exit 1; }
apk mkpkg --help >/dev/null 2>&1 || { echo "ERROR: this apk lacks mkpkg (need apk-tools >= 3)" >&2; exit 1; }
[ -f "$IPK" ] || { echo "ERROR: ipk not found: $IPK" >&2; exit 1; }
if [ "$(id -u)" != "0" ]; then
    echo "WARNING: not running as root — extracted file ownership will be recorded as $(id -un)," >&2
    echo "         not root. Run as root or under fakeroot for a shippable package." >&2
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

tar xzf "$IPK" -C "$WORK"
mkdir -p "$WORK/files" "$WORK/ctrl"
tar xzf "$WORK/data.tar.gz" -C "$WORK/files"
tar xzf "$WORK/control.tar.gz" -C "$WORK/ctrl"

ctl() { sed -n "s/^$1: //p" "$WORK/ctrl/control" | head -1; }
NAME=$(ctl Package)
VERSION=$(ctl Version)
MAINT=$(ctl Maintainer)
# Collapse the control file's multi-line Description (continuation lines begin with a space)
DESC=$(awk '
    /^Description:/ { sub(/^Description: */, ""); d = $0; next }
    d != "" && /^ /  { line = $0; sub(/^ +/, "", line); d = d " " line; next }
    d != ""          { print d; d = ""; exit }
    END              { if (d != "") print d }
' "$WORK/ctrl/control")

[ -n "$NAME" ] && [ -n "$VERSION" ] || { echo "ERROR: could not parse Package/Version from control" >&2; exit 1; }

# apk's version grammar differs from opkg's: CI dev builds use "0.1.0-ci.N", which apk
# rejects. Map the dev suffix to apk's valid _pN form; clean X.Y.Z release versions pass
# through untouched.
APK_VERSION=$(echo "$VERSION" | sed 's/-ci\./_p/')

SCRIPTS=""
[ -f "$WORK/ctrl/postinst" ] && SCRIPTS="$SCRIPTS --script post-install:$WORK/ctrl/postinst --script post-upgrade:$WORK/ctrl/postinst"
[ -f "$WORK/ctrl/prerm" ]    && SCRIPTS="$SCRIPTS --script pre-deinstall:$WORK/ctrl/prerm"

OUT="$OUT_DIR/${NAME}-${APK_VERSION}.apk"
# SOURCE_DATE_EPOCH=0 mirrors package-pack.mk (reproducible timestamps).
# $SCRIPTS word-splitting is deliberate; all paths are space-free mktemp paths.
SOURCE_DATE_EPOCH=0 apk mkpkg \
    --info "name:$NAME" \
    --info "version:$APK_VERSION" \
    --info "description:$DESC" \
    --info "arch:noarch" \
    --info "license:GPL-3.0" \
    --info "maintainer:$MAINT" \
    --info "url:https://github.com/RemoteToHome-io/gl-tailscale-fix" \
    $SCRIPTS \
    --files "$WORK/files" \
    --output "$OUT"

sha256sum "$OUT" > "$OUT.sha256"
echo "Built: $OUT"
