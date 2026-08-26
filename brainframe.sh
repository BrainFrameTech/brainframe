#!/usr/bin/env bash
# Convenience wrapper for manual testing — not part of the app or its build.
# Runs the debug build on the committed fixture engram with an ephemeral
# config, so a session never reads or writes your real engrams or settings.
# Set BRAINFRAME_KEEP_CONFIG=1 for the cases that need the real saved config,
# or BRAINFRAME_WINDOW_SIZE=WxH for a different size. Any extra arguments are
# passed straight through to `flutter run`.
#
# This runs on your desktop session, which means the window's size in *recorded
# pixels* is not ours to choose: a Wayland compositor owns the scale factor, and
# GDK_SCALE and friends are X11-era knobs it ignores. At 1.5x scaling a
# 1600x1000 window is captured at 3200x2000, because GTK3 has no fractional
# scaling and the compositor rounds up to a buffer scale of 2.
#
# So do not use this for screenshots or recordings that need to match
# tool/appshot.sh. That tool runs the app on a private X server with no
# compositor, where 1600x1000 means 1600x1000 — use `appshot.sh drive` to work
# the app by hand there, and `appshot.sh record` to capture it.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$root"

window_size="${BRAINFRAME_WINDOW_SIZE:-1600x1000}"

# Absolute, because the app resolves --engram against its own working
# directory, which is not this one.
app_args=(--dart-entrypoint-args="--engram=$root/test/fixtures/engram")
app_args+=(--dart-entrypoint-args="--window-size=$window_size")
if [[ -z "${BRAINFRAME_KEEP_CONFIG:-}" ]]; then
  app_args+=(--dart-entrypoint-args=--ignore-config)
fi

exec flutter run -d linux "${app_args[@]}" "$@"
