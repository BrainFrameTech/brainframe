#!/usr/bin/env bash
#
# appshot.sh — launch, drive, and screenshot the BrainFrame Linux desktop app
# for visual verification, all behind one allowlistable command.
#
# The app runs on a **private Xvfb display**, never on your desktop session.
# Nothing appears on screen, nothing steals focus, and your real mouse and
# keyboard cannot perturb a run. Doing that by hand is a dozen separate shell
# commands (and a dozen permission prompts); this wraps them so a single
# `Bash(.../tool/appshot.sh *)` allow rule covers the whole workflow.
#
# You can watch it happen: `launch` also exports the private display over VNC
# (view-only by default) and opens remmina on your real desktop, so the run is
# visible live without your pointer being able to disturb it. `quit` tears all
# of it down.
#
# Linux only. Run from the repo root as `tool/appshot.sh …`, or by absolute path
# from anywhere.
#
#   sudo apt install xvfb x11-utils xdotool maim openbox x11vnc remmina
#
# `tool/appshot.sh deps` checks these and prints exactly that line for whatever
# is missing. The window manager and the viewer are only required when they are
# switched on (see APPSHOT_WM / APPSHOT_VIEW below), so a headless run needs
# neither. `feed` additionally needs ffmpeg and the v4l2loopback kernel module.
#
# Usage:
#   tool/appshot.sh launch [PROJECT_DIR]   # start Xvfb + WM + app + viewer from DIR
#                                          #   (default: cwd); waits for the window
#   tool/appshot.sh shot [OUT]             # capture the app window (default OUT below)
#   tool/appshot.sh run PROJECT_DIR [OUT]  # launch (if needed) + shot
#   tool/appshot.sh hover X Y [OUT]        # move pointer to window px (X,Y), settle, shot
#   tool/appshot.sh click X Y [OUT]        # move to (X,Y), left-click, settle, shot
#   tool/appshot.sh rclick X Y [OUT]       # move to (X,Y), right-click, settle, shot
#   tool/appshot.sh key NAME [OUT]         # send a key/combo (Escape, ctrl+a), settle, shot
#   tool/appshot.sh type TEXT [OUT]        # type literal text, settle, shot
#   tool/appshot.sh resize W H [OUT]       # resize the window to W×H px, settle, shot
#   tool/appshot.sh stop                   # stop the app only; display, WM, VNC, feed stay
#   tool/appshot.sh feed [DEVICE]          # stream the display into a v4l2loopback device
#   tool/appshot.sh unfeed                 # stop that stream
#   tool/appshot.sh watch                  # (re)open the VNC viewer
#   tool/appshot.sh deps                   # check dependencies, print the apt line
#   tool/appshot.sh status                 # print the state of every moving part
#   tool/appshot.sh quit                   # tear down viewer, VNC, feed, app, WM, display
#
# Environment:
#   APPSHOT_DISPLAY  private display (default :99) — change to run two at once;
#                    every pidfile, port default and process lookup is scoped to it
#   APPSHOT_SCREEN   Xvfb screen geometry (default 1920x1200x24), or `fit` to make
#                    the screen exactly the window size, so a capture of the
#                    display is a capture of the window with nothing to crop
#   APPSHOT_WIN_W/H  window size (default 1600x1000)
#   APPSHOT_WM       window manager, or `none` (default openbox)
#   APPSHOT_VIEW     1 to auto-open the viewer, 0 for headless (default 1)
#   APPSHOT_INPUT    1 to let the viewer type and click into the app (default 0:
#                    view-only, so watching cannot perturb a run)
#   APPSHOT_VNC_PORT VNC port (default 5900 + display number: :99 → 5999)
#   APPSHOT_ENGRAM   engram folder to open instead of the committed fixture
#                    (--ignore-config stays on regardless)
#   APPSHOT_TITLE    --window-title for the app; also how its window is found
#   APPSHOT_V4L2     v4l2loopback device for `feed` (default /dev/video10)
#   APPSHOT_FEED_FPS frame rate for `feed` (default 30)
#   XDG_DATA_HOME    passed through untouched — point two instances at two
#                    device stores to show them converging
#
# Each capturing command prints the PNG path on stdout. Window pixels map 1:1 to
# the coordinates you pass: the window is moved to the screen origin at launch
# and GDK scaling is pinned to 1, so image pixel == window pixel == the (X,Y)
# you pass. No HiDPI or display-scale arithmetic anywhere.
#
# Isolation: the app is always launched with `--ignore-config`, and by default
# with `--engram <test/fixtures/engram>`, so it opens the committed
# manual-testing fixture backed by an ephemeral (in-memory) config store. It
# never reads or writes the real app config or your real engrams, so driving
# even destructive flows here cannot interfere with normal use. The fixture is
# self-restoring (`git checkout -- test/fixtures/engram`; the app's own
# `.brainframe/shared/` store there is git-ignored). APPSHOT_ENGRAM points it at
# a folder of your own instead — a scratch engram for a demo, say — but never at
# your config.
#
# ── Recording a demo ─────────────────────────────────────────────────────────
# The same isolation makes this the right stage for a screen recording. A
# Wayland desktop scales every window by the output scale and re-places it on
# each launch, so a recording of the live session has to be re-cropped every
# time the app restarts; a window-capture bound to one window goes dark the
# moment that window closes. Here neither happens: the display is unscaled, the
# window is parked at the origin at a fixed size, and the display outlives the
# app. Two instances, two displays:
#
#   export APPSHOT_WIN_W=1080 APPSHOT_WIN_H=640 APPSHOT_SCREEN=fit APPSHOT_INPUT=1
#   APPSHOT_DISPLAY=:99 APPSHOT_ENGRAM=/tmp/engramA APPSHOT_TITLE='BrainFrame A' \
#     XDG_DATA_HOME=/tmp/deviceA tool/appshot.sh launch
#   APPSHOT_DISPLAY=:99 tool/appshot.sh feed /dev/video10   # OBS: Video Capture Device
#   … and the same on :98 with engramB / deviceB / video11.
#
# `stop` quits the app and nothing else, so OBS keeps its source, remmina keeps
# its tab, and `launch` puts the next instance back in exactly the same pixels.
# That is the restart point for showing convergence: stop, do something in a
# terminal, launch again. With APPSHOT_SCREEN=fit the display *is* the window,
# so `feed` needs no crop and `launch` refuses to reuse a display of the wrong
# size rather than let the two silently disagree.
#
# `feed` will not load the kernel module for you. Loading it needs root, and a
# script that can `sudo` under a blanket allow rule is a root grant, not a
# tool; it would also hang waiting for a password when Claude runs it. It is a
# machine-level, one-time step anyway — `feed` prints the exact line.
#
# ── Why Xvfb, and not the desktop session ────────────────────────────────────
# Driving the app on the live GNOME/Wayland session does not work on this box,
# and cannot be made to:
#
#   * xdotool synthesizes input through the X11 XTEST extension. Recent GNOME no
#     longer lets XWayland clients drive the pointer that way — the request is
#     routed through the RemoteDesktop portal, so clicks either raise a "Screen
#     Sharing" consent dialog or are silently dropped. They *look* delivered:
#     the call succeeds and the pointer even appears to move, but the app never
#     receives the event.
#   * ydotool (writing to /dev/uinput below the compositor) dodges the portal,
#     but is screen-global and positions in absolute device coordinates that do
#     not track the compositor's display scale. After a scale change its clicks
#     landed over 1300px from the target. That approach was tried and abandoned.
#   * Either way the app shares a pointer with the human at the keyboard, so an
#     accidental mouse nudge silently corrupts a run.
#
# On Xvfb there is no compositor and no portal: XTEST is delivered by the X
# server straight to the client, exactly as it was designed to. The display is
# ours alone, so the pointer is ours alone. As a bonus the geometry is fixed and
# reproducible, which the desktop session never guaranteed.
#
# ── Window manager ───────────────────────────────────────────────────────────
# Xvfb is a bare X server, so a WM is something we start ourselves. Openbox is
# the default: it is fully EWMH-compliant, has no compositor, and starts
# instantly, which matters because it sits in the launch path.
#
# It earns its place by making activation *realistic* — `windowactivate` goes
# through `_NET_ACTIVE_WINDOW` exactly as it would on a real desktop, which is
# the path the app's own focus handling sees. With APPSHOT_WM=none there is no
# WM to ask, and we fall back to a direct XSetInputFocus (`windowfocus`); GTK
# turns the resulting FocusIn into ordinary keyboard focus, so typing and
# shortcuts still work. Being able to flip between the two in one variable is
# the cheapest way to answer "does this bug depend on window management?".
#
# Decorations change nothing: `maim -i` captures the *client* window and every
# coordinate is derived from the client's own geometry, so a title bar neither
# appears in a screenshot nor shifts the (X,Y) you pass.

