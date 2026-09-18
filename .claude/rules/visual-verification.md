# Visual Verification (Linux desktop)

Automated tests prove behavior, but some things only a running window reveals —
layout, overflow, hover/splash bleed, alignment, theme. On Linux,
`tool/appshot.sh` launches the real desktop app **on a private Xvfb display**,
drives it, and captures screenshots, so a change can be *seen* and not just
asserted.

This is developer tooling, not part of the app. It is Linux-only today; a macOS
or Windows equivalent would be a welcome addition, and this script is expected
to grow as more contributors lean on it.

## Why a headless display (and not your desktop session)

The app does **not** run on your GNOME session. It runs on an X server that
exists only for this tool (`:99` by default). Nothing appears on screen,
nothing steals focus, and your mouse cannot perturb a run.

That is not a preference — driving the live session does not work here:

- `xdotool` synthesizes input through the X11 **XTEST** extension. Recent GNOME
  no longer lets XWayland clients drive the pointer that way: the request goes
  through the RemoteDesktop portal, so clicks either raise a "Screen Sharing"
  consent dialog or are **silently dropped**. This is the dangerous one — the
  call succeeds and the pointer even appears to move, so a screenshot showing
  "nothing happened" is indistinguishable from a real UI bug.
- `ydotool` (writing to `/dev/uinput`, below the compositor) dodges the portal,
  but positions in absolute device coordinates that do not track the
  compositor's display scale. After a scale change its clicks landed >1300px
  from the target. That approach was tried and **abandoned**; don't revive it.
- Either way the app shares one pointer with the human at the keyboard, so an
  accidental nudge silently corrupts a run.

On Xvfb there is no compositor and no portal, so XTEST is delivered straight to
the client as designed. Two bonuses fall out of it: the geometry is fixed and
reproducible, and screenshots are comparable between runs.

Other sharp edges the script encodes so nobody re-derives them:

- The Flutter app exposes three X windows — two 10×10 helpers and the real one
  titled **`BrainFrame`**. `maim -i` on a helper fails with a RENDER
  `BadMatch`; you must pick the titled window.
- The debug build's windows carry a distinct `WM_CLASS` of
  `tech.brainframe.app.debug` (the release/profile ID is `tech.brainframe.app`;
  the `.debug` suffix is added in `linux/CMakeLists.txt`). The script selects on
  **that class *and* the `BrainFrame` title**, so a release/profile build you
  are dogfooding is never captured, clicked, resized, or quit — and it is now on
  a different display entirely.
- `flutter run` is started under `setsid`, so it survives the shell that
  launched it. Without that the app dies the moment the calling tool call or
  terminal is reaped, and `status` reports a window that vanished for no
  visible reason.
- **Openbox** runs on the private display so the app gets real EWMH activation
  and focus semantics rather than a bare `XSetInputFocus`. It runs
  **undecorated** (`tool/appshot-openbox-rc.xml`): a framed window puts the
  client at an offset from its frame, so the origin screenshots are captured
  from and the origin coordinates are computed from disagree, and clicks land
  tens of pixels off with nothing on screen to explain it. Undecorated, the
  client *is* the frame and coordinates are identical with the WM on or off —
  so `APPSHOT_WM=none` is a clean A/B for "does this depend on window
  management?" and never moves the target.

## Requirements

```bash
sudo apt install xvfb x11-utils xdotool maim openbox x11vnc remmina
```

Plus the Flutter Linux desktop toolchain (already needed to build the app).
`tool/appshot.sh deps` checks all of them and prints exactly that line for
whatever is missing — worth running first on an unfamiliar machine, because
these fail in ways that each look like a different problem.

The window manager and viewer are only required when switched on, so a headless
run (`APPSHOT_WM=none APPSHOT_VIEW=0`) needs neither. No graphical session is
required for the app itself — that part works over SSH and in CI. `feed`
additionally needs `ffmpeg` and `v4l2loopback-dkms`; `deps` lists them
separately, since nothing else depends on them.

## Watching a run live

`launch` exports the private display over VNC and opens remmina on your real
desktop, so you can watch the app being driven:

- The x11vnc server is **view-only** by default and bound to **localhost**. You
  can watch but not type or click, which is deliberate — it preserves the
  isolation the private display bought. To interact, drive through the
  subcommands — or, for a demo you drive by hand, set `APPSHOT_INPUT=1`: the
  server then accepts keyboard and mouse from the remmina tab, injected through
  XTEST just like `xdotool`, so the app sees an ordinary desktop. A server left
  over in the other mode is restarted, not reused, because a view-only tab that
  swallows typing is indistinguishable from an app that ignores it.
- `tool/appshot.sh watch` reopens the viewer if you closed it.
- `APPSHOT_VIEW=0` disables it; `APPSHOT_VNC_PORT` changes the port, which
  defaults to `5900 + display number` (`:99` → 5999, `:98` → 5998) so two
  displays get two ports without being told.
