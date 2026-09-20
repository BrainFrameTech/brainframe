#!/usr/bin/env bash
#
# common.sh — shared by the AppImage build scripts in this directory: logging,
# the pinned upstream tools with their checksums, and the verified download.
# Sourced, not run. Every pin lives here so there is one table to bump.
#
# See docs/appimage.md ("Bumping the pinned tools") for how to verify a new
# hash before pinning it.

log() { printf '%s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# ── Pinned tools ─────────────────────────────────────────────────────────────
# These tools ship only rolling `continuous` releases, so the *checksum* is the
# real pin: if upstream republishes, verification fails and we bump the hash
# deliberately. To bootstrap or refresh a pin, run once with
# APPIMAGE_ALLOW_UNPINNED=1 and copy the printed sha256 values here.
LINUXDEPLOY_URL="https://github.com/linuxdeploy/linuxdeploy/releases/download/continuous/linuxdeploy-%ARCH%.AppImage"
# The GTK plugin has no release assets; it lives as a raw script on master,
# pinned here to a commit for reproducibility (bump alongside its checksum).
LINUXDEPLOY_GTK_URL="https://raw.githubusercontent.com/linuxdeploy/linuxdeploy-plugin-gtk/7a3fbc31a9e5075073ff8790f26effbac5f84453/linuxdeploy-plugin-gtk.sh"
APPIMAGETOOL_URL="https://github.com/AppImage/appimagetool/releases/download/continuous/appimagetool-%ARCH%.AppImage"
RUNTIME_URL="https://github.com/AppImage/type2-runtime/releases/download/continuous/runtime-%ARCH%"

# sha256 pins (empty = unpinned; requires APPIMAGE_ALLOW_UNPINNED=1). Per-arch
# via an associative array keyed "<tool>:<arch>"; a tool that is the same bytes
# on every architecture (the GTK plugin is a shell script) is keyed "<tool>:any".
# linuxdeploy and appimagetool run on the *build host*; the runtime is embedded
# in the result and is pinned for every *target*, which is why it alone has an
# armhf row.
declare -A SHA256=(
  [linuxdeploy:x86_64]="36a2d7e274d12e1050d0e9ecfe11d339ed54720b2bec464c286d53f8b07f5c62"
  [linuxdeploy:aarch64]="556ab80baa98e600aa80f0dcedfb70bca0e1ce7e9f147fb345be3fcc3e91b2b1"
  [linuxdeploy-gtk:any]="b0f4cbc684a0103a9651f0955b635eaea0096b3a66c0f5a2c2aa337960375171"
  [appimagetool:x86_64]="a6d71e2b6cd66f8e8d16c37ad164658985e0cf5fcaa950c90a482890cb9d13e0"
  [appimagetool:aarch64]="1b00524ba8c6b678dc15ef88a5c25ec24def36cdfc7e3abb32ddcd068e8007fe"
  [runtime:x86_64]="1cc49bcf1e2ccd593c379adb17c9f85a36d619088296504de95b1d06215aebbf"
  [runtime:aarch64]="7d5d772b7c32f0c84caf0a452a3072a5709027d7eac5856feb89a7a7a8881372"
  [runtime:armhf]="6b4bc2d4f9b027f5389fbd180abf5c29ea84dd59d1e80c8e8087d2258f6ab9c8"
)

# The host architecture in AppImage spelling. `arm64` is what some kernels and
# Docker call aarch64.
host_arch() {
  local a; a="$(uname -m)"
  [ "$a" = arm64 ] && a=aarch64
  printf '%s\n' "$a"
}

# fetch KEY URL DEST ARCH — download DEST from URL (with %ARCH% substituted)
# unless a copy that already verifies is present, then verify it against the
# pin for KEY:ARCH (falling back to KEY:any). ARCH is passed explicitly rather
# than read from a global because one build may fetch tools for the host and a
# runtime for a different target.
fetch() {
  local key="$1" url="$2" dest="$3" arch="$4"
  local expected="${SHA256[$key:$arch]:-${SHA256[$key:any]:-}}"
  url="${url//%ARCH%/$arch}"
  if [ -f "$dest" ] && [ -n "$expected" ] && echo "$expected  $dest" | sha256sum -c - >/dev/null 2>&1; then
    log "    cached $(basename "$dest")"
  else
    log "    downloading $(basename "$dest")"
    curl -fSL --retry 3 -o "$dest.part" "$url" || die "download failed: $url"
    mv "$dest.part" "$dest"
  fi
  local actual; actual="$(sha256sum "$dest" | cut -d' ' -f1)"
  if [ -n "$expected" ]; then
    [ "$actual" = "$expected" ] || die "checksum mismatch for $(basename "$dest"): got $actual, pinned $expected"
  elif [ "${APPIMAGE_ALLOW_UNPINNED:-0}" = 1 ]; then
    log "    UNPINNED $(basename "$dest") sha256=$actual  (pin this in SHA256[])"
  else
    die "no pinned checksum for $key:$arch — set APPIMAGE_ALLOW_UNPINNED=1 to bootstrap, then pin the printed sha256"
  fi
}
