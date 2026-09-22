# Linux AppImage packaging

BrainFrame ships on Linux as an [AppImage][appimage] — a single executable
file that runs on most desktop distributions with no install step. It is built
by [`tool/appimage/build-appimage.sh`](../tool/appimage/build-appimage.sh),
locally or from the tag-triggered [`release`](../.github/workflows/release.yml)
workflow. A Pi with no desktop environment gets a different AppImage, built
around flutter-pi — see [below](#raspberry-pi-without-a-desktop-flutter-pi).

## The FUSE 2 vs FUSE 3 problem (and how we avoid it)

A classic AppImage embeds a small runtime that mounts the app's squashfs image
using **libfuse.so.2** (FUSE 2). Ubuntu 24.04 and later no longer ship that
library, so a classic AppImage fails there with a `libfuse.so.2` error unless
the user manually installs `libfuse2`. We sidestep this at both ends:

- **Produced AppImage — embeds the static `type2-runtime`.** Instead of the
  classic runtime, we pass a pinned [type2-runtime][type2] to `appimagetool`
  via `--runtime-file`. That runtime statically links squashfuse and needs only
  the kernel `fuse` module plus a `fusermount`/`fusermount3` helper — both
  present on essentially every desktop Linux. The app therefore self-mounts on
  **FUSE 2** hosts (e.g. Ubuntu 22.04) *and* **FUSE 3** hosts (24.04, 26.04)
  with no `libfuse2` install required.
- **Build time — `APPIMAGE_EXTRACT_AND_RUN=1`.** The build tools (`linuxdeploy`,
  `appimagetool`) are themselves AppImages, so running them would also want
  FUSE. The script exports `APPIMAGE_EXTRACT_AND_RUN=1`, which makes them
  self-extract instead of mounting. No FUSE of either version is needed to
  *build* — on a GitHub runner or on a dev box mid-upgrade from 24.04 to 26.04.

If an end user somehow has no FUSE at all (a minimal container, say), the
AppImage still runs with the universal fallback:

```bash
./BrainFrame-<version>-x86_64.AppImage --appimage-extract-and-run
```

## Building locally

```bash
flutter build linux --release
tool/appimage/build-appimage.sh
```

The script prints the path of the finished `.AppImage` (under `build/appimage/`)
as its only stdout line; all logging goes to stderr. It needs `curl`,
`patchelf`, `file`, and `desktop-file-utils` on `PATH`:

```bash
sudo apt install patchelf desktop-file-utils file
```

## Raspberry Pi (aarch64)

The same script produces the AppImage for a Raspberry Pi — one **aarch64**
build serves every ARMv8 Pi (3, 4, 5). Two things follow from how it is made:

- **It is built on the Pi.** Flutter does not cross-compile Linux desktop
  bundles, and `linuxdeploy`/`appimagetool` are native binaries, so the build
  runs on an aarch64 host. `--arch` defaults to the host's architecture
  (`uname -m`), and the script refuses a mismatch up front rather than letting
  it surface later as an `Exec format error`. A Pi 4 with the Flutter Linux
  toolchain installed is the intended build box; the same two commands apply:

  ```bash
  flutter build linux --release
  tool/appimage/build-appimage.sh      # → build/appimage/BrainFrame-<version>-aarch64.AppImage
  ```

- **The Pi must run a 64-bit OS.** Flutter has no 32-bit ARM (`armhf`) Linux
  desktop target, so there is no armhf AppImage. Raspberry Pi OS 64-bit
  supports the Pi 3 and later; a Pi 3 on the 32-bit image cannot run this
  build at all. Copy the file from the Pi 4 to the Pi 3 (or any other 64-bit
  Pi) and run it as on any Linux desktop.

The result carries the build host's glibc as a floor: an AppImage built on
Raspberry Pi OS runs on that release and newer, not on an older one. Build on
the oldest OS release you mean to run on.

## Raspberry Pi without a desktop (flutter-pi)

The AppImage above needs a desktop: its embedder is GTK, which needs X11 or
Wayland underneath. A Pi with no desktop environment — Raspberry Pi OS Lite, a
kiosk, the e-ink target — runs BrainFrame through [flutter-pi][flutter-pi]
instead, an embedder that opens the display through DRM/KMS and reads input
through libinput, with nothing X11, Wayland or GTK involved.
[`tool/appimage/build-flutterpi-appimage.sh`](../tool/appimage/build-flutterpi-appimage.sh)
packages that.

Its input is a [`flutterpi_tool`][flutterpi_tool] bundle. `flutterpi_tool`
cross-compiles from any host, so this is one command on the desktop:

```bash
flutter pub global activate flutterpi_tool   # flutter, not dart: it needs the Flutter SDK
flutterpi_tool build --arch=arm64 --cpu=pi3 --release
tool/appimage/build-flutterpi-appimage.sh --arch arm64 --cpu pi3
#   → build/appimage/BrainFrame-<version>-flutterpi-pi3-64.AppImage
```

Two things about that activation, both learned the hard way:

- **`flutter pub global`, not `dart pub global`.** `flutterpi_tool` links
  Flutter's own `flutter_tools`, which `dart pub` cannot supply; the wrapper
  it writes fails at every run with *"requires the Flutter SDK, which is
  unsupported for global executables"*. Re-activating does **not** replace a
  wrapper that already exists — pub says so in passing — so if `dart` was
  used once, `flutter pub global deactivate flutterpi_tool` first.
- **It compiles against the installed Flutter SDK's internals**, so each
  `flutterpi_tool` release supports a range of Flutter versions and a newer
  SDK breaks the build with errors deep in `flutter_tools` (`Couldn't find
  constructor 'DartBuildForNative'` and the like). When the pub.dev release
  trails your SDK, activate from upstream `main`, pinned to a commit:

  ```bash
  flutter pub global deactivate flutterpi_tool
  flutter pub global activate -sgit https://github.com/ardera/flutterpi_tool --git-ref <sha>
  ```

  Re-activate after every Flutter upgrade either way; a stale snapshot fails
  the same way.

`--arch`/`--cpu` take `flutterpi_tool`'s own spellings and default to
`arm64`/`pi3`; the script finds the bundle at `build/flutter-pi/<target>` from
them (`pi3-64`, `pi4-64`, `aarch64-generic`, …), or take `--bundle DIR`. The
target name is kept in the file name because it says which **engine tuning**
is inside: `flutterpi_tool` builds an engine tuned for the CPU you name, and
one tuned for a Pi 3 is not expected to run on a Pi 4, or vice versa. A
`--cpu=generic` build runs on any Pi of that architecture.

### Why this one builds on the desktop

Unlike the desktop AppImage, this one does **not** run `linuxdeploy`, and so
needs no aarch64 host. The libraries flutter-pi links fall into two groups,
neither of which is bundled:

- **The Mesa stack** (`libEGL`, `libGLESv2`, `libgbm`, `libdrm`) has to be the
  Pi's own. `libgbm` and `libEGL` `dlopen` the DRI driver for the GPU they are
  running on (`vc4`/`v3d` on a Pi), and a copy carried in from another machine
  does not match it. This is the same reason `linuxdeploy` refuses to bundle
  them on the desktop.
- **The rest** are ordinary distro packages that a Pi already running
  flutter-pi has. On Raspberry Pi OS:

  ```bash
  sudo apt install libdrm2 libgbm1 libegl1 libgles2 libgl1-mesa-dri \
    libinput10 libudev1 libxkbcommon0 libsystemd0 libvulkan1 libatomic1 \
    libgstreamer1.0-0 libgstreamer-plugins-base1.0-0 libglib2.0-0
  ```

  (That is the `NEEDED` list of the `flutter-pi` binary `flutterpi_tool`
  ships, mapped to package names. GStreamer is linked, not used — flutter-pi
  is built with its video-player support in, and the loader wants the
  libraries present either way.)

With nothing to bundle, the only native tool left is `appimagetool`, which
only packs a squashfs and takes the target architecture from `$ARCH`. So the
script fetches `appimagetool` for the **host** and the static runtime for the
**target**, and an x86_64 desktop produces a valid aarch64 AppImage. The
`flutterpi_tool` bundle is copied under `usr/lib/brainframe/` **whole and
untouched**: flutter-pi looks for `libflutter_engine.so` beside the assets it
is handed. The script refuses a bundle whose manifest does not list
`libsqlite3.so` — that is the native-asset step not having run, and the
failure it would ship is the silent one described under
[How it works](#how-it-works).

That library has a catch of its own. The manifest lists it as
`["relative", "./libsqlite3.so"]`, and the engine resolves `relative` against
the isolate's *advisory script URI* — which an embedder-API host like
flutter-pi leaves at the engine's default, a bare `main.dart` with no
directory. With no directory to merge in, the VM keeps the path as given,
and its dot-segment removal does not strip a leading `./` (it compares three
bytes, so only the exact string `./` matches). What reaches `dlopen()` is
therefore `./libsqlite3.so` — relative to the process's **working
directory**, not to the bundle, and never searched on any library path. The
failure reads `Failed to load dynamic library './libsqlite3.so' relative to
'main.dart'`, and it is an unhandled exception in the CRDT session, so the
app comes up with no `metadata.db`. A bundle run by hand works only because
one runs it from inside the bundle. The launcher therefore starts flutter-pi
with the bundle as its working directory (and puts the bundle on
`LD_LIBRARY_PATH` too, for a VM that one day collapses the path to a bare
name). One consequence: **a file path in `BRAINFRAME_ARGS` must be absolute**,
or it resolves inside the read-only image.

### Running it

Run it **from a login on the Pi's own console** (or a systemd unit — see
below), **not** from inside a desktop session and preferably not over SSH,
as a user in the `video`, `render` and `input` groups. Which console it is
launched from matters, for a reason given under [Keystrokes and the
console](#keystrokes-and-the-console). Arguments before a literal `--` are
flutter-pi's own options; arguments after it go to the **engine** as
switches:

```bash
./BrainFrame-0.0.1-flutterpi-pi3-64.AppImage                       # just run it
./BrainFrame-0.0.1-flutterpi-pi3-64.AppImage -r 90                 # rotate the UI
./BrainFrame-0.0.1-flutterpi-pi3-64.AppImage --videomode 1280x720
./BrainFrame-0.0.1-flutterpi-pi3-64.AppImage -- --old-gen-heap-size=128
```

**The app's own options do not go on the command line at all.** flutter-pi
passes nothing to the Dart entrypoint — `main(args)` gets an empty list, and
an app option after `--` is just an unknown engine switch, ignored. The app
therefore reads `BRAINFRAME_ARGS` from the environment on every platform,
whitespace-separated, ahead of whatever `argv` it was given:

```bash
BRAINFRAME_ARGS="--engram /home/pi/notes" ./BrainFrame-0.0.1-flutterpi-pi3-64.AppImage
```

When the app dies during the open-time scan — the OOM killer on a 512 MB
board names the process and nothing else — `--trace-scan` narrates the scan
on stderr, one line per note *before* the note is touched, so the last line
is the file it died on:

```bash
BRAINFRAME_ARGS="--trace-scan" ./BrainFrame-0.0.1-flutterpi-pi3-64.AppImage 2>scan.log
```

`FLUTTER_PI=/path/to/flutter-pi` runs a flutter-pi of your own against the
bundled engine and app, for a build without GStreamer, say. The FUSE notes
above apply unchanged: the static runtime needs only the kernel `fuse` module
and `fusermount3`, and `--appimage-extract-and-run` is the fallback without
them.

### Keystrokes and the console

flutter-pi reads the keyboard through libinput, straight from evdev, and
never tells the kernel's virtual terminal that it has taken the keyboard
over. So the VT keeps translating every key press and queuing the characters
on the console's tty **in parallel**. Nothing reads them while the app runs;
the moment it exits, whatever owns that console — the shell you launched
from, or a login prompt — reads the lot and acts on it. A username and
password typed into a note become a login on tty1. Ctrl+C typed into a text
field reaches the same tty and kills the app. This is
[flutter-pi issue #298][flutterpi-298], open since 2022; the durable fix
belongs there.

Until it lands, the AppImage closes the hole itself. The launcher runs
flutter-pi under a small guard
([`flutterpi-console-guard.py`](../tool/appimage/flutterpi-console-guard.py))
that does what every KMS compositor does: it puts the controlling VT's
keyboard into **`K_OFF`** (the `KDSKBMODE` ioctl), under which the kernel
discards key events before they become characters, and restores the previous
mode when the app exits. libinput is untouched, so the app still sees every
key. Consequences worth knowing:

- **Launch from a login on the console itself.** The guard configures the VT
  through the controlling terminal, which needs no privileges when that is
  the console you logged in on. Over SSH the controlling terminal is a pty,
  the keyboard belongs to whatever is on the Pi's screen (usually a login
  prompt), and the guard cannot reach it without `CAP_SYS_TTY_CONFIG`. It
  then **prints a warning and runs the app anyway** — read stderr.
- **Ctrl+Alt+Fn cannot switch consoles while the app runs.** That is the
  kernel's `K_OFF`, not a choice here. Quit the app, or come in over SSH.
- **If the guard is killed outright** (SIGKILL, an OOM kill on a small
  board) the mode is not restored and the console's keyboard stays dead.
  From another machine: `sudo kbd_mode -u -C /dev/tty1`.
- It needs `python3`, which Raspberry Pi OS ships, Lite included. Without it
  the launcher warns and runs unguarded. `BRAINFRAME_CONSOLE_GUARD=0` skips
  the guard deliberately, for debugging it.

For an appliance, a systemd unit that owns the console is the tidiest shape:
no getty, so there is no shell for keystrokes to fall into even if the guard
could not run, and `TTYPath=` makes the console the controlling terminal so
that it can.

```ini
[Unit]
Description=BrainFrame (flutter-pi)
Conflicts=getty@tty1.service
After=systemd-user-sessions.service

[Service]
User=pi
TTYPath=/dev/tty1
StandardInput=tty
Environment=BRAINFRAME_ARGS=--engram /home/pi/notes
ExecStart=/home/pi/BrainFrame-0.0.1-flutterpi-pi3-64.AppImage
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

## How it works

1. **Assemble an AppDir.** The Flutter release bundle is copied under
   `usr/bin/` so the binary keeps its `data/` and `lib/` siblings (the engine
   loads its libraries via an `$ORIGIN/lib` rpath). The `.desktop` entry
   ([`linux/packaging/`](../linux/packaging/)) and the
   [`brainframe.png`](../brainframe.png) icon are installed into the usual
   `usr/share` locations.
2. **Write the AppRun hook, then bundle dependencies with `linuxdeploy` + the
   GTK plugin.** `linuxdeploy` pulls the app's GTK/glib dependency tree into
   `usr/lib` and patches library paths, so the result runs on distributions
   with different GTK builds. That rewrite turns the binary's `$ORIGIN/lib`
   rpath into `$ORIGIN/../lib`, which is fine for everything the binary
   *links* — the dependency walk copies those into `usr/lib` — but not for
   what Dart opens **at run time by name**: `libsqlite3.so`, the native asset
   the `sqlite3` package ships, stays in `usr/bin/lib` on no search path. The
   hook (`apprun-hooks/10-flutter-libs.sh`) prepends that directory to
   `LD_LIBRARY_PATH`. **It must exist before `linuxdeploy` runs**: the
   generated `AppRun` sources each hook present at generation time, by name,
   and never globs the directory. A hook written afterwards ships in the
   AppImage and is never sourced — which is how a whole release opened every
   engram with no `metadata.db`, no scan, and no error, since a session that
   cannot open its database comes up null. The script now checks that
   `AppRun` names the hook and fails the build if it does not.
3. **Package with the static runtime.** `appimagetool --runtime-file` writes the
   final AppImage using the FUSE 2/3-safe runtime described above.

### Version metadata

The version comes from `pubspec.yaml` and reaches the artifact in two places:
the **file name**, and an `X-AppImage-Version` key that `appimagetool` injects
into the embedded `.desktop` entry. Only the second one counts — AppImage
managers (AppImageLauncher, AppMan, Gear Lever, …) read that key to report an
installed app's version, and they rename files freely, so the name proves
nothing.

`appimagetool` picks it up from the **environment**, which is why the script
`export`s `VERSION` rather than just setting it. Miss the export and nothing
fails: the build succeeds, the AppImage runs, the file name still carries the
number, and the app simply shows up in every manager with no version at all.
Check it after any change to the packaging step:

```bash
./BrainFrame-0.0.1-x86_64.AppImage --appimage-extract >/dev/null
grep X-AppImage-Version squashfs-root/*.desktop
```

Do **not** add the version to the checked-in `.desktop` file to fix this. The
`Version=` key there means the *desktop-entry spec* version, not the app's, and
a hand-written `X-AppImage-Version` would be a second source of truth that
drifts from `pubspec.yaml` the first time someone bumps one and not the other.

## Reusing the script

Everything project-specific is a variable with a repo-derived default that an
environment variable or flag can override: `APP_NAME`, `BIN_NAME` (read from
`linux/CMakeLists.txt`), `APP_ID`, `VERSION` (from `pubspec.yaml`, or the tag in
CI), `ICON`, `DESKTOP_FILE`, `ARCH` (from `uname -m`), and `OUTPUT`. Run
`tool/appimage/build-appimage.sh --help` for the full list.

## Bumping the pinned tools

`linuxdeploy`, its GTK plugin, `appimagetool`, and the runtime publish only
rolling `continuous` releases, so the **sha256 checksum is the real pin**: if
upstream republishes an asset, verification fails and we bump the hash on
purpose. Both build scripts read the pins from one table in
[`tool/appimage/common.sh`](../tool/appimage/common.sh). The pins are per
architecture (`x86_64` and `aarch64` assets are separate uploads that move
independently); the GTK plugin is a shell script, the same bytes everywhere,
so it is pinned once under `any`. `linuxdeploy` and `appimagetool` run on the
build host, so they are pinned for host architectures; the runtime is
embedded in the result, so it is pinned for every target, `armhf` included.

**Verify before you bump.** A failed check means the bytes changed; it does not
say *why*. Copying whatever just downloaded into the table turns the pin into
theatre — it would accept a corrupted transfer or a substituted artifact just as
readily as a legitimate rebuild. Ask GitHub what it is serving, independently of
the bytes you received:

```bash
gh api repos/linuxdeploy/linuxdeploy/releases/tags/continuous \
  --jq '.assets[] | select(.name=="linuxdeploy-x86_64.AppImage") | {digest, size, updated_at}'
```

(For the aarch64 pins, the asset names are `linuxdeploy-aarch64.AppImage`,
`appimagetool-aarch64.AppImage`, and `runtime-aarch64`.)

The `digest` must equal the sha256 the build printed, and `updated_at` should
show a republish that plausibly explains the change. Only then bump the hash in
the `SHA256` table in `common.sh`, and say in the commit what you checked. The
other pins are worth a glance at the same time — a single moved asset is
routine, several at once is worth a harder look.

Also worth knowing what this can and cannot tell you: the digest confirms your
download matches the official asset GitHub is serving. It does **not** attest
that the new build is trustworthy — `continuous` is a rolling tag rebuilt from
upstream CI, so its contents change by design. That residual trust in upstream
is inherent to pinning a rolling release, not something the checksum removes.

To bootstrap a pin that does not exist yet, run once allowing an unpinned
download and pin the printed hashes after verifying them the same way:

```bash
APPIMAGE_ALLOW_UNPINNED=1 tool/appimage/build-appimage.sh
```

[appimage]: https://appimage.org/
[type2]: https://github.com/AppImage/type2-runtime
[flutter-pi]: https://github.com/ardera/flutter-pi
[flutterpi-298]: https://github.com/ardera/flutter-pi/issues/298
[flutterpi_tool]: https://pub.dev/packages/flutterpi_tool
