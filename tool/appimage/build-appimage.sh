#!/usr/bin/env bash
#
# build-appimage.sh — build a Linux AppImage from a Flutter release bundle.
#
# Reusable across Flutter desktop projects: every project-specific value is a
# variable with a default derived from the repo (linux/CMakeLists.txt, pubspec),
# and each is overridable by an environment variable or a flag. Run it after
# `flutter build linux --release`; it prints the path of the produced .AppImage
# on stdout (and nothing else there — logs go to stderr).
#
#   flutter build linux --release
#   tool/appimage/build-appimage.sh
#
# ── Architectures ────────────────────────────────────────────────────────────
# x86_64 and aarch64 are supported, and the target defaults to the host: an
# AppImage is built *on* the architecture it is for. Flutter does not
# cross-compile Linux desktop bundles, and linuxdeploy/appimagetool are native
# binaries, so an aarch64 build (Raspberry Pi 4/5, or a Pi 3 on a 64-bit OS)
# runs this script on an aarch64 host — the Pi itself, typically. One aarch64
# AppImage serves every ARMv8 Pi; there is no 32-bit ARM build because Flutter
# has no armhf Linux desktop target.
#
# ── FUSE 2 vs FUSE 3 ─────────────────────────────────────────────────────────
# The classic AppImage runtime dynamically links libfuse.so.2 (FUSE 2), which
# Ubuntu 24.04+ no longer ships. We avoid that on both ends:
#
#   * Produced AppImage: we embed the modern *static* type2-runtime (pinned,
#     downloaded below, passed via `appimagetool --runtime-file`). It statically
#     links squashfuse and needs only the kernel `fuse` module plus a
#     fusermount/fusermount3 helper — so the app self-mounts on FUSE 2 (22.04)
#     *and* FUSE 3 (24.04/26.04) hosts, with no libfuse2 install required.
#   * Build time: every AppImage-packaged tool below (linuxdeploy, appimagetool)
#     is itself an AppImage. We run them all with APPIMAGE_EXTRACT_AND_RUN=1 so
#     they self-extract instead of FUSE-mounting themselves — no FUSE of either
#     version is needed to *build*, on a GitHub runner or a dev box.
#
# End users with no FUSE at all (e.g. minimal containers) can always run the
# result with `./App.AppImage --appimage-extract-and-run`.
#
# See docs/appimage.md for the full rationale and how to bump the pinned tools.

set -euo pipefail

# ── Locate the project ───────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR_DEFAULT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# Logging, the pinned tools with their checksums, and the verified fetch().
. "$SCRIPT_DIR/common.sh"

usage() {
  cat >&2 <<EOF
Usage: build-appimage.sh [options]

Options (all also settable via the matching UPPER_CASE env var):
  --project-dir DIR   Flutter project root         (default: repo of this script)
  --version VER       Version string in the name   (default: pubspec version)
  --arch ARCH         Target arch: x86_64|aarch64  (default: the host's, uname -m)
  --output PATH       Output .AppImage path         (default: build/appimage/...)
  --bundle DIR        Flutter release bundle dir   (default: build/linux/<a>/release/bundle)
  -h, --help          Show this help

Environment overrides: APP_NAME BIN_NAME APP_ID VERSION ARCH ICON DESKTOP_FILE
  PROJECT_DIR BUNDLE_DIR OUTPUT. Set APPIMAGE_ALLOW_UNPINNED=1 to download tools
  without a pinned checksum (prints the sha256 to pin).
EOF
}

PROJECT_DIR="${PROJECT_DIR:-$PROJECT_DIR_DEFAULT}"
# The build is native (see the header), so the host's architecture is the
# default target.
HOST_ARCH="$(host_arch)"
ARCH="${ARCH:-$HOST_ARCH}"
while [ $# -gt 0 ]; do
  case "$1" in
    --project-dir) PROJECT_DIR="$2"; shift 2 ;;
    --version)     VERSION="$2"; shift 2 ;;
    --arch)        ARCH="$2"; shift 2 ;;
    --output)      OUTPUT="$2"; shift 2 ;;
    --bundle)      BUNDLE_DIR="$2"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *) usage; die "unknown argument: $1" ;;
  esac
done
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

# Map arch → Flutter's bundle directory arch token.
case "$ARCH" in
  x86_64)  FLUTTER_ARCH="x64" ;;
  aarch64) FLUTTER_ARCH="arm64" ;;
  *) die "unsupported arch: $ARCH (want x86_64 or aarch64)" ;;
esac
# A mismatch would otherwise surface later as an opaque "Exec format error"
# from linuxdeploy, or as a missing bundle directory. Say what is actually
# wrong: this script has to run on the architecture it is packaging for.
[ "$ARCH" = "$HOST_ARCH" ] \
  || die "building for $ARCH on a $HOST_ARCH host: Flutter does not cross-compile Linux desktop bundles and the AppImage tools are native binaries, so run this script (and 'flutter build linux') on a $ARCH machine"

