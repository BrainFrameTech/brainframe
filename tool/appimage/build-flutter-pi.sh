#!/usr/bin/env bash
#
# build-flutter-pi.sh — cross-build a patched flutter-pi for the Pi, here.
#
# flutterpi_tool downloads a prebuilt flutter-pi from upstream's releases. That
# binary corrupts every text field on the device: its JSON parser never decodes
# string escapes, so a newline arriving from the engine becomes a literal
# backslash and an 'n', the encoder escapes that backslash on the way back, and
# each round trip doubles it — until the editing-state buffer is full. The
# caret drifts by one per newline while it happens. See docs/appimage.md
# ("The text-input corruption") and patches/ for the fix.
#
# So we build our own. Everything happens on the development machine and needs
# no root: the compiler is clang (already required for Flutter's Linux
# toolchain), the aarch64 assembler and linker come from a binutils package
# unpacked into a scratch directory, and the target headers and libraries come
# from Debian .debs unpacked into a sysroot. Building against Debian's own
# packages rather than the host's is the point — the binary then asks for the
# glibc and SONAMEs Raspberry Pi OS actually has.
#
#   tool/appimage/build-flutter-pi.sh            # → build/flutter-pi-patched/pi3-64/flutter-pi
#   tool/appimage/build-flutterpi-appimage.sh    # picks it up automatically
#
# Roughly 250 MB of downloads, cached under build/flutter-pi-patched/cache, and
# a minute of compiling. Re-running with everything cached rebuilds only the
# source.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR_DEFAULT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/common.sh"

usage() {
  cat >&2 <<EOF
Usage: build-flutter-pi.sh [options]

Cross-builds a patched flutter-pi. Prints the binary's path on stdout.

Options (all also settable via the matching UPPER_CASE env var):
  --arch ARCH         arm64|arm|x64                 (default: arm64)
  --cpu CPU           generic|pi3|pi4|pi5           (default: pi3)
  --suite SUITE       Debian suite for the sysroot  (default: trixie)
  --project-dir DIR   Repo root                     (default: repo of this script)
  --clean             Discard the work tree and sysroot first
  -h, --help          Show this help

The target names only the output directory and the Debian architecture; the
binary itself is not CPU-tuned (flutter-pi is a thin embedder — the tuning
that matters is the engine's, which flutterpi_tool still supplies).
EOF
}

PROJECT_DIR="${PROJECT_DIR:-$PROJECT_DIR_DEFAULT}"
ARCH="${ARCH:-arm64}"
CPU="${CPU:-pi3}"
SUITE="${SUITE:-trixie}"
CLEAN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --arch)        ARCH="$2"; shift 2 ;;
    --cpu)         CPU="$2"; shift 2 ;;
    --suite)       SUITE="$2"; shift 2 ;;
    --project-dir) PROJECT_DIR="$2"; shift 2 ;;
    --clean)       CLEAN=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *) usage; die "unknown argument: $1" ;;
  esac
done
PROJECT_DIR="$(cd "$PROJECT_DIR" && pwd)"

# The upstream tag to build. flutterpi_tool pins the flutter-pi release it
# downloads, and its stamp names it: keep these together, or the binary we
# ship and the engine it runs diverge. Check with
#   cat "$(dirname "$(dirname "$(readlink -f "$(command -v flutter)")")")/bin/cache/flutter-pi.stamp"
FLUTTER_PI_TAG="${FLUTTER_PI_TAG:-release/1.1.1}"
FLUTTER_PI_REPO="${FLUTTER_PI_REPO:-https://github.com/ardera/flutter-pi.git}"

case "$ARCH" in
  arm64) DEB_ARCH=arm64; TRIPLE=aarch64-linux-gnu ;;
  arm)   DEB_ARCH=armhf; TRIPLE=arm-linux-gnueabihf ;;
  x64)   DEB_ARCH=amd64; TRIPLE=x86_64-linux-gnu ;;
  *) die "unsupported arch: $ARCH (arm64, arm or x64)" ;;
esac
case "$ARCH:$CPU" in
  *:generic)                     TARGET="$(case "$ARCH" in arm64) echo aarch64-generic ;; arm) echo armv7-generic ;; *) echo x64-generic ;; esac)" ;;
  arm64:pi3|arm64:pi4|arm64:pi5) TARGET="${CPU}-64" ;;
  arm:pi3|arm:pi4)               TARGET="$CPU" ;;
  *) die "no --cpu=$CPU target for --arch=$ARCH" ;;
esac

