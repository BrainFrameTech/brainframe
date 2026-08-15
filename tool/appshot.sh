#!/usr/bin/env bash
#
# appshot.sh — launch, drive, and screenshot the BrainFrame Linux desktop app
# for visual verification, all behind one allowlistable command.
#
# Why this exists: on this GNOME/Wayland box, capturing and controlling the app
# needs it running under X11 (XWayland) so maim + xdotool can see it. Doing that
# by hand is a dozen separate shell commands (and a dozen permission prompts).
# This wraps them so a single `Bash(.../tool/appshot.sh *)` allow rule covers the
# whole workflow.
#
# Linux only (GNOME/Wayland + XWayland, or plain X11). Run from the repo root as
# `tool/appshot.sh …`, or by absolute path from anywhere. Needs a running
# graphical session (`$DISPLAY`) and:
#
#   * `maim` + `x11-utils` (xprop, xwininfo) — for launch / status / shot / run.
#     These are the read-only commands, and they are the common case.
#   * `xdotool` — *only* to drive the app (hover, click, key, resize). The other
#     commands work without it; those four say so plainly and name the package.
#
# Window discovery deliberately uses `xprop` rather than `xdotool`, so a fresh
# machine can capture the app before anything extra is installed. `status`
# reports which tools are missing, because a missing tool once looked exactly
# like "no window" (`window=0`) and cost an afternoon.
#
# Usage:
#   tool/appshot.sh launch [PROJECT_DIR]   # flutter run -d linux (X11) from DIR
#                                          #   (default: cwd); waits for the window
#   tool/appshot.sh shot [OUT]             # capture the app window (default OUT below)
#   tool/appshot.sh run PROJECT_DIR [OUT]  # launch (if needed) + shot
#   tool/appshot.sh hover X Y [OUT]        # move mouse to window px (X,Y), settle, shot
#   tool/appshot.sh click X Y [OUT]        # move to (X,Y), left-click, settle, shot
#   tool/appshot.sh key NAME [OUT]         # send a key (e.g. Escape), settle, shot
#   tool/appshot.sh resize W H [OUT]       # resize the window to W×H px, settle, shot
#   tool/appshot.sh status                 # print "running=<n> window=<n>"
#   tool/appshot.sh quit                   # terminate the app (loops until gone)
#
# Each capturing command prints the PNG path on stdout. Window pixels map 1:1 to
# the coordinates you pass (the app window sits at the screen origin).
#
# Isolation: the app is always launched with `--engram <test/fixtures/engram>`
# and `--ignore-config`, so it opens the committed manual-testing fixture backed
# by an ephemeral (in-memory) config store. It never reads or writes the real
# app config or your real engrams, so driving even destructive flows here cannot
# interfere with normal use. The fixture is self-restoring (`git checkout -- .`).

set -uo pipefail
export DISPLAY="${DISPLAY:-:0}"

readonly APP_TITLE='BrainFrame'   # the real window's title (same in every build)
# We target ONLY the debug build. Its application ID gets a ".debug" suffix (see
# linux/CMakeLists.txt), giving its X windows a distinct WM_CLASS. So you can
# leave a release/profile build running all the time — dogfooding on your real
# notes — and this tool will never capture, click, resize, or quit it; it only
# ever sees the debug instance it launched.
readonly APP_CLASS='tech.brainframe.app.debug'
readonly APP_BUNDLE='build/linux/x64/debug/bundle/brainframe'
# Always launch against the committed manual-testing engram, never real data.
readonly TEST_ENGRAM='test/fixtures/engram'
readonly PIDFILE='/tmp/brainframe-appshot.pid'
readonly RUNLOG='/tmp/brainframe-appshot-run.log'
readonly DEFAULT_OUT='/tmp/brainframe-shot.png'