set -uo pipefail

# The real window's title. 'BrainFrame' in every build unless the app is told
# otherwise with --window-title, which APPSHOT_TITLE passes — so the same value
# is what we look for.
readonly APP_TITLE="${APPSHOT_TITLE:-BrainFrame}"
# We target ONLY the debug build. Its application ID gets a ".debug" suffix (see
# linux/CMakeLists.txt), giving its X windows a distinct WM_CLASS. A release or
# profile build you are dogfooding is never captured, clicked, resized or quit —
# and now it is also on a different display entirely.
readonly APP_CLASS='tech.brainframe.app.debug'
readonly APP_BUNDLE='build/linux/x64/debug/bundle/brainframe'
# Same path as a pgrep -f regex, but with the first character bracketed so the
# pattern cannot match the shell command line that is running pgrep itself
# (a classic self-match false positive: `status` reporting running=1 with the
# app long gone). Likewise for the `flutter run` tool supervising the app.
readonly APP_BUNDLE_RE='[b]uild/linux/x64/debug/bundle/brainframe'
readonly TOOL_RE='[f]lutter_tools.snapshot run -d linux'
# Launch against the committed manual-testing engram unless told otherwise —
# never real data.
readonly TEST_ENGRAM='test/fixtures/engram'
readonly APPSHOT_ENGRAM="${APPSHOT_ENGRAM:-}"

# The display the *human* is sitting in front of. Captured before DISPLAY is
# redirected below, because the VNC viewer is the one thing that must open on
# the real desktop rather than inside the sandbox it is there to show.
readonly HOST_DISPLAY="${DISPLAY:-:0}"

# The private display. Override APPSHOT_DISPLAY to run two sessions at once;
# its number scopes everything below (state dir, VNC port, process lookups) so
# the two never see each other.
readonly APPSHOT_DISPLAY="${APPSHOT_DISPLAY:-:99}"
_dnum="${APPSHOT_DISPLAY#:}"; _dnum="${_dnum%%.*}"
[[ "$_dnum" =~ ^[0-9]+$ ]] || _dnum=0
readonly DISPLAY_NUM="$_dnum"

# The window is sized to this on launch so screenshots are byte-comparable
# between runs regardless of what geometry the toolkit would have picked.
readonly WIN_W="${APPSHOT_WIN_W:-1600}"
readonly WIN_H="${APPSHOT_WIN_H:-1000}"

