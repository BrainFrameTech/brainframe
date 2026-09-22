#!/usr/bin/env bash
#
# build-flutterpi-appimage.sh — build an AppImage that runs BrainFrame on a
# Raspberry Pi with *no desktop environment*, through flutter-pi.
#
# flutter-pi is the embedder for exactly that case: it opens the display
# through DRM/KMS and reads input through libinput, so nothing X11, Wayland or
# GTK is involved. The desktop AppImage (build-appimage.sh) cannot do this —
# its embedder is GTK and needs a compositor.
#
# Input is a flutterpi_tool bundle; this script packages it, it does not build
# it. flutterpi_tool cross-compiles from any host and puts the whole runnable
# tree — the flutter-pi binary, libflutter_engine.so, the AOT snapshot, the
# assets, and the native-asset libraries (libsqlite3.so) — under
# build/flutter-pi/<target>:
#
#   flutter pub global activate flutterpi_tool   # flutter, not dart: needs the SDK
#   flutterpi_tool build --arch=arm64 --cpu=pi3 --release
#   tool/appimage/build-flutterpi-appimage.sh --arch arm64 --cpu pi3
#
# The output goes to build/appimage/ and its path is the only line on stdout.
#
# ── Why this builds on any host, unlike the desktop AppImage ─────────────────
# No linuxdeploy. The libraries flutter-pi links fall into two groups, and
# neither is bundled:
#   * The Mesa stack (libEGL, libGLESv2, libgbm, libdrm) must be the target's
#     own: libgbm and libEGL dlopen the DRI driver of the GPU they run on
#     (vc4/v3d on a Pi), and a bundled copy from another machine would not
#     match it. linuxdeploy refuses to bundle these for the same reason.
#   * The rest (libinput, libudev, libxkbcommon, libsystemd, glib, the
#     GStreamer core) are ordinary distro packages, listed in docs/appimage.md,
#     and present on a Pi that already runs flutter-pi.
# With nothing to bundle, the only native tool left is appimagetool, which
# only packs a squashfs and takes the target architecture from $ARCH — so an
# x86_64 desktop builds the aarch64 AppImage. The embedded static runtime is
# fetched for the *target*, appimagetool for the *host*.
#
# See docs/appimage.md ("Raspberry Pi without a desktop") for the rest.

set -euo pipefail

# ── Locate the project ───────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR_DEFAULT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# Logging, the pinned tools with their checksums, and the verified fetch().
. "$SCRIPT_DIR/common.sh"

usage() {
  cat >&2 <<EOF
Usage: build-flutterpi-appimage.sh [options]

Packages a flutterpi_tool bundle as an AppImage for a Raspberry Pi with no
desktop environment. Build the bundle first:

  flutterpi_tool build --arch=<arch> --cpu=<cpu> --release

Options (all also settable via the matching UPPER_CASE env var):
  --arch ARCH         flutterpi_tool --arch: arm64|arm|x64      (default: arm64)
  --cpu CPU           flutterpi_tool --cpu: generic|pi3|pi4|pi5 (default: pi3)
  --bundle DIR        flutterpi_tool output dir (default: build/flutter-pi/<target>)
  --project-dir DIR   Flutter project root      (default: repo of this script)
  --version VER       Version string in the name (default: pubspec version)
  --output PATH       Output .AppImage path      (default: build/appimage/...)
  -h, --help          Show this help

Environment overrides: APP_NAME BIN_NAME APP_ID VERSION ARCH CPU ICON
  DESKTOP_FILE PROJECT_DIR BUNDLE_DIR OUTPUT. Set APPIMAGE_ALLOW_UNPINNED=1 to
  download tools without a pinned checksum (prints the sha256 to pin).
EOF
}

PROJECT_DIR="${PROJECT_DIR:-$PROJECT_DIR_DEFAULT}"
ARCH="${ARCH:-arm64}"
CPU="${CPU:-pi3}"
while [ $# -gt 0 ]; do
  case "$1" in
    --project-dir) PROJECT_DIR="$2"; shift 2 ;;
    --version)     VERSION="$2"; shift 2 ;;
    --arch)        ARCH="$2"; shift 2 ;;
    --cpu)         CPU="$2"; shift 2 ;;
    --bundle)      BUNDLE_DIR="$2"; shift 2 ;;
    --output)      OUTPUT="$2"; shift 2 ;;
    -h|--help)     usage; exit 0 ;;
    *) usage; die "unknown argument: $1" ;;
  esac
done
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

# ── Map the flutterpi_tool target ────────────────────────────────────────────
# flutterpi_tool names its output directory after the (arch, cpu) pair — the
# table is FlutterpiTargetPlatform in its lib/src/common.dart — and the
# AppImage runtime uses the AppImage spelling of the architecture.
case "$ARCH" in
  arm64) APPIMAGE_ARCH="aarch64"; GENERIC_TARGET="aarch64-generic" ;;
  arm)   APPIMAGE_ARCH="armhf";   GENERIC_TARGET="armv7-generic" ;;
  x64)   APPIMAGE_ARCH="x86_64";  GENERIC_TARGET="x64-generic" ;;
  *) die "unsupported arch: $ARCH (flutterpi_tool spelling: arm64, arm or x64)" ;;