# ── Resolve config from the repo (each overridable by env) ───────────────────
read_cmake() { # var name → value from linux/CMakeLists.txt: set(NAME "value")
  sed -n "s/^set(${1} \"\\([^\"]*\\)\").*/\\1/p" "$PROJECT_DIR/linux/CMakeLists.txt" | head -n1
}
BIN_NAME="${BIN_NAME:-$(read_cmake BINARY_NAME)}"
APP_ID="${APP_ID:-$(read_cmake APPLICATION_ID)}"
# pubspec `version: 1.2.3+4` → strip the +build metadata for a clean file name.
VERSION="${VERSION:-$(sed -n 's/^version: *\([^ +]*\).*/\1/p' "$PROJECT_DIR/pubspec.yaml" | head -n1)}"
APP_NAME="${APP_NAME:-BrainFrame}"
# A 512x512 PNG: the master brainframe.png is 1024x1024, which exceeds the
# largest hicolor size linuxdeploy accepts (512x512), so packaging keeps its own
# 512 variant beside the .desktop file. Regenerate it from the master with
# tool/gen_packaging_icon.py. Override ICON with any square PNG whose size is a
# valid hicolor size.
ICON="${ICON:-$PROJECT_DIR/linux/packaging/brainframe-512.png}"
DESKTOP_FILE="${DESKTOP_FILE:-$PROJECT_DIR/linux/packaging/${APP_ID}.desktop}"
BUNDLE_DIR="${BUNDLE_DIR:-$PROJECT_DIR/build/linux/${FLUTTER_ARCH}/release/bundle}"

WORK_DIR="$PROJECT_DIR/build/appimage"
TOOLS_DIR="$WORK_DIR/tools"
APPDIR="$WORK_DIR/AppDir"
OUTPUT="${OUTPUT:-$WORK_DIR/${APP_NAME}-${VERSION}-${ARCH}.AppImage}"

[ -n "$BIN_NAME" ] || die "could not resolve BINARY_NAME from linux/CMakeLists.txt"
[ -n "$APP_ID" ]   || die "could not resolve APPLICATION_ID from linux/CMakeLists.txt"
[ -n "$VERSION" ]  || die "could not resolve version (pass --version or set VERSION)"

# ── Preconditions ────────────────────────────────────────────────────────────
[ -x "$BUNDLE_DIR/$BIN_NAME" ] || die "no release bundle at $BUNDLE_DIR — run 'flutter build linux --release' first"
[ -f "$ICON" ] || die "icon not found: $ICON"
[ -f "$DESKTOP_FILE" ] || die "desktop file not found: $DESKTOP_FILE"
for cmd in curl sha256sum patchelf file; do
  command -v "$cmd" >/dev/null 2>&1 || die "missing '$cmd' — install it (e.g. sudo apt install patchelf desktop-file-utils file)"
done

# Derive the icon's pixel size from the file itself and validate it against the
# hicolor sizes linuxdeploy accepts — the icon is installed under a directory
# named for that size, and a mismatch makes linuxdeploy fail.
ICON_SIZE="$(file -b "$ICON" | sed -n 's/.*, \([0-9]\+\) x \([0-9]\+\),.*/\1/p')"
case " 8 16 20 22 24 28 32 36 42 48 64 72 96 128 160 192 256 384 480 512 " in
  *" $ICON_SIZE "*) : ;;
  *) die "icon $ICON is ${ICON_SIZE}x?; use a square PNG of a valid hicolor size (…256, 384, 480, 512)" ;;
esac

log "==> AppImage build: $APP_NAME $VERSION ($ARCH)"
log "    bin=$BIN_NAME app_id=$APP_ID bundle=$BUNDLE_DIR icon=${ICON_SIZE}px"

# ── Fetch pinned tools ───────────────────────────────────────────────────────
# Host and target are the same architecture here (checked above).
mkdir -p "$TOOLS_DIR"
LINUXDEPLOY="$TOOLS_DIR/linuxdeploy-$ARCH.AppImage"
LINUXDEPLOY_GTK="$TOOLS_DIR/linuxdeploy-plugin-gtk.sh"
APPIMAGETOOL="$TOOLS_DIR/appimagetool-$ARCH.AppImage"
RUNTIME="$TOOLS_DIR/runtime-$ARCH"
fetch linuxdeploy     "$LINUXDEPLOY_URL"     "$LINUXDEPLOY"     "$ARCH"
fetch linuxdeploy-gtk "$LINUXDEPLOY_GTK_URL" "$LINUXDEPLOY_GTK" "$ARCH"
fetch appimagetool    "$APPIMAGETOOL_URL"    "$APPIMAGETOOL"    "$ARCH"
fetch runtime         "$RUNTIME_URL"         "$RUNTIME"         "$ARCH"
chmod +x "$LINUXDEPLOY" "$LINUXDEPLOY_GTK" "$APPIMAGETOOL"

