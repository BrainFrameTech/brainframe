#!/bin/sh
# BrainFrame on flutter-pi: no desktop environment, the app draws straight to
# the display through DRM/KMS. Run it from a login on the console (not from
# inside X11 or Wayland) as a user in the video, render and input groups.
#
# Installed as usr/bin/<bin> with AppRun symlinked to it, so the binary name
# and the bundle location are derived from where this script sits:
# usr/bin/<bin> runs usr/lib/<bin>/flutter-pi on usr/lib/<bin>.
#
# Arguments before a literal `--` are flutter-pi's own options, e.g.
#   -r 90                  rotate the UI
#   --videomode 1280x720   pick an output mode
#   -d "155,86"            display size in mm, if the panel misreports it
# Arguments after `--` follow the bundle path, where flutter-pi hands them to
# the ENGINE as switches (e.g. --old-gen-heap-size=128). They never reach the
# app: flutter-pi passes nothing to the Dart entrypoint. The app's own options
# (--engram, --trace-scan, ...) go in the BRAINFRAME_ARGS environment
# variable instead, whitespace-separated:
#   BRAINFRAME_ARGS="--trace-scan --engram /home/pi/notes" ./BrainFrame.AppImage
# With no `--`, every argument is a flutter-pi option. A file path in
# BRAINFRAME_ARGS must be absolute: flutter-pi runs with the bundle as its
# working directory (see below), so a relative path would resolve inside the
# read-only image.
#
# FLUTTER_PI=/path/to/flutter-pi runs a flutter-pi of your own (say, one built
# without GStreamer) against the bundled engine and app instead of the
# flutter-pi that flutterpi_tool put in the bundle.
#
# While the app runs, the console's keyboard is turned off (see
# <bin>-console-guard next to this script) so that what is typed into the app
# does not also land on the console's shell or login prompt.
# BRAINFRAME_CONSOLE_GUARD=0 skips that, for debugging the guard itself.
set -e
SELF="$(readlink -f "$0")"
HERE="$(cd "$(dirname "$SELF")" && pwd)"
NAME="$(basename "$SELF")"
BUNDLE="$(cd "$HERE/../lib/$NAME" && pwd)"
GUARD="$HERE/$NAME-console-guard"
FLUTTER_PI="${FLUTTER_PI:-$BUNDLE/flutter-pi}"

# Where dart:ffi finds the native-asset libraries (libsqlite3.so). The
# manifest lists ["relative", "./libsqlite3.so"], and the engine resolves
# `relative` against the isolate's advisory script URI — which an
# embedder-API host like flutter-pi leaves at the engine's default, a bare
# "main.dart" with no directory. With no directory to merge, the VM keeps
# the path as given, and its dot-segment removal does not strip a leading
# "./" (it compares three bytes, so only the exact string "./" matches).
# What reaches dlopen() is therefore "./libsqlite3.so": relative to the
# process's WORKING DIRECTORY, not to the bundle, and not searched on any
# library path — the error reads "Failed to load dynamic library
# './libsqlite3.so' relative to 'main.dart'". A bundle run by hand works
# only because one runs it from inside the bundle. Do the same here — which
# is why a file path in BRAINFRAME_ARGS must be absolute — and put the
# bundle on LD_LIBRARY_PATH as well, so a VM that one day does collapse the
# path to a bare name still finds it, the way the desktop AppImage's AppRun
# hook finds its lib/.
cd "$BUNDLE"
LD_LIBRARY_PATH="$BUNDLE${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LD_LIBRARY_PATH

# Rebuild the argument list with `--release <bundle>` in place of the first
# `--`, or appended when there is none.
seen=0
for a in "$@"; do
  shift
  if [ "$seen" = 0 ] && [ "$a" = -- ]; then
    set -- "$@" --release "$BUNDLE"
    seen=1
  else
    set -- "$@" "$a"
  fi
done
[ "$seen" = 1 ] || set -- "$@" --release "$BUNDLE"

if [ "${BRAINFRAME_CONSOLE_GUARD:-1}" = 0 ]; then
  exec "$FLUTTER_PI" "$@"
fi
if command -v python3 >/dev/null 2>&1; then
  exec python3 "$GUARD" "$FLUTTER_PI" "$@"
fi
cat >&2 <<EOF
$NAME: python3 not found, so the console keyboard stays ON while the app runs.
  Keystrokes typed into the app will ALSO reach the console's shell or login
  prompt and be acted on when the app exits. Install python3 (apt install
  python3) or launch from a systemd unit on a console with no getty.
EOF
exec "$FLUTTER_PI" "$@"
