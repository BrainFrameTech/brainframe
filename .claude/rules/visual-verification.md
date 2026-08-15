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
- There is **no window manager**. Focus therefore cannot go through EWMH
  (`xdotool windowactivate`); the script uses `xdotool windowfocus`, a direct
  `XSetInputFocus`, which needs no WM.

## Requirements

```bash
sudo apt install xvfb x11-utils xdotool maim
```

Plus the Flutter Linux desktop toolchain (already needed to build the app). No
graphical session is required — this works over SSH and in CI.

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
tool/appshot.sh status                 # print "display=<0|1> running=<n> window=<n>"
tool/appshot.sh quit                   # terminate the app and the display
```

- Capturing subcommands print the PNG path on stdout.
- **Coordinates are 1:1.** The window is moved to the origin at a fixed
  1600×1000 and GDK scaling is pinned to 1, so image pixel == window pixel ==
  the `(X,Y)` you pass. No HiDPI or display-scale arithmetic anywhere. Override
  with `APPSHOT_WIN_W` / `APPSHOT_WIN_H`, the screen with `APPSHOT_SCREEN`, and
  the display with `APPSHOT_DISPLAY` (to run two sessions at once).
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

## Safety

The app is always launched with `--engram test/fixtures/engram` and
`--ignore-config`, so it opens the committed manual-testing fixture backed by an
ephemeral in-memory config store. It never reads or writes the real app config
or your real engrams, so **destructive flows are safe to drive** — rename,
delete, and create are all fair game. Restore the fixture afterwards with
`git checkout -- test/fixtures/engram`.