WORK="$PROJECT_DIR/build/flutter-pi-patched"
CACHE="$WORK/cache"
SYSROOT="$WORK/sysroot-$DEB_ARCH"
XTOOL="$WORK/binutils-$DEB_ARCH"
SRC="$WORK/src"
OUT_DIR="$WORK/$TARGET"
MIRROR="${DEBIAN_MIRROR:-https://deb.debian.org/debian}"

[ "$CLEAN" = 1 ] && rm -rf "$SRC" "$SYSROOT" "$XTOOL" "$OUT_DIR"
mkdir -p "$CACHE" "$OUT_DIR"

for cmd in clang cmake ninja curl dpkg-deb python3 file; do
  command -v "$cmd" >/dev/null 2>&1 \
    || die "missing '$cmd' — install it (clang, cmake and ninja come with the Flutter Linux toolchain)"
done
command -v apt-get >/dev/null 2>&1 \
  || die "this script fetches its cross-binutils with 'apt-get download'; on a non-Debian host, supply them yourself and set XTOOL_BIN"

log "==> patched flutter-pi: $FLUTTER_PI_TAG for $TARGET ($DEB_ARCH)"

# ── The assembler and linker ─────────────────────────────────────────────────
# clang is a cross-compiler already; it only lacks a target assembler and
# linker. `apt-get download` needs no root, and the package unpacks into a
# scratch directory — nothing is installed on the host.
if [ ! -x "$XTOOL/usr/bin/$TRIPLE-ld" ]; then
  log "    fetching binutils-$TRIPLE"
  ( cd "$CACHE" && apt-get download "binutils-$TRIPLE" >/dev/null 2>&1 ) \
    || die "could not download binutils-$TRIPLE — is it in your apt sources?"
  mkdir -p "$XTOOL"
  dpkg-deb -x "$CACHE/binutils-$TRIPLE"_*.deb "$XTOOL"
fi
# Its libbfd/libopcodes ship in the same package, under the host triple.
export LD_LIBRARY_PATH="$XTOOL/usr/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

# ── The sysroot ──────────────────────────────────────────────────────────────
# Headers and libraries for the target, from Debian, so the result matches
# Raspberry Pi OS rather than this machine.
SYSROOT_PKGS="
libc6 libc6-dev linux-libc-dev libgcc-s1 gcc-14-base libgcc-14-dev
libcrypt1 libcrypt-dev
libdrm2 libdrm-dev libgbm1 libgbm-dev
libsystemd0 libsystemd-dev
libinput10 libinput-dev libevdev2 libevdev-dev libmtdev1t64 libmtdev-dev
libwacom9 libwacom-dev libgudev-1.0-0 libgudev-1.0-dev
libxkbcommon0 libxkbcommon-dev libudev1 libudev-dev
libegl1 libegl-dev libgles2 libgles-dev libgl1 libgl-dev libglx0 libglx-dev
libglvnd0 libglvnd-core-dev libglvnd-dev libopengl0 mesa-common-dev
libglib2.0-0t64 libglib2.0-dev libffi8 libffi-dev
libpcre2-8-0 libpcre2-dev zlib1g zlib1g-dev
libcap2 libcap-dev liblzma5 liblzma-dev libzstd1 libzstd-dev
libgcrypt20 libgcrypt20-dev libgpg-error0 libgpg-error-dev
libselinux1 libselinux1-dev libsepol2 libsepol-dev
libmount1 libmount-dev libblkid1 libblkid-dev libuuid1 uuid-dev
libxml2 libxml2-dev libicu76
"
if [ ! -d "$SYSROOT/usr/include" ]; then
  log "    building $SUITE/$DEB_ARCH sysroot"
  IDX="$CACHE/Packages-$SUITE-$DEB_ARCH"
  [ -s "$IDX" ] || curl -fsSL "$MIRROR/dists/$SUITE/main/binary-$DEB_ARCH/Packages.xz" | xz -dc > "$IDX"

  python3 - "$IDX" $SYSROOT_PKGS > "$CACHE/urls-$DEB_ARCH.txt" <<'PY'
import sys
want = set(sys.argv[2:])
found, name = {}, None
with open(sys.argv[1], encoding='utf-8', errors='replace') as f:
    for line in f:
        if line.startswith('Package: '):
            name = line[9:].strip()
        elif line.startswith('Filename: ') and name in want and name not in found:
            found[name] = line[10:].strip()
missing = want - set(found)
if missing:
    print('note: not in the index (may have been renamed): '
          + ' '.join(sorted(missing)), file=sys.stderr)
for path in sorted(found.values()):
    print(path)