# Screen geometry. `fit` makes the screen exactly the window, so anything that
# captures the display captures the window and nothing else. SCREEN_PINNED
# records that a size was asked for at all: a display already running at some
# other size is then an error, not something to quietly reuse.
if [ "${APPSHOT_SCREEN:-}" = fit ]; then
  _screen="${WIN_W}x${WIN_H}x24"
else
  _screen="${APPSHOT_SCREEN:-1920x1200x24}"
fi
# Normalize to WxHxD so a depth-less "1920x1200" is accepted too.
IFS=x read -r _sw _sh _sd <<<"$_screen"
readonly XVFB_SCREEN="${_sw}x${_sh}x${_sd:-24}"
readonly SCREEN_WH="${_sw}x${_sh}"
if [ -n "${APPSHOT_SCREEN:-}" ]; then readonly SCREEN_PINNED=1; else readonly SCREEN_PINNED=0; fi

# Window manager. Openbox gives the app real EWMH activation and focus
# semantics instead of the bare XSetInputFocus a WM-less server forces on us.
# Set APPSHOT_WM=none to go back to no WM (useful for isolating whether a
# behavior depends on window management at all).
readonly APPSHOT_WM="${APPSHOT_WM:-openbox}"
# Openbox config lives beside this script, so it is found however it is invoked.
OPENBOX_RC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/appshot-openbox-rc.xml"
readonly OPENBOX_RC

# Live viewing. x11vnc exports the private display; remmina opens on the real
# one to show it. Set APPSHOT_VIEW=0 for headless runs (CI, SSH without a
# desktop) where starting a viewer would be pointless or impossible.
# APPSHOT_INPUT=1 makes the viewer a keyboard and mouse too — for a demo you
# drive by hand — instead of the view-only default. The port follows the VNC
# convention of 5900 + display number, so two displays get two ports unasked.
readonly APPSHOT_VIEW="${APPSHOT_VIEW:-1}"
readonly APPSHOT_INPUT="${APPSHOT_INPUT:-0}"
readonly VNC_PORT="${APPSHOT_VNC_PORT:-$((5900 + DISPLAY_NUM))}"

# Feeding the display to OBS: ffmpeg grabs the whole screen and writes it to a
# v4l2loopback device, which OBS reads as an ordinary camera — one that keeps
# existing while the app is stopped and relaunched behind it.
readonly FEED_DEV="${APPSHOT_V4L2:-/dev/video10}"
readonly FEED_FPS="${APPSHOT_FEED_FPS:-30}"

readonly STATE_DIR="${TMPDIR:-/tmp}/brainframe-appshot-${DISPLAY_NUM}"
readonly PIDFILE="$STATE_DIR/app.pid"
readonly XVFB_PIDFILE="$STATE_DIR/xvfb.pid"
readonly WM_PIDFILE="$STATE_DIR/wm.pid"
readonly VNC_PIDFILE="$STATE_DIR/x11vnc.pid"
readonly VNC_MODEFILE="$STATE_DIR/x11vnc.mode"   # the APPSHOT_INPUT it was started with
readonly FEED_PIDFILE="$STATE_DIR/feed.pid"
readonly FEED_DEVFILE="$STATE_DIR/feed.dev"
readonly RUNLOG="$STATE_DIR/run.log"
readonly XVFB_LOG="$STATE_DIR/xvfb.log"
readonly WM_LOG="$STATE_DIR/wm.log"
readonly VNC_LOG="$STATE_DIR/x11vnc.log"
readonly VIEWER_LOG="$STATE_DIR/viewer.log"
readonly FEED_LOG="$STATE_DIR/feed.log"
readonly MAIM_ERR="$STATE_DIR/maim.err"
readonly DEFAULT_OUT="$STATE_DIR/shot.png"

mkdir -p "$STATE_DIR"

# Every X client below — xdotool, maim, xdpyinfo, ffmpeg, and the app itself —
# talks to the private display and nothing else. Exported once, here, so no
# subcommand can accidentally reach the real session. The single exception is
# the viewer, which is explicitly launched with DISPLAY=$HOST_DISPLAY.
export DISPLAY="$APPSHOT_DISPLAY"

log() { printf 'appshot: %s\n' "$*" >&2; }

# ── Dependencies ─────────────────────────────────────────────────────────────
# Checked up front and reported in one line, because discovering these one at a
# time — each failure looking like a different problem — is how an afternoon
# disappears. Split by tier: the viewer and the WM are only required when they
# are actually switched on, so a headless run needs neither, and the feed only
# when you ask for one.
#
# binary:package pairs (the two differ often enough to be worth spelling out).
readonly CORE_DEPS='Xvfb:xvfb xdpyinfo:x11-utils xdotool:xdotool maim:maim'
readonly WM_DEPS='openbox:openbox'
readonly VIEW_DEPS='x11vnc:x11vnc remmina:remmina'
readonly FEED_DEPS='ffmpeg:ffmpeg'

# Print the missing packages for the given binary:package list, if any.
missing_pkgs() {
  local pair bin pkg out=''
  for pair in $1; do
    bin="${pair%%:*}"; pkg="${pair##*:}"
    command -v "$bin" >/dev/null 2>&1 || out="$out $pkg"
  done
  printf '%s' "$out"
}

# Fail with one actionable apt line rather than a cascade of odd symptoms.
check_deps() {
  local missing; missing=$(missing_pkgs "$CORE_DEPS")
  [ "$APPSHOT_WM" != none ] && missing="$missing$(missing_pkgs "$WM_DEPS")"
  [ "$APPSHOT_VIEW" = 1 ] && missing="$missing$(missing_pkgs "$VIEW_DEPS")"
  [ -z "$missing" ] && return 0
  log "missing dependencies. Install them with:"
  log "  sudo apt install$missing"
  return 69
}