- x11vnc decides it is "on Wayland" from `WAYLAND_DISPLAY` /
  `XDG_SESSION_TYPE` in its environment and refuses to start — it never looks
  at the display it was handed. The script scrubs both. If you run x11vnc by
  hand against `:99` and it exits complaining about Wayland, that is why.
- `quit` stops the VNC server, which disconnects the session. Remmina itself is
  left running on purpose: it is single-instance, so killing it would close
  every other connection you have open. Close the dead tab when you like.

## Usage

Run from the repo root (or by absolute path from anywhere):

```bash
tool/appshot.sh launch [PROJECT_DIR]   # start Xvfb + the app; waits for the window
tool/appshot.sh run PROJECT_DIR [OUT]  # launch (if needed) + capture
tool/appshot.sh shot [OUT]             # capture the running app
tool/appshot.sh hover X Y [OUT]        # pointer to window px, then capture
tool/appshot.sh click X Y [OUT]        # move, left-click, then capture
tool/appshot.sh rclick X Y [OUT]       # move, right-click, then capture
tool/appshot.sh key NAME [OUT]         # send a key/combo (Escape, ctrl+a), capture
tool/appshot.sh type TEXT [OUT]        # type literal text, capture
tool/appshot.sh resize W H [OUT]       # resize the window, capture
tool/appshot.sh stop                   # stop the app only; display, WM, VNC, feed stay
tool/appshot.sh feed [DEVICE]          # stream the display into a v4l2loopback device
tool/appshot.sh unfeed                 # stop that stream
tool/appshot.sh watch                  # (re)open the VNC viewer
tool/appshot.sh deps                   # check dependencies, print the apt line
tool/appshot.sh status                 # state of every moving part
tool/appshot.sh quit                   # tear down viewer, VNC, feed, app, WM, display
```

`status` reports `display= screen= wm= running= window= vnc= input= viewer=
feed= session=`. `viewer=` is a live TCP connection to the VNC port, not a
process we started — remmina hands off to its own daemon and exits, so its pid
proves nothing. `screen=` is the running Xvfb geometry, `input=` the mode the
VNC server was started in, and `session=` whether a remembered session (below)
is supplying defaults.

### State directory

Everything a display's session owns lives in
`${TMPDIR:-/tmp}/brainframe-appshot-<N>` — `/tmp/brainframe-appshot-99` for
`:99`. That is where to look when something fails:

| File | What it is | Look here when… |
| --- | --- | --- |
| `run.log` | `flutter run` output: build errors, Dart exceptions, the app's console | the window never appears, or the app misbehaves |
| `xvfb.log` / `wm.log` | Xvfb and openbox output | `display up` never prints; the window is decorated or off-origin |
| `x11vnc.log` / `x11vnc.mode` | VNC server output; the `APPSHOT_INPUT` it was started with | `watch` says it did not listen; typing in remmina does nothing |
| `viewer.log` | remmina launcher output | the tab never opens |
| `feed.log` / `feed.dev` | ffmpeg output; the device it writes to | OBS shows black; `feed` exits at once |
| `session.env` | the settings the last `launch` ran with | a bare `launch` opened the wrong engram or size |
| `maim.err` | the last screenshot error | `shot` fails |
| `*.pid` | app, Xvfb, WM, x11vnc, feed pids | `status` disagrees with reality |

`run.log` is overwritten on every `launch`, so copy it before relaunching if a
run went wrong.

### The display remembers its session

`launch` writes the settings it ran with — `APPSHOT_WIN_W/H`, `APPSHOT_SCREEN`,
`APPSHOT_WM`, `APPSHOT_VIEW`, `APPSHOT_INPUT`, `APPSHOT_VNC_PORT`,
`APPSHOT_TITLE`, `APPSHOT_ENGRAM`, `APPSHOT_V4L2`, `APPSHOT_FEED_FPS`, and
`XDG_DATA_HOME` — to `session.env`, and every later command on that display
reads them back as **defaults**. Anything set in the environment still wins;
the file only fills gaps. `quit` removes it. So after the first fully-specified
`launch`, the restart cycle is just:

```bash
APPSHOT_DISPLAY=:99 tool/appshot.sh stop
APPSHOT_DISPLAY=:99 tool/appshot.sh launch
```

`APPSHOT_DISPLAY` is the one variable that must always be passed — it is how
the state dir, and therefore everything else, is found.

- Capturing subcommands print the PNG path on stdout.
- **Coordinates are 1:1.** The window is moved to the origin at a fixed
  1600×1000 and GDK scaling is pinned to 1, so image pixel == window pixel ==
  the `(X,Y)` you pass. No HiDPI or display-scale arithmetic anywhere. Override
  with `APPSHOT_WIN_W` / `APPSHOT_WIN_H`, the screen with `APPSHOT_SCREEN`
  (`fit` makes it exactly the window), and the display with `APPSHOT_DISPLAY`
  to run two sessions at once — the state dir, VNC port default, and every
  process lookup are scoped to the display, so `stop`/`quit`/`status` on one
  never touch the other.