PY

  mkdir -p "$SYSROOT"
  while read -r path; do
    deb="$CACHE/$(basename "$path")"
    [ -s "$deb" ] || curl -fsSL "$MIRROR/$path" -o "$deb"
    dpkg-deb -x "$deb" "$SYSROOT"
  done < "$CACHE/urls-$DEB_ARCH.txt"

  # Debian is merged-/usr; dpkg-deb does not create the compatibility symlinks,
  # and the linker follows absolute paths out of libc.so's linker script.
  ln -sfn usr/lib "$SYSROOT/lib"
  ln -sfn usr/bin "$SYSROOT/bin"
fi

GCC_DIR="$(echo "$SYSROOT"/usr/lib/gcc/"$TRIPLE"/* | tr ' ' '\n' | tail -1)"
[ -f "$GCC_DIR/crtbeginS.o" ] || die "no crtbeginS.o under $GCC_DIR — the sysroot is missing libgcc-*-dev"

# ── The source, patched ──────────────────────────────────────────────────────
if [ ! -d "$SRC/.git" ]; then
  log "    cloning flutter-pi $FLUTTER_PI_TAG"
  rm -rf "$SRC"
  git clone -q --depth 1 --branch "$FLUTTER_PI_TAG" "$FLUTTER_PI_REPO" "$SRC"
fi
log "    applying patches"
git -C "$SRC" checkout -q -- .
for patch in "$SCRIPT_DIR"/patches/*.patch; do
  [ -e "$patch" ] || continue
  git -C "$SRC" apply "$patch" || die "patch did not apply: $patch (did FLUTTER_PI_TAG move?)"
  log "      $(basename "$patch")"
done

# ── Build ────────────────────────────────────────────────────────────────────
# GStreamer, Vulkan and libseat are off: BrainFrame uses none of them, and
# every one left on is a package the Pi would have to carry.
TOOLCHAIN="$WORK/toolchain-$DEB_ARCH.cmake"
cat > "$TOOLCHAIN" <<EOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR $(case "$ARCH" in arm64) echo aarch64 ;; arm) echo arm ;; *) echo x86_64 ;; esac))
set(CMAKE_C_COMPILER clang)
set(CMAKE_C_COMPILER_TARGET $TRIPLE)
set(CMAKE_CXX_COMPILER clang++)
set(CMAKE_CXX_COMPILER_TARGET $TRIPLE)
set(CMAKE_SYSROOT "$SYSROOT")
set(CMAKE_AR "$XTOOL/usr/bin/$TRIPLE-ar" CACHE FILEPATH "" FORCE)
set(CMAKE_RANLIB "$XTOOL/usr/bin/$TRIPLE-ranlib" CACHE FILEPATH "" FORCE)
set(_XFLAGS "-B$XTOOL/usr/bin -fuse-ld=$XTOOL/usr/bin/$TRIPLE-ld --gcc-install-dir=$GCC_DIR")
set(CMAKE_C_FLAGS_INIT "\${_XFLAGS}")
set(CMAKE_CXX_FLAGS_INIT "\${_XFLAGS}")
set(CMAKE_EXE_LINKER_FLAGS_INIT "\${_XFLAGS}")
set(CMAKE_FIND_ROOT_PATH "$SYSROOT")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF

export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/$TRIPLE/pkgconfig:$SYSROOT/usr/share/pkgconfig"
export PKG_CONFIG_PATH=""

log "    configuring"
cmake -S "$SRC" -B "$SRC/build" -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_GSTREAMER_VIDEO_PLAYER_PLUGIN=OFF \
  -DBUILD_GSTREAMER_AUDIO_PLAYER_PLUGIN=OFF \
  -DENABLE_SESSION_SWITCHING=OFF \
  -DENABLE_VULKAN=OFF \
  -DLTO=OFF >/dev/null

log "    compiling"
ninja -C "$SRC/build" flutter-pi >/dev/null

install -m 0755 "$SRC/build/flutter-pi" "$OUT_DIR/flutter-pi"

# It has to be the right machine, and it must not ask for a newer glibc than
# the Pi has. Both are silent failures on the device otherwise.
case "$(file -b "$OUT_DIR/flutter-pi")" in
  *"ARM aarch64"*) BUILT=arm64 ;;
  *"ARM,"*|*"ARM EABI"*) BUILT=arm ;;
  *"x86-64"*) BUILT=x64 ;;
  *) BUILT=unknown ;;
esac
[ "$BUILT" = "$ARCH" ] || die "built a $BUILT binary but asked for $ARCH"
log "    glibc floor: $(strings "$OUT_DIR/flutter-pi" | grep -o 'GLIBC_[0-9.]*' | sort -uV | tail -1)"
log "==> done"
printf '%s\n' "$OUT_DIR/flutter-pi"
