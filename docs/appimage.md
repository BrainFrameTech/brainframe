# Linux AppImage packaging

BrainFrame ships on Linux as an [AppImage][appimage] — a single executable
file that runs on most desktop distributions with no install step. It is built
by [`tool/appimage/build-appimage.sh`](../tool/appimage/build-appimage.sh),
locally or from the tag-triggered [`release`](../.github/workflows/release.yml)
workflow.

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

## How it works

1. **Assemble an AppDir.** The Flutter release bundle is copied under
   `usr/bin/` so the binary keeps its `data/` and `lib/` siblings (the engine
   loads its libraries via an `$ORIGIN/lib` rpath). The `.desktop` entry
   ([`linux/packaging/`](../linux/packaging/)) and the
   [`brainframe.png`](../brainframe.png) icon are installed into the usual
   `usr/share` locations.
2. **Bundle dependencies with `linuxdeploy` + the GTK plugin.** This pulls the
   app's GTK/glib dependency tree into the AppDir and patches library paths, so
   the result runs on distributions with different GTK builds. An AppRun hook
   (`apprun-hooks/10-flutter-libs.sh`) prepends the engine-library directory to
   `LD_LIBRARY_PATH` as a deterministic guard, independent of how `linuxdeploy`
   rewrites rpaths.
3. **Package with the static runtime.** `appimagetool --runtime-file` writes the
   final AppImage using the FUSE 2/3-safe runtime described above.

## Reusing the script

Everything project-specific is a variable with a repo-derived default that an
environment variable or flag can override: `APP_NAME`, `BIN_NAME` (read from
`linux/CMakeLists.txt`), `APP_ID`, `VERSION` (from `pubspec.yaml`, or the tag in
CI), `ICON`, `DESKTOP_FILE`, `ARCH`, and `OUTPUT`. Run
`tool/appimage/build-appimage.sh --help` for the full list.

## Bumping the pinned tools

`linuxdeploy`, its GTK plugin, `appimagetool`, and the runtime publish only
rolling `continuous` releases, so the **sha256 checksum is the real pin**: if
upstream republishes an asset, verification fails and we bump the hash on
purpose. To refresh a pin, run once allowing an unpinned download and copy the
printed hashes into the `SHA256` table at the top of the script:

```bash
APPIMAGE_ALLOW_UNPINNED=1 tool/appimage/build-appimage.sh
```

[appimage]: https://appimage.org/
[type2]: https://github.com/AppImage/type2-runtime