- **Placement is read back.** After `launch` parks the window it re-reads the
  geometry and warns if the toolkit clamped the request (the app has a 640×480
  minimum); nothing silently ends up a different size than asked.
- Pointer moves are **verified**: `click` and `hover` confirm the pointer
  actually arrived and fail loudly if it did not. A silent miss is what made the
  previous incarnations of this tool untrustworthy — never reintroduce one.
- Give the app a few seconds after `launch` before capturing, or you will grab a
  loading spinner.
- Do launch / drive / verify / quit **only** through these subcommands — never a
  bare `pkill` / `pgrep` / `xdotool` — so nothing escapes the one allow rule.

## Permissions

So the tool runs without a prompt per invocation, allowlist it in your
**personal, git-ignored** `.claude/settings.local.json` (not the shared
`settings.json`):

```json
{ "permissions": { "allow": ["Bash(tool/appshot.sh *)"] } }
```

That single rule covers every subcommand, including the self-cleaning `quit`.

## Recording a demo

The same isolation makes the private display the right stage for a screen
recording, because the live Wayland session works against you twice: the
compositor scales every window by the output scale (150 % here, so a 1080-px
request lands as 1620 physical pixels) and re-places it on every launch, and an
OBS window capture is bound to one window — it goes dark when that window
closes and does not re-attach to the relaunched one. On Xvfb the display is
unscaled, the window sits at the origin at a fixed size, and the display
outlives the app.

```bash
export APPSHOT_WIN_W=1080 APPSHOT_WIN_H=640 APPSHOT_SCREEN=fit APPSHOT_INPUT=1
APPSHOT_DISPLAY=:99 APPSHOT_ENGRAM=/tmp/engramA APPSHOT_TITLE='BrainFrame A' \
  XDG_DATA_HOME=/tmp/deviceA tool/appshot.sh launch
APPSHOT_DISPLAY=:99 tool/appshot.sh feed /dev/video10
# …and the same on :98 with engramB / deviceB / video11
```

- `APPSHOT_SCREEN=fit` sizes the Xvfb screen to the window, so a capture of the
  display *is* the window with nothing to crop. An Xvfb screen cannot be
  resized once up, so when a size is specified and a display of another size
  is already running, `launch` (and every driving subcommand) refuses with
  "run `quit` first" rather than let the capture silently disagree with the
  window. With no size specified, whatever is up is accepted.
- `feed` runs `ffmpeg -f x11grab` over the whole display into a v4l2loopback
  device, which OBS reads as a plain *Video Capture Device*. The source keeps
  existing while the app behind it is stopped and relaunched. Two instances,
  two displays, two devices.
- `stop` quits **only the app** — first through its own Ctrl+Q so unsaved edits
  flush through the normal close path, escalating to signals only if it does
  not exit — and leaves the display, WM, VNC server, remmina tab and feed
  running. That is the restart point: `stop`, do something in a terminal,
  `launch`, and the next instance lands in exactly the same pixels — with only
  `APPSHOT_DISPLAY` on the command line, since the display remembers the rest.
- `APPSHOT_ENGRAM` opens a folder of your own instead of the fixture
  (`--ignore-config` stays on), `APPSHOT_TITLE` passes `--window-title` and is
  also how the script finds the window, and `XDG_DATA_HOME` passes straight
  through to the app — the usual way to give two instances two device stores.
- `feed` needs `ffmpeg` and the `v4l2loopback` module, and it will **not**
  `modprobe` for you. Loading a module needs root; a script that can `sudo`
  under the blanket allow rule above would be a root grant rather than a tool,
  and it would hang on a password prompt when Claude runs it. It is a one-time,
  machine-level step anyway — `feed` prints the exact `modprobe` line and the
  `/etc/modules-load.d` + `/etc/modprobe.d` files that make it survive a
  reboot.

## Safety

The app is always launched with `--ignore-config` and, unless `APPSHOT_ENGRAM`
says otherwise, `--engram test/fixtures/engram`, so it opens the committed
manual-testing fixture backed by an ephemeral in-memory config store and an
empty temporary engram container. It never reads or writes the real app config
or your real engrams, so **destructive flows are safe to drive** — rename,
delete, and create are all fair game. Restore the fixture afterwards with
`git checkout -- test/fixtures/engram`; the app's own `.brainframe/shared/`
store inside it is git-ignored.

That container swap is what makes a screenshot safe to publish: without it,
`--ignore-config` still scanned the real app documents directory, so the engram
switcher named every engram you own in any capture of it. If you are on an older
build, check a switcher shot before you share it.