esac
case "$ARCH:$CPU" in
  *:generic)                        TARGET="$GENERIC_TARGET" ;;
  arm64:pi3|arm64:pi4|arm64:pi5)    TARGET="${CPU}-64" ;;
  arm:pi3|arm:pi4)                  TARGET="$CPU" ;;
  *) die "flutterpi_tool has no --cpu=$CPU engine for --arch=$ARCH" ;;
esac

# ── Resolve config from the repo (each overridable by env) ───────────────────
read_cmake() { # var name → value from linux/CMakeLists.txt: set(NAME "value")
  sed -n "s/^set(${1} \"\\([^\"]*\\)\").*/\\1/p" "$PROJECT_DIR/linux/CMakeLists.txt" | head -n1
}
BIN_NAME="${BIN_NAME:-$(read_cmake BINARY_NAME)}"
APP_ID="${APP_ID:-$(read_cmake APPLICATION_ID)}"
# pubspec `version: 1.2.3+4` → strip the +build metadata for a clean file name.
VERSION="${VERSION:-$(sed -n 's/^version: *\([^ +]*\).*/\1/p' "$PROJECT_DIR/pubspec.yaml" | head -n1)}"
APP_NAME="${APP_NAME:-BrainFrame}"
ICON="${ICON:-$PROJECT_DIR/web/icons/Icon-512.png}"
DESKTOP_FILE="${DESKTOP_FILE:-$PROJECT_DIR/linux/packaging/${APP_ID}.desktop}"
BUNDLE_DIR="${BUNDLE_DIR:-$PROJECT_DIR/build/flutter-pi/$TARGET}"

WORK_DIR="$PROJECT_DIR/build/appimage"
TOOLS_DIR="$WORK_DIR/tools"      # shared with build-appimage.sh: same pins, same names
APPDIR="$WORK_DIR/AppDir-flutterpi"
# The target name in the file name says which engine tuning is inside: an
# engine tuned for one CPU is not expected to run on another.
OUTPUT="${OUTPUT:-$WORK_DIR/${APP_NAME}-${VERSION}-flutterpi-${TARGET}.AppImage}"

[ -n "$BIN_NAME" ] || die "could not resolve BINARY_NAME from linux/CMakeLists.txt"
[ -n "$APP_ID" ]   || die "could not resolve APPLICATION_ID from linux/CMakeLists.txt"
[ -n "$VERSION" ]  || die "could not resolve version (pass --version or set VERSION)"

# ── Preconditions ────────────────────────────────────────────────────────────
[ -d "$BUNDLE_DIR" ] \
  || die "no flutterpi_tool bundle at $BUNDLE_DIR — run 'flutterpi_tool build --arch=$ARCH --cpu=$CPU --release' first"
[ -x "$BUNDLE_DIR/flutter-pi" ] \
  || die "$BUNDLE_DIR has no flutter-pi binary; flutterpi_tool ≥ 0.12 puts one in the bundle"
[ -f "$BUNDLE_DIR/libflutter_engine.so" ] || die "$BUNDLE_DIR has no libflutter_engine.so"
# app.so is the AOT snapshot: only --release and --profile bundles have one.
# A debug bundle (kernel_blob.bin) needs the debug engine and a JIT start-up
# a Pi 3 is too slow for; refuse rather than ship it.
[ -f "$BUNDLE_DIR/app.so" ] \
  || die "$BUNDLE_DIR is a debug bundle (no app.so); rebuild with 'flutterpi_tool build --release'"
[ -f "$ICON" ] || die "icon not found: $ICON"
[ -f "$DESKTOP_FILE" ] || die "desktop file not found: $DESKTOP_FILE"
for cmd in curl sha256sum file; do
  command -v "$cmd" >/dev/null 2>&1 || die "missing '$cmd' — install it (e.g. sudo apt install curl file)"
done

# The bundle's own binaries prove the target architecture; a mismatch means
# the wrong flutterpi_tool build is being packaged.
case "$(file -b "$BUNDLE_DIR/flutter-pi")" in
  *"ARM aarch64"*) BUNDLE_ARCH=arm64 ;;
  *"ARM,"*|*"ARM EABI"*) BUNDLE_ARCH=arm ;;
  *"x86-64"*) BUNDLE_ARCH=x64 ;;
  *) BUNDLE_ARCH=unknown ;;
esac
[ "$BUNDLE_ARCH" = "$ARCH" ] \
  || die "$BUNDLE_DIR/flutter-pi is a $BUNDLE_ARCH binary, but --arch is $ARCH"

# The bundle also tells us whether the native-asset step ran: the sqlite3
# package ships libsqlite3.so this way, and without it every engram opens
# with no metadata.db and no error (see docs/appimage.md). Refuse to package
# a bundle that would fail that silently.
[ -f "$BUNDLE_DIR/NativeAssetsManifest.json" ] && grep -q libsqlite3 "$BUNDLE_DIR/NativeAssetsManifest.json" \
  || die "$BUNDLE_DIR/NativeAssetsManifest.json does not list libsqlite3.so — the native-asset build did not run (flutterpi_tool ≥ 0.12 is required)"