# ── Assemble the AppDir ──────────────────────────────────────────────────────
# Flutter's binary expects its data/ and lib/ as *siblings* (rpath $ORIGIN/lib),
# so the whole bundle goes under usr/bin/. linuxdeploy then bundles system deps
# (GTK, glib, …) into usr/lib and patches rpaths; the LD_LIBRARY_PATH hook below
# keeps the engine libs in usr/bin/lib reachable regardless of that rewrite.
log "==> assembling AppDir"
rm -rf "$APPDIR"
ICON_DIR="$APPDIR/usr/share/icons/hicolor/${ICON_SIZE}x${ICON_SIZE}/apps"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/share/applications" "$ICON_DIR"
cp -a "$BUNDLE_DIR/$BIN_NAME" "$APPDIR/usr/bin/$BIN_NAME"
cp -a "$BUNDLE_DIR/data"      "$APPDIR/usr/bin/data"
cp -a "$BUNDLE_DIR/lib"       "$APPDIR/usr/bin/lib"
cp "$DESKTOP_FILE" "$APPDIR/usr/share/applications/${APP_ID}.desktop"
# Icon basename must match the .desktop `Icon=` key (Icon=brainframe).
cp "$ICON" "$ICON_DIR/${BIN_NAME}.png"

# AppRun hook, written BEFORE linuxdeploy runs — the order is the whole fix.
# linuxdeploy generates AppRun as a script that sources each hook present in
# apprun-hooks/ *at the moment it generates it*, by name; it does not glob the
# directory at run time. A hook added afterwards is carried in the AppImage and
# never sourced, which is exactly what happened: the binary's $ORIGIN/lib rpath
# was rewritten to $ORIGIN/../lib, the NEEDED plugin libs were copied to usr/lib
# by the dependency walk and kept working, and the libraries dart:ffi loads at
# run time by bare name — libsqlite3.so, libdartjni.so, anything a native asset
# ships — were left in usr/bin/lib on no search path. metadata.db could not be
# opened, the CRDT session came up null, and every engram opened as it did
# before the catalog existed. No error reached the user.
mkdir -p "$APPDIR/apprun-hooks"
cat > "$APPDIR/apprun-hooks/10-flutter-libs.sh" <<'HOOK'
# Flutter engine libs (libflutter_linux_gtk.so, libapp.so, plugin libs) and
# the native-asset libraries dart:ffi opens by name (libsqlite3.so) live next
# to the binary in usr/bin/lib; make sure the loader finds them.
export LD_LIBRARY_PATH="${APPDIR}/usr/bin/lib:${LD_LIBRARY_PATH:-}"
HOOK

# ── Bundle dependencies with linuxdeploy + the GTK plugin ────────────────────
log "==> linuxdeploy (+gtk) bundling dependencies"
export APPIMAGE_EXTRACT_AND_RUN=1   # never FUSE-mount the tools themselves
export DEPLOY_GTK_VERSION=3         # BrainFrame links gtk+-3.0
export ARCH                         # appimagetool/linuxdeploy read this
# linuxdeploy treats NO_STRIP as set-or-unset (any value, even empty, disables
# stripping), so only export it when the caller actually asked for it.
[ -n "${NO_STRIP:-}" ] && export NO_STRIP
"$LINUXDEPLOY" \
  --appdir "$APPDIR" \
  --executable "$APPDIR/usr/bin/$BIN_NAME" \
  --library "$APPDIR/usr/bin/lib/libflutter_linux_gtk.so" \
  --desktop-file "$APPDIR/usr/share/applications/${APP_ID}.desktop" \
  --icon-file "$ICON_DIR/${BIN_NAME}.png" \
  --plugin gtk >&2

# The hook above is only worth anything if AppRun sources it. Check, rather
# than trust the ordering: a linuxdeploy that changes how it generates AppRun
# would otherwise fail the same silent way again.
grep -q '10-flutter-libs.sh' "$APPDIR/AppRun" \
  || die "linuxdeploy's AppRun does not source apprun-hooks/10-flutter-libs.sh"

# ── Finalize with our pinned static runtime (the FUSE 2/3 fix) ────────────────
log "==> packaging with static runtime → $OUTPUT"
mkdir -p "$(dirname "$OUTPUT")"
rm -f "$OUTPUT"
# VERSION must be *exported*, not merely set: appimagetool reads it from the
# environment and injects `X-AppImage-Version` into the embedded .desktop entry.
# That key is how AppImage managers (AppImageLauncher, AppMan, Gear Lever…)
# report an installed app's version, and it is the only place the version
# survives — the file name is cosmetic and managers rename freely. Without the
# export the build still succeeds and the AppImage still runs, so nothing fails
# loudly; the app just shows up with no version at all.
export VERSION
"$APPIMAGETOOL" --runtime-file "$RUNTIME" "$APPDIR" "$OUTPUT" >&2

[ -f "$OUTPUT" ] || die "appimagetool did not produce $OUTPUT"
chmod +x "$OUTPUT"
log "==> done"
printf '%s\n' "$OUTPUT"   # the only stdout line: the artifact path
