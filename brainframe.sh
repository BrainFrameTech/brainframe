#!/usr/bin/env bash
# Convenience wrapper for manual testing — not part of the app or its build.
# Runs the debug build on the committed fixture engram with an ephemeral
# config, so a session never reads or writes your real engrams or settings.
# Set BRAINFRAME_KEEP_CONFIG=1 for the cases that need the real saved config.
# Any extra arguments are passed straight through to `flutter run`.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$root"

# Absolute, because the app resolves --engram against its own working
# directory, which is not this one.
app_args=(--dart-entrypoint-args="--engram=$root/test/fixtures/engram")
if [[ -z "${BRAINFRAME_KEEP_CONFIG:-}" ]]; then
  app_args+=(--dart-entrypoint-args=--ignore-config)
fi

exec flutter run -d linux "${app_args[@]}" "$@"