ICON_SIZE="$(file -b "$ICON" | sed -n 's/.*, \([0-9]\+\) x \([0-9]\+\),.*/\1/p')"
[ -n "$ICON_SIZE" ] || die "could not read the pixel size of $ICON"

HOST_ARCH="$(host_arch)"
log "==> flutter-pi AppImage build: $APP_NAME $VERSION (target $TARGET → $APPIMAGE_ARCH, host $HOST_ARCH)"
log "    bundle=$BUNDLE_DIR"

# ── Fetch pinned tools ───────────────────────────────────────────────────────
# appimagetool runs here, so it is fetched for the host; the runtime is
# embedded in the result, so it is fetched for the target.
mkdir -p "$TOOLS_DIR"
APPIMAGETOOL="$TOOLS_DIR/appimagetool-$HOST_ARCH.AppImage"
RUNTIME="$TOOLS_DIR/runtime-$APPIMAGE_ARCH"
fetch appimagetool "$APPIMAGETOOL_URL" "$APPIMAGETOOL" "$HOST_ARCH"
fetch runtime      "$RUNTIME_URL"      "$RUNTIME"      "$APPIMAGE_ARCH"
chmod +x "$APPIMAGETOOL"

# ── Assemble the AppDir ──────────────────────────────────────────────────────
# The flutterpi_tool bundle is copied whole and untouched under usr/lib: the
# flutter-pi binary looks for libflutter_engine.so beside the assets it is
# handed, and the launcher runs flutter-pi from inside the same directory for
# the native-asset libraries dart:ffi opens by a "./" path (see the launcher
# for why the manifest's "relative" entry ends up working-directory-relative
# under an embedder-API host). Moving any piece breaks one of those lookups.
log "==> assembling AppDir"
rm -rf "$APPDIR"
LIB_DIR="$APPDIR/usr/lib/$BIN_NAME"
ICON_DIR="$APPDIR/usr/share/icons/hicolor/${ICON_SIZE}x${ICON_SIZE}/apps"
mkdir -p "$APPDIR/usr/bin" "$APPDIR/usr/lib" "$APPDIR/usr/share/applications" "$ICON_DIR"
cp -a "$BUNDLE_DIR" "$LIB_DIR"
# Hidden build bookkeeping from flutterpi_tool has no business in the image.
rm -f "$LIB_DIR/.last_build_id"

# The launcher (flutterpi-launcher.sh) and the console guard it starts the app
# under (flutterpi-console-guard.py) ship from this directory. The .desktop
# file's Exec= names the binary, so the launcher lives at usr/bin/<bin> and
# derives the bundle location from that; AppRun is a symlink to it — one
# script, two names. The guard sits beside it under the name the launcher
# looks for.
install -m 0755 "$SCRIPT_DIR/flutterpi-launcher.sh" "$APPDIR/usr/bin/$BIN_NAME"
install -m 0755 "$SCRIPT_DIR/flutterpi-console-guard.py" \
  "$APPDIR/usr/bin/${BIN_NAME}-console-guard"
ln -s "usr/bin/$BIN_NAME" "$APPDIR/AppRun"

# Desktop entry and icon: appimagetool wants both at the AppDir root, with the
# icon named as the entry's Icon= key (Icon=brainframe).
cp "$DESKTOP_FILE" "$APPDIR/usr/share/applications/${APP_ID}.desktop"
ln -s "usr/share/applications/${APP_ID}.desktop" "$APPDIR/${APP_ID}.desktop"
cp "$ICON" "$ICON_DIR/${BIN_NAME}.png"
ln -s "usr/share/icons/hicolor/${ICON_SIZE}x${ICON_SIZE}/apps/${BIN_NAME}.png" "$APPDIR/${BIN_NAME}.png"
ln -s "${BIN_NAME}.png" "$APPDIR/.DirIcon"

# ── Package with the target's static runtime ─────────────────────────────────
log "==> packaging with static $APPIMAGE_ARCH runtime → $OUTPUT"
mkdir -p "$(dirname "$OUTPUT")"
rm -f "$OUTPUT"
export APPIMAGE_EXTRACT_AND_RUN=1   # never FUSE-mount appimagetool itself
# ARCH tells appimagetool what it is packaging for, since it cannot run the
# target's binaries to find out; VERSION becomes X-AppImage-Version in the
# embedded .desktop entry (see build-appimage.sh for why that export matters).
export ARCH="$APPIMAGE_ARCH"
export VERSION
"$APPIMAGETOOL" --runtime-file "$RUNTIME" "$APPDIR" "$OUTPUT" >&2

[ -f "$OUTPUT" ] || die "appimagetool did not produce $OUTPUT"
chmod +x "$OUTPUT"
log "==> done"
printf '%s\n' "$OUTPUT"   # the only stdout line: the artifact path
