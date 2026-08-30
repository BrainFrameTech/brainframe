#!/usr/bin/env bash
# Convenience wrapper for manual testing — not part of the app or its build.
# Runs the debug build on the committed fixture engram with an ephemeral
# config, so a session never reads or writes your real engrams or settings.
# Geometry and pixel scale match tool/appshot.sh, so a screen recording lines
# up with the screenshots the visual-verification tool takes.
# Set BRAINFRAME_KEEP_CONFIG=1 for the cases that need the real saved config,
# or BRAINFRAME_WINDOW_SIZE=WxH for a different size. Any extra arguments are
# passed straight through to `flutter run`.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$root"

# Keep in step with APPSHOT_WIN_W/H in tool/appshot.sh — the point of pinning
# the size here is that the two agree.
window_size="${BRAINFRAME_WINDOW_SIZE:-1600x1000}"

# Absolute, because the app resolves --engram against its own working
# directory, which is not this one.
app_args=(--dart-entrypoint-args="--engram=$root/test/fixtures/engram")
app_args+=(--dart-entrypoint-args="--window-size=$window_size")
if [[ -z "${BRAINFRAME_KEEP_CONFIG:-}" ]]; then
  app_args+=(--dart-entrypoint-args=--ignore-config)
fi

# GDK_SCALE/GDK_DPI_SCALE pin the device pixel ratio to 1, as appshot does, so
# the window's logical size is also its size in recorded pixels. Without this a
# HiDPI desktop records the same window at a different resolution.
exec env GDK_SCALE=1 GDK_DPI_SCALE=1 flutter run -d linux "${app_args[@]}" "$@"