# What `feed` needs on top: ffmpeg, and the loopback module present on the
# system (loaded or not — loading is a separate, root-only step; see start_feed).
missing_feed_pkgs() {
  local missing; missing=$(missing_pkgs "$FEED_DEPS")
  modinfo v4l2loopback >/dev/null 2>&1 || missing="$missing v4l2loopback-dkms"
  printf '%s' "$missing"
}

display_up() { xdpyinfo >/dev/null 2>&1; }
screen_geometry() { xdpyinfo 2>/dev/null | awk '/dimensions:/ {print $2; exit}'; }
alive() { [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null; }

# Is our VNC server listening, and is anyone actually watching through it?
vnc_up() { ss -ltn 2>/dev/null | grep -q ":$VNC_PORT[[:space:]]"; }
viewer_connected() {
  ss -tn state established 2>/dev/null | grep -q ":$VNC_PORT[[:space:]]"
}
feed_up() { alive "$FEED_PIDFILE"; }

# Start a long-lived background process, detached, recording its *real* pid.
#
# `setsid ... & echo $!` is a trap: setsid forks when it is not already a
# process-group leader, so $! is often the short-lived parent and the pidfile
# ends up naming a process that died immediately — which then reads as "the
# thing crashed" when it is running fine. Having the child write its own $$
# before exec'ing is the only reliable version.
spawn() {
  local pidfile="$1" logfile="$2"; shift 2
  local quoted; printf -v quoted '%q ' "$@"
  setsid nohup bash -c "echo \$\$ >'$pidfile'; exec $quoted" >"$logfile" 2>&1 &
}

# Kill whatever a pidfile names, then drop the pidfile. Quiet about a process
# that is already gone — teardown must be safe to run twice.
stop_pidfile() {
  [ -f "$1" ] || return 0
  kill "$(cat "$1")" 2>/dev/null
  rm -f "$1"
}

# ── Process discovery, scoped to our display ─────────────────────────────────
# Every pid matching PATTERN (a pgrep -f regex) whose environment carries our
# DISPLAY. The app and its `flutter run` supervisor inherit DISPLAY from
# launch(), so this is what keeps a session on :98 from seeing — or, in stop
# and quit, killing — the one on :99. Only our own processes' environments are
# readable, which is exactly the set we care about.
pids_on_display() {
  local pid
  for pid in $(pgrep -f "$1" 2>/dev/null); do
    # 2>/dev/null before the input redirect: a failed `<` is reported before
    # any redirection to its right takes effect, and someone else's process
    # matching the pattern is unreadable, not an error.
    tr '\0' '\n' 2>/dev/null <"/proc/$pid/environ" \
      | grep -qx "DISPLAY=$APPSHOT_DISPLAY" && echo "$pid"
  done
}
app_pids()  { pids_on_display "$APP_BUNDLE_RE"; }
tool_pids() { pids_on_display "$TOOL_RE"; }
app_running() { [ -n "$(app_pids)" ]; }

# Bring up the private X server, unless it is already there. Idempotent: every
# driving subcommand calls this, so a stray `click` after a reboot still works.
#
# An Xvfb screen cannot be resized once it is up. If a size was asked for
# (APPSHOT_SCREEN set) and the running display is some other size, that is a
# hard error: for a recording, a display that does not match its window means
# a capture that silently does not match either, which is the one thing `fit`
# exists to rule out. With no size asked for, whatever is up is fine.
start_xvfb() {
  if display_up; then
    local have; have=$(screen_geometry)
    if [ "$SCREEN_PINNED" = 1 ] && [ "$have" != "$SCREEN_WH" ]; then
      log "display $APPSHOT_DISPLAY is already up at $have, but $SCREEN_WH was requested."
      log "Xvfb cannot be resized in place — run \`quit\` first, then launch again."
      return 1
    fi
    return 0
  fi
  command -v Xvfb >/dev/null || { log "Xvfb not installed (sudo apt install xvfb)"; return 1; }
  log "starting Xvfb on $APPSHOT_DISPLAY ($XVFB_SCREEN)…"
  # -nolisten tcp keeps it off the network; -ac then costs nothing and saves
  # maintaining an xauth file for a display only we use. -noreset stops the
  # server tearing down its state when the last client exits between commands.
  spawn "$XVFB_PIDFILE" "$XVFB_LOG" \
    Xvfb "$APPSHOT_DISPLAY" -screen 0 "$XVFB_SCREEN" -nolisten tcp -ac -noreset
  local _
  for _ in $(seq 1 40); do            # ~10s
    display_up && { log "display up"; return 0; }
    sleep 0.25
  done
  log "Xvfb never came up — tail of $XVFB_LOG:"; tail -n 10 "$XVFB_LOG" >&2
  return 1
}

# Openbox on the private display. Idempotent, like everything else here.
#
# It runs undecorated (see appshot-openbox-rc.xml). A framed window puts the
# client at an offset from its frame, which makes the origin `maim` captures
# from and the origin coordinates are computed from disagree — clicks then land
# tens of pixels off with nothing to show for it. Undecorated, the client is the
# frame, so coordinates are identical whether the WM is on or off.
start_wm() {
  [ "$APPSHOT_WM" = none ] && return 0
  alive "$WM_PIDFILE" && return 0
  command -v "$APPSHOT_WM" >/dev/null || { log "$APPSHOT_WM not installed"; return 1; }
  log "starting $APPSHOT_WM on $APPSHOT_DISPLAY…"
  if [ "$APPSHOT_WM" = openbox ] && [ -f "$OPENBOX_RC" ]; then
    spawn "$WM_PIDFILE" "$WM_LOG" openbox --config-file "$OPENBOX_RC"
  else
    spawn "$WM_PIDFILE" "$WM_LOG" "$APPSHOT_WM"
  fi
  # Wait for the WM to own the screen, so the app's window is managed from the
  # moment it maps rather than racing it.
  local _
  for _ in $(seq 1 20); do
    xprop -root _NET_SUPPORTING_WM_CHECK 2>/dev/null | grep -q 'window id' && return 0
    sleep 0.25
  done
  log "warning: $APPSHOT_WM did not claim the display; continuing without it"
  return 0
}

# Stop our VNC server. x11vnc outlives a killed parent often enough to be worth
# a backstop, and it holds the port open when it does. Scoped to our own port
# so a VNC server someone else is running is never touched, and bracketed so a
# shell whose command line merely mentions the pattern is not (see APP_BUNDLE_RE).
stop_vnc() {
  stop_pidfile "$VNC_PIDFILE"
  pkill -f "[x]11vnc.*-rfbport $VNC_PORT" 2>/dev/null
  rm -f "$VNC_MODEFILE"
}

# Export the private display over VNC and open the viewer on the real one.
#
# View-only is the default, and the point: the human watches without being able
# to inject input, so watching a run cannot perturb it. That preserves exactly
# the property the private display bought us. APPSHOT_INPUT=1 drops -viewonly
# for a demo you drive by hand; x11vnc then injects through XTEST, the same
# path xdotool uses, so the app sees an ordinary keyboard and mouse.
#
# The mode is recorded next to the pid. A server left over from a run in the
# other mode is restarted, not reused: a view-only tab that swallows your typing
# looks exactly like an app that ignores it, and nobody should debug that.
# -localhost keeps it off the network in either mode.
start_viewer() {
  [ "$APPSHOT_VIEW" = 1 ] || return 0
  if vnc_up && [ "$(cat "$VNC_MODEFILE" 2>/dev/null)" != "$APPSHOT_INPUT" ]; then
    log "VNC server on $VNC_PORT is in the other input mode; restarting it (APPSHOT_INPUT=$APPSHOT_INPUT)…"
    stop_vnc
    local _
    for _ in $(seq 1 20); do
      vnc_up || break
      sleep 0.25
    done
    vnc_up && log "warning: something else still holds port $VNC_PORT; the viewer may not be ours"
  fi
  if ! vnc_up; then
    command -v x11vnc >/dev/null || { log "x11vnc not installed"; return 1; }
    local -a input=(-viewonly)
    local how='view-only'
    [ "$APPSHOT_INPUT" = 1 ] && { input=(); how='interactive'; }
    log "exporting $APPSHOT_DISPLAY over VNC on localhost:$VNC_PORT ($how)…"
    # x11vnc refuses to start if it *thinks* it is on Wayland — and it decides
    # that from WAYLAND_DISPLAY/XDG_SESSION_TYPE in the environment, never
    # looking at the display it was actually handed. Inheriting the desktop's
    # session variables therefore kills it on a pure X display, with an error
    # about Wayland that has nothing to do with :99. Scrub them.
    spawn "$VNC_PIDFILE" "$VNC_LOG" \
      env -u WAYLAND_DISPLAY XDG_SESSION_TYPE=x11 \
      x11vnc -display "$APPSHOT_DISPLAY" -rfbport "$VNC_PORT" \
        -localhost "${input[@]}" -nopw -forever -shared
    echo "$APPSHOT_INPUT" >"$VNC_MODEFILE"
    local _
    for _ in $(seq 1 40); do
      vnc_up && break
      sleep 0.25
    done
    vnc_up || { log "x11vnc did not listen on $VNC_PORT — tail of $VNC_LOG:"
                tail -n 10 "$VNC_LOG" >&2; return 1; }
  fi
  if ! viewer_connected; then
    command -v remmina >/dev/null || { log "remmina not installed"; return 1; }
    log "opening remmina on $HOST_DISPLAY…"
    # The viewer is the one client that belongs on the human's desktop, so it
    # is the one place DISPLAY is deliberately pointed back at the real session.
    #
    # Remmina is single-instance: `-c` hands the URI to an already-running
    # `remmina -i` and exits, so the process we start here is gone in a moment
    # and its pid tells us nothing. That is why "is anyone watching" is answered
    # by looking for a live TCP connection to the VNC port instead.
    DISPLAY="$HOST_DISPLAY" setsid nohup \
      remmina -c "vnc://localhost:$VNC_PORT" >"$VIEWER_LOG" 2>&1 &
  fi
  return 0
}

# ── Feed: the display as a camera ────────────────────────────────────────────
# Is DEV a v4l2loopback node? Loopback devices are virtual, so they live under
# /sys/devices/virtual/video4linux; a real camera sits under its USB/PCI bus.
is_loopback() { [ -c "$1" ] && [ -e "/sys/devices/virtual/video4linux/$(basename "$1")" ]; }

# Deliberately advice, not action: loading a kernel module needs root, and this
# script runs unprivileged under a blanket allow rule — see the header.
modprobe_hint() {
  log "$1 is not a v4l2loopback device. Load the module once (root; this script"
  log "will not do it for you) with:"
  log "  sudo modprobe v4l2loopback video_nr=10,11 card_label=BrainFrameA,BrainFrameB exclusive_caps=1"
  log "To keep it across reboots, put 'v4l2loopback' in /etc/modules-load.d/v4l2loopback.conf"
  log "and that same 'options v4l2loopback video_nr=… card_label=… exclusive_caps=1' line in"
  log "/etc/modprobe.d/v4l2loopback.conf."
}

# Stream the whole private display into DEV. With APPSHOT_SCREEN=fit the whole
# display is the window, so OBS gets the window with nothing to crop; otherwise
# it gets the screen with the window in its top-left corner. yuyv422 is what
# every V4L2 consumer accepts and keeps text sharp; exclusive_caps=1 on the
# module makes the device look like a real camera to OBS and browsers.
start_feed() {
  local dev="${1:-$FEED_DEV}" missing
  missing=$(missing_feed_pkgs)
  if [ -n "$missing" ]; then
    log "missing dependencies. Install them with:"; log "  sudo apt install$missing"; return 69
  fi
  is_loopback "$dev" || { modprobe_hint "$dev"; return 69; }
  start_xvfb || return 1
  if feed_up; then log "feed already running → $(cat "$FEED_DEVFILE" 2>/dev/null)"; return 0; fi
  local geom; geom=$(screen_geometry)
  log "feeding $APPSHOT_DISPLAY ($geom @ ${FEED_FPS}fps) into $dev…"
  # -nostdin: ffmpeg otherwise reads its keyboard controls from the terminal
  # it was started in, and the first stray 'q' typed there would end the feed.
  spawn "$FEED_PIDFILE" "$FEED_LOG" \
    ffmpeg -hide_banner -loglevel warning -nostdin \
      -f x11grab -framerate "$FEED_FPS" -video_size "$geom" -i "${APPSHOT_DISPLAY}+0,0" \
      -pix_fmt yuyv422 -f v4l2 "$dev"
  echo "$dev" >"$FEED_DEVFILE"
  sleep 1
  feed_up || { log "ffmpeg exited — tail of $FEED_LOG:"; tail -n 10 "$FEED_LOG" >&2
               rm -f "$FEED_DEVFILE"; return 1; }
  log "feed up: add $dev as a Video Capture Device in OBS. It survives stop/launch."
}

stop_feed() {
  feed_up && log "feed stopped"
  stop_pidfile "$FEED_PIDFILE"
  rm -f "$FEED_DEVFILE"
}

# The debug build exposes three X windows sharing APP_CLASS: two 10x10 helpers
# and the real one titled APP_TITLE. Filter by class (excludes any release/
# profile build) then by title (excludes the 10x10 helpers).
find_window() {
  local wid
  for wid in $(xdotool search --classname "^${APP_CLASS}\$" 2>/dev/null); do
    [ "$(xdotool getwindowname "$wid" 2>/dev/null)" = "$APP_TITLE" ] && { echo "$wid"; return 0; }
  done
}

# Park the window at the origin at a known size, and give it keyboard focus.
# Without a WM this is the only thing that will, so it runs on every launch.
#
# The size is read back afterwards and any difference reported: the app's own
# minimum size or the WM can clamp a request, and for a capture sized to the
# screen that is the difference between a clean frame and a mystery border.
place_window() {
  local wid="$1"
  xdotool windowmove "$wid" 0 0 2>/dev/null
  xdotool windowsize "$wid" "$WIN_W" "$WIN_H" 2>/dev/null
  xdotool windowraise "$wid" 2>/dev/null
  # With a WM, activate through EWMH — that is what a real desktop does, and it
  # is the path the app's own focus handling will see. Without one there is
  # nothing to ask, so fall back to a direct XSetInputFocus.
  xdotool windowactivate "$wid" 2>/dev/null \
    || xdotool windowfocus --sync "$wid" 2>/dev/null
  sleep 0.5
  local X Y WIDTH HEIGHT WINDOW SCREEN
  eval "$(xdotool getwindowgeometry --shell "$wid" 2>/dev/null)"
  if [ "${WIDTH:-}" != "$WIN_W" ] || [ "${HEIGHT:-}" != "$WIN_H" ]; then
    log "warning: asked for ${WIN_W}x${WIN_H} but the window is ${WIDTH:-?}x${HEIGHT:-?}" \
        "— the app's minimum size or the WM clamped it, so a screen-sized capture will not match"
  fi
}

launch() {
  local proj="${1:-$PWD}"
  check_deps || return $?
  start_xvfb || return 1
  start_wm || return 1
  if app_running; then
    log "already running"
    local wid; wid=$(find_window)
    [ -n "$wid" ] && { place_window "$wid"; echo "$wid"; }
    start_viewer || log "warning: viewer unavailable; carrying on headless"
    return 0
  fi
  [ -d "$proj" ] || { log "no such project dir: $proj"; return 1; }
  proj=$(cd "$proj" && pwd)   # normalize to an absolute path for --engram
  local engram
  if [ -n "$APPSHOT_ENGRAM" ]; then
    [ -d "$APPSHOT_ENGRAM" ] || { log "no such engram folder: $APPSHOT_ENGRAM"; return 1; }
    engram=$(cd "$APPSHOT_ENGRAM" && pwd)
  else
    engram="$proj/$TEST_ENGRAM"
    [ -d "$engram" ] || { log "no test engram at $engram"; return 1; }
  fi
  # The `=` form on --dart-entrypoint-args keeps flutter from mistaking the
  # leading `--` of each value for one of its own flags.
  local -a app_args=(
    --dart-entrypoint-args=--engram
    --dart-entrypoint-args="$engram"
    --dart-entrypoint-args=--ignore-config
  )
  [ -n "${APPSHOT_TITLE:-}" ] && app_args+=(
    --dart-entrypoint-args=--window-title
    --dart-entrypoint-args="$APP_TITLE"
  )
  log "launching from $proj on $APPSHOT_DISPLAY ($(screen_geometry)) (--engram $engram --ignore-config${APPSHOT_TITLE:+ --window-title '$APP_TITLE'})…"
  # setsid detaches `flutter run` into its own session and process group, so it
  # survives the shell that started it going away — otherwise the app dies the
  # moment the calling tool call or terminal is reaped, and `status` reports a
  # window that vanished for no visible reason.
  #
  # GDK_SCALE/GDK_DPI_SCALE pin the device pixel ratio to 1 so window pixels,
  # screenshot pixels, and the coordinates you pass are all the same unit.
  # DISPLAY is what pids_on_display() later keys on, so it is set explicitly.
  ( cd "$proj" && DISPLAY="$APPSHOT_DISPLAY" GDK_BACKEND=x11 GDK_SCALE=1 \
      GDK_DPI_SCALE=1 setsid nohup flutter run -d linux "${app_args[@]}" \
      >"$RUNLOG" 2>&1 &
    echo $! >"$PIDFILE" )
  local wid='' _
  for _ in $(seq 1 120); do          # up to ~4 min for a cold build
    wid=$(find_window); [ -n "$wid" ] && break
    if grep -qE 'error:|Exception|Build failed|Failed to build|Oops' "$RUNLOG" 2>/dev/null; then
      log "build error — tail of $RUNLOG:"; tail -n 12 "$RUNLOG" >&2; return 1
    fi
    sleep 2
  done
  [ -n "$wid" ] || { log "window never appeared; see $RUNLOG"; return 1; }
  sleep 2                            # let the first frame render
  place_window "$wid"
  # Only worth watching once there is something on screen to watch.
  start_viewer || log "warning: viewer unavailable; carrying on headless"
  local X Y WIDTH HEIGHT WINDOW SCREEN
  eval "$(xdotool getwindowgeometry --shell "$wid" 2>/dev/null)"
  log "window up ($wid) at ${WIDTH:-$WIN_W}x${HEIGHT:-$WIN_H}"
  echo "$wid"
}

capture() {
  local out="${1:-$DEFAULT_OUT}" wid
  wid=$(find_window)
  [ -n "$wid" ] || { log "no ${APP_TITLE} window — launch first"; return 1; }
  xdotool windowraise "$wid" 2>/dev/null
  sleep 0.3
  if maim -i "$wid" "$out" 2>"$MAIM_ERR"; then echo "$out"; return 0; fi
  # Fallback: some windows reject direct capture (RENDER BadMatch); grab the
  # screen region the window occupies instead.
  local X Y WIDTH HEIGHT WINDOW SCREEN
  eval "$(xdotool getwindowgeometry --shell "$wid")"
  if maim -g "${WIDTH}x${HEIGHT}+${X}+${Y}" "$out" 2>>"$MAIM_ERR"; then
    echo "$out"; return 0
  fi
  log "capture failed:"; cat "$MAIM_ERR" >&2; return 1
}

# Move the pointer to window-relative (x,y) and prove it arrived.
#
# The verification is the whole point: the previous incarnations of this script
# failed *silently* — the move call succeeded while the pointer went somewhere
# else entirely, so a screenshot showing "nothing happened" was indistinguishable
# from a real UI bug. Anything that cannot be confirmed is now a loud failure.
point_at() {
  local wid X Y WIDTH HEIGHT WINDOW SCREEN sx sy mx my
  wid=$(find_window)
  [ -n "$wid" ] || { log "no ${APP_TITLE} window — launch first"; return 1; }
  eval "$(xdotool getwindowgeometry --shell "$wid")"
  sx=$((X + $1)); sy=$((Y + $2))
  if [ "$1" -lt 0 ] || [ "$2" -lt 0 ] || [ "$1" -ge "$WIDTH" ] || [ "$2" -ge "$HEIGHT" ]; then
    log "($1,$2) is outside the ${WIDTH}x${HEIGHT} window"; return 1
  fi
  xdotool mousemove --sync "$sx" "$sy" 2>/dev/null
  eval "$(xdotool getmouselocation --shell 2>/dev/null)"
  mx="${X:-}"; my="${Y:-}"
  if [ "$mx" != "$sx" ] || [ "$my" != "$sy" ]; then
    log "pointer did not reach ($sx,$sy) — it is at ($mx,$my); aborting"
    return 1
  fi
  sleep 0.3
}

# Stop the app and nothing else. The display, WM, VNC server, viewer tab and
# feed all stay up, so a capture pointed at the display keeps rolling and the
# next `launch` puts the next instance back in the same pixels. This is the
# restart point when recording: stop, do something in a terminal, launch.
#
# Graceful first: the app's own Quit shortcut (Ctrl+Q) runs its single exit
# path — flush unsaved edits, save geometry, close — which a signal would skip,
# and which is exactly what a demo of persistence needs to have happened. Only
# if the app is still there afterwards do we escalate, TERM then KILL, scoped
# to this display's processes so a second instance elsewhere is untouched.
stop_app() {
  local wid attempt pids rc=0
  if ! app_running && [ -z "$(tool_pids)" ]; then
    rm -f "$PIDFILE"; log "app not running on $APPSHOT_DISPLAY"; return 0
  fi
  wid=$(find_window)
  if [ -n "$wid" ]; then
    xdotool windowactivate "$wid" 2>/dev/null \
      || xdotool windowfocus --sync "$wid" 2>/dev/null
    sleep 0.3
    xdotool key --clearmodifiers ctrl+q 2>/dev/null
    for attempt in $(seq 1 20); do   # ~5s for a clean exit
      app_running || break
      sleep 0.25
    done
  fi
  for attempt in 1 2 3 4 5 6; do
    pids="$(tool_pids) $(app_pids)"
    [ -z "${pids// /}" ] && break
    # shellcheck disable=SC2086  # pids is a word list on purpose
    if [ "$attempt" -ge 3 ]; then kill -9 $pids 2>/dev/null; else kill $pids 2>/dev/null; fi
    sleep 0.6
    [ "$attempt" = 6 ] && { log "warning: app still running after stop"; rc=1; }
  done
  rm -f "$PIDFILE"
  [ "$rc" = 0 ] && log "app stopped"
  return "$rc"
}

# Terminate everything — outside-in: the VNC server first, then the feed, the
# app, the WM, and finally the display everything else was sitting on — and
# leave nothing behind, so no ad-hoc cleanup (bare pkill/pgrep) is ever needed
# outside this allowlisted script.
quit_all() {
  # Remmina is deliberately left alone. It is single-instance, so the session is
  # held inside the user's own `remmina -i` daemon — killing that would close
  # every other connection they have open. Dropping the server disconnects our
  # session on its own, which is the cleanup that is actually ours to do; their
  # remmina is left showing a disconnected tab to close whenever they like.
  stop_vnc
  stop_feed
  local rc=0
  stop_app || rc=1
  stop_pidfile "$WM_PIDFILE"
  # The display is private to this tool, so nothing else can be relying on it.
  stop_pidfile "$XVFB_PIDFILE"

  # Sweep any pidfile left behind — including ones written by an older version
  # of this script, which would otherwise sit here forever looking like a
  # process we failed to reap.
  rm -f "$STATE_DIR"/*.pid

  [ "$rc" = 0 ] && log "quit (clean)"
  return "$rc"
}

require() { [ -n "${1:-}" ] || { log "missing argument"; exit 64; }; }
# Driving subcommands need the display, but must not silently start a *new* one
# and then report "no window" — start_xvfb is idempotent and cheap, so it is
# safe to call first and lets a stray command fail with a clear message.
ready() { start_xvfb || exit 1; }

cmd="${1:-}"; shift || true
case "$cmd" in
  launch) launch "${1:-}" ;;
  shot)   ready; capture "${1:-}" ;;
  run)    require "${1:-}"; launch "$1" >/dev/null || exit 1; capture "${2:-}" ;;
  hover)  require "${1:-}"; require "${2:-}"; ready
          point_at "$1" "$2" || exit 1
          capture "${3:-}" ;;
  click)  require "${1:-}"; require "${2:-}"; ready
          point_at "$1" "$2" || exit 1
          xdotool click 1; sleep 1; capture "${3:-}" ;;
  rclick) require "${1:-}"; require "${2:-}"; ready
          point_at "$1" "$2" || exit 1
          xdotool click 3; sleep 1; capture "${3:-}" ;;
  key)    require "${1:-}"; ready
          wid=$(find_window); [ -n "$wid" ] && xdotool windowfocus --sync "$wid" 2>/dev/null
          xdotool key --clearmodifiers "$1"; sleep 0.6; capture "${2:-}" ;;
  type)   require "${1:-}"; ready
          wid=$(find_window); [ -n "$wid" ] && xdotool windowfocus --sync "$wid" 2>/dev/null
          xdotool type --clearmodifiers --delay 30 "$1"; sleep 0.6; capture "${2:-}" ;;
  resize) require "${1:-}"; require "${2:-}"; ready
          wid=$(find_window)
          [ -n "$wid" ] || { log "no ${APP_TITLE} window — launch first"; exit 1; }
          xdotool windowsize "$wid" "$1" "$2"; sleep 1; capture "${3:-}" ;;
  stop)   display_up || { log "display $APPSHOT_DISPLAY is not up; nothing to stop"; exit 0; }
          stop_app && log "display, WM, VNC and feed left up — \`launch\` to relaunch" ;;
  feed)   start_feed "${1:-}" ;;
  unfeed) stop_feed ;;
  watch)  check_deps || exit $?
          start_xvfb || exit 1
          start_viewer || exit 1 ;;
  deps)   rc=0; check_deps || rc=$?
          feed_missing=$(missing_feed_pkgs)
          [ -n "$feed_missing" ] && log "for \`feed\`, additionally: sudo apt install$feed_missing"
          [ "$rc" = 0 ] && [ -z "$feed_missing" ] && log "all dependencies present"
          exit "$rc" ;;
  quit)   quit_all ;;
  status) display=0; screen='-'; display_up && { display=1; screen=$(screen_geometry); }
          wm=0; alive "$WM_PIDFILE" && wm=1
          vnc=0; input='-'; vnc_up && { vnc=1; input=$(cat "$VNC_MODEFILE" 2>/dev/null || echo '?'); }
          # "Watching" is a live TCP connection, not a process we started —
          # remmina hands off to its own daemon, so its pid proves nothing.
          viewer=0; viewer_connected && viewer=1
          feed=0; feed_up && feed=1
          running=$(app_pids | grep -c . || true)
          window=$(find_window | grep -c . || true)
          echo "display=${display} screen=${screen} wm=${wm} running=${running:-0} window=${window:-0} vnc=${vnc} input=${input} viewer=${viewer} feed=${feed}" ;;
  *) log "usage: appshot.sh {launch [DIR]|shot [OUT]|run DIR [OUT]|hover X Y [OUT]|click X Y [OUT]|rclick X Y [OUT]|key NAME [OUT]|type TEXT [OUT]|resize W H [OUT]|stop|feed [DEVICE]|unfeed|watch|deps|status|quit}"
     exit 64 ;;
esac