log() { printf 'appshot: %s\n' "$*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

# Aborts a driving command that has no xdotool to drive with, naming the fix.
# Silence here is what makes a fresh machine look broken, so this is loud.
require_driver() {
  have xdotool && return 0
  log "'$1' needs xdotool to move the pointer or send keys, and it is not installed."
  log "  fix: sudo apt install xdotool"
  log "  (launch, shot, run, status and quit all work without it.)"
  exit 69   # EX_UNAVAILABLE
}

# The window id (decimal — what both maim and xdotool take), or nothing.
#
# Read from the window manager's own client list via xprop, not xdotool: the
# capture path then depends on nothing beyond maim + x11-utils. Filter by class
# (so a release/profile build being dogfooded is never touched) and then by
# title. `_NET_CLIENT_LIST` holds only managed top-level windows, which also
# leaves out the debug build's two 10x10 helper windows for free.
find_window() {
  have xprop || { log "xprop is missing — install x11-utils"; return 1; }
  local ids id
  ids=$(xprop -root _NET_CLIENT_LIST 2>/dev/null | sed -n 's/.*# //p' | tr -d ' ' | tr ',' '\n')
  for id in $ids; do
    [ -n "$id" ] || continue
    xprop -id "$id" WM_CLASS 2>/dev/null | grep -q "\"${APP_CLASS}\"" || continue
    xprop -id "$id" WM_NAME _NET_WM_NAME 2>/dev/null | grep -q "\"${APP_TITLE}\"" || continue
    printf '%d\n' "$id"
    return 0
  done
  return 1
}

# "X Y WIDTH HEIGHT" for a window, in absolute screen pixels.
window_geometry() {
  have xwininfo || { log "xwininfo is missing — install x11-utils"; return 1; }
  xwininfo -id "$1" 2>/dev/null | awk '
    /Absolute upper-left X/ { x = $NF }
    /Absolute upper-left Y/ { y = $NF }
    /^  Width:/             { w = $NF }
    /^  Height:/            { h = $NF }
    END { if (w == "") exit 1; print x, y, w, h }'
}

app_running() { pgrep -f "$APP_BUNDLE" >/dev/null 2>&1; }

launch() {
  local proj="${1:-$PWD}"
  if app_running; then log "already running"; find_window; return 0; fi
  [ -d "$proj" ] || { log "no such project dir: $proj"; return 1; }
  proj=$(cd "$proj" && pwd)   # normalize to an absolute path for --engram
  local engram="$proj/$TEST_ENGRAM"
  log "launching from $proj (flutter run -d linux, --engram $engram --ignore-config)…"
  # Forward startup options to the Dart entrypoint's main(args). The `=` form
  # keeps flutter from mistaking the leading `--` of each value for its own flag.
  ( cd "$proj" && GDK_BACKEND=x11 nohup flutter run -d linux \
      --dart-entrypoint-args=--engram \
      --dart-entrypoint-args="$engram" \
      --dart-entrypoint-args=--ignore-config >"$RUNLOG" 2>&1 &
    echo $! >"$PIDFILE" )
  local wid=''
  for _ in $(seq 1 120); do          # up to ~4 min for a cold build
    wid=$(find_window); [ -n "$wid" ] && break
    if grep -qE 'error:|Exception|Build failed|Failed to build|Oops' "$RUNLOG" 2>/dev/null; then
      log "build error — tail of $RUNLOG:"; tail -n 12 "$RUNLOG" >&2; return 1
    fi
    sleep 2
  done
  [ -n "$wid" ] || { log "window never appeared; see $RUNLOG"; return 1; }
  sleep 2                            # let first frame render
  log "window up ($wid)"
  echo "$wid"
}

capture() {
  local out="${1:-$DEFAULT_OUT}" wid geo
  have maim || { log "maim is missing — fix: sudo apt install maim"; return 1; }
  wid=$(find_window)
  [ -n "$wid" ] || { log "no ${APP_TITLE} window — launch first"; return 1; }
  # Raising is a nicety, not a requirement: it guarantees an unoccluded window
  # before the grab. Without xdotool we capture where it lies.
  if have xdotool; then
    xdotool windowactivate "$wid" 2>/dev/null; xdotool windowraise "$wid" 2>/dev/null
    sleep 0.5
  fi
  if maim -i "$wid" "$out" 2>/tmp/appshot-maim.err; then
    echo "$out"; return 0
  fi
  # Fallback: some windows reject direct capture (RENDER BadMatch); grab the
  # screen region the window occupies instead.
  geo=$(window_geometry "$wid") || { log "capture failed and no geometry to fall back on"; return 1; }
  # shellcheck disable=SC2086
  set -- $geo
  if maim -g "${3}x${4}+${1}+${2}" "$out" 2>>/tmp/appshot-maim.err; then
    echo "$out"; return 0
  fi
  log "capture failed:"; cat /tmp/appshot-maim.err >&2; return 1
}

# Translate window-relative (x,y) to absolute screen coords (window origin + x,y).
to_screen() {
  local wid geo
  wid=$(find_window) || return 1
  geo=$(window_geometry "$wid") || return 1
  # shellcheck disable=SC2086
  set -- $geo "$1" "$2"
  printf '%s %s' "$(($1 + $5))" "$(($2 + $6))"
}

# Terminate the app and its `flutter run` supervisor, escalating to SIGKILL, and
# loop until nothing is left — so no ad-hoc cleanup (bare pkill/pgrep) is ever
# needed outside this allowlisted script.
quit_app() {
  [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null
  rm -f "$PIDFILE"
  local attempt
  for attempt in 1 2 3 4 5 6; do
    if [ "$attempt" -ge 3 ]; then
      pkill -9 -f 'flutter_tools.snapshot run -d linux' 2>/dev/null
      pkill -9 -f "$APP_BUNDLE" 2>/dev/null
    else
      pkill -f 'flutter_tools.snapshot run -d linux' 2>/dev/null
      pkill -f "$APP_BUNDLE" 2>/dev/null
    fi
    sleep 0.6
    pgrep -f "$APP_BUNDLE" >/dev/null 2>&1 || { log "quit (clean)"; return 0; }
  done
  log "warning: app still running after quit"
  return 1
}

require() { [ -n "${1:-}" ] || { log "missing argument"; exit 64; }; }

cmd="${1:-}"; shift || true
case "$cmd" in
  launch) launch "${1:-}" ;;
  shot)   capture "${1:-}" ;;
  run)    require "${1:-}"; launch "$1" >/dev/null || exit 1; capture "${2:-}" ;;
  hover)  require_driver hover; require "${1:-}"; require "${2:-}"
          read -r sx sy < <(to_screen "$1" "$2")
          xdotool mousemove "$sx" "$sy"; sleep 1; capture "${3:-}" ;;
  click)  require_driver click; require "${1:-}"; require "${2:-}"
          read -r sx sy < <(to_screen "$1" "$2")
          xdotool mousemove "$sx" "$sy"; sleep 0.3; xdotool click 1; sleep 1
          capture "${3:-}" ;;
  key)    require_driver key; require "${1:-}"
          xdotool key "$1"; sleep 0.6; capture "${2:-}" ;;
  resize) require_driver resize; require "${1:-}"; require "${2:-}"
          wid=$(find_window)
          [ -n "$wid" ] || { log "no ${APP_TITLE} window — launch first"; exit 1; }
          xdotool windowsize "$wid" "$1" "$2"; sleep 1; capture "${3:-}" ;;
  quit)   quit_app ;;
  status) running=$(pgrep -cf "$APP_BUNDLE" 2>/dev/null || true)
          window=0; find_window >/dev/null 2>&1 && window=1
          missing=''
          for tool in maim xprop xwininfo xdotool; do
            have "$tool" || missing="${missing:+$missing,}$tool"
          done
          # tools= is here so a missing dependency can never masquerade as
          # "no window": window=0 with tools=missing:xprop means the tool is
          # blind, not that the app is down.
          echo "running=${running:-0} window=${window} tools=${missing:+missing:}${missing:-ok}"
          [ -n "$missing" ] && log "install with: sudo apt install ${missing//,/ }"
          exit 0 ;;
  *) log "usage: appshot.sh {launch [DIR]|shot [OUT]|run DIR [OUT]|hover X Y [OUT]|click X Y [OUT]|key NAME [OUT]|resize W H [OUT]|status|quit}"
     exit 64 ;;
esac
