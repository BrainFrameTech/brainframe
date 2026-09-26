# Adopting a folder on the sandboxed platforms

- **Status:** accepted (2026-09-26) — reviewed in **#207**
- **Author:** Claude
- **Date:** 2026-09-26
- **Issue:** **#94**
- **Companion to:** [engram-storage.md](engram-storage.md), whose
  "Location B" and v2 phase this designs, and whose Decision 2 it amends

## TL;DR

"Open folder…" adopts any directory as an engram, but only on Linux and
Windows today, where the folder dialog hands back a plain path. This design
brings it to Android, iOS and macOS **without changing anything above the
path**: every platform still ends with an absolute directory that `dart:io`
can read and write, so the store, the identity map, the drift reconciler,
folder preview and the watcher all work unchanged.

- **Android asks for All files access** (`MANAGE_EXTERNAL_STORAGE`) and maps
  the folder the system picker returns to its real `/storage/…` path. It does
  **not** build a Storage Access Framework store.
- **iOS and macOS keep a security-scoped bookmark** in the registry row and
  resolve it at each launch. Once access is started the URL's path is an
  ordinary path. macOS is included because its build is sandboxed, which
  desktop adoption has so far ignored.
- **One Dart seam, `FolderAccess`,** picks, resolves and asks for permission.
  A plain-path implementation serves Linux and Windows; one platform channel
  serves Android, iOS and macOS.
- **The registry row gains an optional opaque `bookmark`.** Existing rows,
  which lack it, are read exactly as before.
- **An engram that is unreachable says why:** its folder is missing, or the
  app has lost permission to reach it. The second is fixed from the switcher
  by granting access, not by adopting it again.
- The Apple half is **written but unverified** until a Mac and an iPhone are
  available, as the storage design's Decision 3 already allows.

## Why a path everywhere

The storage design's key move was that Location A and Location B "differ
only in how you obtain a directory handle". That turns out to be more than
an ideal: well beyond `FileSystemEngramStore`, the code reaches the engram
folder through `dart:io` paths.

- The identity map writes `.brainframe/shared/` by temp file and rename.
- The drift reconciler checks the root exists.
- Folder preview walks the tree.
- The marker and per-engram settings are written atomically.
- The watcher design (#204) watches the folder with inotify.

Any access kind that does not end in a path means lifting all of those off
`dart:io`, not only the store.

### Android: All files access, not the Storage Access Framework

SAF hands back a `content://` tree URI, reached through a `ContentResolver`
rather than a path. Building on it was considered and rejected:

- **It is slow for this workload.** Every list, stat and read is an IPC
  call to the documents provider with a permission check. A drift scan stats
  every file on every open and resume.
- **It cannot be watched.** There is no inotify over a tree URI, and a
  `ContentObserver` on external storage is unreliable. The watcher design
  (#204) would fall back to polling on exactly the platform where a sync tool
  (Syncthing, Dropsync) is most likely to be writing the folder.
- **It cannot rename over an existing file,** so the marker and identity map
  writes stop being atomic. The identity map is shared between devices, and
  a torn write there is a correctness problem, not a cosmetic one.
- **It needs a second implementation** of the store, the identity map,
  preview and the watcher, all to reach the same bytes.

Obsidian's Android app reached the same conclusion for the same reasons
(slow per-file checks, no change notification) and asks for All files access.
Google Play lists "document management" among the permitted uses of
`MANAGE_EXTERNAL_STORAGE`. The permission is current, not deprecated; the
cost is a declaration form at Play review, which sideloaded and F-Droid builds
do not face.

What SAF would buy and this design gives up: folders offered by cloud
document providers (Google Drive, Dropbox), and use without a special
permission. Both are recorded under *Not decided here*.

### iOS and macOS: bookmarks already end in a path

A folder picked through `UIDocumentPickerViewController` (iOS) or
`NSOpenPanel` (sandboxed macOS) arrives as a security-scoped URL. After
`startAccessingSecurityScopedResource()`, its `path` is readable and writable
with POSIX calls, and so with `dart:io`. The only native work is getting that
access back in a later launch, which is what a bookmark is for. Nothing
above the path changes.

## Decisions

### Decision 1 — every access kind ends in an absolute path

`EngramLocation` stays a plain path. Neither a bookmark nor an Android
permission becomes part of it: they are how the path is *reached*, which
belongs to the registry row and the `FolderAccess` seam. `openFileSystemEngram`
and everything after it are untouched.

This keeps the storage design's rule that `EngramLocation` is "a plain value
with no `dart:io` dependency" and closes the question its comment leaves
open ("later access kinds … slot in behind this same type"): they slot in
*in front of* it.

### Decision 2 — `FolderAccess`, one seam for pick, resolve and permission

```dart
abstract class FolderAccess {
  /// Whether this platform can pick a folder at all.
  bool get canPick;

  /// Shows the platform's folder chooser. Null when the user cancels.
  Future<PickedFolder?> pick();

  /// Turns a stored row back into a usable path, starting access if the
  /// platform needs it. Throws [FolderAccessException] with a reason.
  Future<ResolvedFolder> resolve({required String path, String? bookmark});

  /// Whether the app may reach folders outside its container right now,
  /// and a way to ask. Always granted where no permission exists.
  Future<bool> get hasBroadAccess;
  Future<bool> requestBroadAccess();
}

class PickedFolder   { String path; String? bookmark; }
class ResolvedFolder { String path; String? refreshedBookmark; }
```

Two implementations:

| Implementation | Platforms | `pick` | `resolve` | broad access |
| --- | --- | --- | --- | --- |
| `PathFolderAccess` | Linux, Windows | `file_selector` dialog | returns the path | always granted |
| `ChannelFolderAccess` | Android, iOS, macOS | native channel | native channel | Android: the permission; Apple: always granted |

The channel is `tech.brainframe.app/folder_access`, written in the app's own
Kotlin and Swift, not a third-party plugin. It is small, and no plugin covers
both the Android path mapping and bookmark resolution (the storage design
already expected "a small Swift platform channel").

`pickAndAdoptFolder` takes a `FolderAccess` instead of today's
`DirectoryPicker`. `isDesktopFolderAdoptionSupported` becomes
`folderAccess.canPick`, and `desktop_folder_adoption.dart` is renamed
`folder_adoption.dart`. Tests inject a fake `FolderAccess`, which covers
every Dart branch without a device.

The Raspberry Pi is Linux to Flutter, but flutter-pi has no dialog. It
keeps today's behaviour, and its in-app browser remains the Pi-usability
work's to build. It would be another `FolderAccess`.

### Decision 3 — the registry row carries an opaque bookmark

```json
{"id": "01J…", "displayName": "Notes", "path": "/…/Notes", "bookmark": "…"}
```

- `bookmark` is optional, base64 and **opaque to Dart**. It is written only
  on iOS and macOS. Rows from before this change have none and resolve as a
  plain path, which is what they are.
- `path` is kept on every row. On Apple it is the *last resolved* path: shown
  in Housekeeping, used in log lines, and refreshed whenever resolution
  returns a different one. A folder moved within its volume keeps working,
  because the bookmark follows it; the row follows the bookmark.
- A **stale** bookmark (the system says so on resolve) is re-created on the
  spot and written back to the row. The native side returns it as
  `refreshedBookmark`.
- The key stays `engram.registry.v1`. The change is additive, and an older
  build reading a new row ignores the field. It resolves the path, which on
  macOS will fail as unavailable rather than misbehave.

### Decision 4 — Android: the permission, the picker, and the mapping

- **API 30 and up:** `MANAGE_EXTERNAL_STORAGE`, granted on the system's
  *All files access* screen (`ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION`).
  The result is not returned to the caller, so it is read again with
  `Environment.isExternalStorageManager()` when the app resumes.
- **API 24–29:** `READ_`/`WRITE_EXTERNAL_STORAGE` as a runtime permission
  (declared with `maxSdkVersion="29"`), plus `requestLegacyExternalStorage`
  for API 29, where scoped storage is otherwise already on.
- **The picker is the system's** `ACTION_OPEN_DOCUMENT_TREE`, since it is
  familiar and knows the device's volumes. Only its answer is used, never the
  URI grant: the tree URI's authority must be
  `com.android.externalstorage.documents`, and its document id
  `<volume>:<relative>` maps to a path. `primary` is the primary shared
  storage (`Environment.getExternalStorageDirectory()`), and any other volume
  id is matched against `StorageManager.getStorageVolumes()`. A folder from any
  other provider (Drive, Downloads' virtual root) is refused with a message
  that names the reason. No persistable URI permission is taken.
- **Asking comes first.** "Open folder…" checks broad access before showing
  the picker. Without it, a short in-app explanation leads to the system
  screen, and the picker follows once access is granted. A user who declines
  is left where they were, with nothing adopted.
- The system picker refuses the root of storage and `Download/` on API 30
  and up. That is accepted: an engram at the root of the card is unlikely,
  and a subfolder of `Download/` is still allowed.

### Decision 5 — Apple: resolve at discovery, hold access for the session

- **Picking** (iOS `UIDocumentPickerViewController(forOpeningContentTypes:
  [.folder])`, macOS `NSOpenPanel` with `canChooseDirectories`) starts access
  and returns the path with a new bookmark. macOS bookmarks are created with
  `.withSecurityScope`; iOS ones with no options, as Apple documents for the
  document picker.
- **Resolving** turns the bookmark into a URL, starts access, and returns the
  path, plus a new bookmark when the old one was stale.
- **Access is held until the process exits.** Discovery resolves every
  registry row, and the switcher, Housekeeping and a later switch all read
  the folders. Stopping access after each read would mean resolving again
  before every use. The native side keeps one started URL per path, so
  resolving twice never starts access twice. The system's cap on
  concurrently accessed resources is far above any real number of adopted
  engrams.
- **This amends the storage design's Decision 2,** which says the outgoing
  engram's handle "must be `release()`d before the new one is `resolve()`d".
  The platform requires no such order. `EngramStore.release()` stays the
  seam where a per-engram handle *could* be freed if the cap ever mattered,
  and Decision 2 gains a note pointing here.
- **macOS entitlements** gain `com.apple.security.files.user-selected.read-write`
  and `com.apple.security.files.bookmarks.app-scope`. Without the first, the
  sandbox refuses the folder the dialog just returned, which is today's
  desktop adoption on a Mac.

### Decision 6 — an unreachable engram says why

`UnavailableEngram` gains a reason:

- `missing` — the folder is gone, unreadable, or not an engram any more.
  Today's only case, shown as it is today.
- `accessNeeded` — the app lacks the permission to look (Android, when All
  files access has been revoked in system settings). Every row that needs
  broad access is reported this way, **without being opened**, so a revoked
  permission never looks like deleted folders.
- `bookmarkInvalid` — the bookmark no longer resolves (Apple: the folder's
  volume is gone, or the bookmark belongs to another install). Re-adopting
  the folder is the fix. Adopting a folder that is already an engram opens
  it with its identity, so nothing is lost.

In the switcher, an `accessNeeded` row gets a **Grant access** action, which
runs the same flow as Decision 4 and rediscovers. The other reasons keep
today's disabled row, with a subtitle that says which case it is.

### Decision 7 — what is not done in this change

- **No file coordination.** The storage design expected `NSFileCoordinator`
  "when we add Location B". It protects against a concurrent writer in the
  same process tree, such as the Files app or an iCloud download. The
  watcher design's check-before-write rule already stops the app overwriting
  a change it has not seen. Coordination is added when it can be measured on
  a device, not guessed at here.
- **No iCloud placeholder handling.** A folder in iCloud Drive can be picked
  and resolved through this design. Files not yet downloaded appear as
  hidden `.<name>.icloud` stubs, which fall under the app's existing
  treatment of hidden paths (`isHiddenEngramPath`), not as notes. They are
  absent rather than broken until downloaded. Materializing them is the
  storage design's v3 work.
- **No change to engram creation.** Choosing where a *new* engram goes is
  **#100**. It will reuse `FolderAccess.pick`, which is why pick returns a
  bookmark and not only a path.

## What this asks of the implementation

Each step is a pull request. Steps 2 and 3 are verified on an Android
emulator and a physical tablet; step 4 cannot be.

1. **This document**, reviewed to consensus before anything is built on it.
2. **The Dart seam.** `FolderAccess`, `PathFolderAccess`, the registry
   `bookmark` field, resolution in discovery (including row refresh),
   `UnavailableEngram.reason`, and the rename to `folder_adoption.dart`. The
   channel implementation is a thin mapper with its codec tested against a
   mocked `MethodChannel`. Behaviour on Linux and Windows is unchanged, and
   the tests prove it.
3. **Android.** Manifest permissions, the Kotlin channel (permission, picker,
   URI-to-path mapping), the explanation dialog, **Grant access** in the
   switcher, and the ARB strings for all of it. Manual test plan: F15's
   Android and PixelTab cells, and a new case for the permission flow and its
   revocation.
4. **Apple.** The Swift channel for iOS and macOS, the macOS entitlements,
   and manual test plan cases marked *designed, unverified on hardware*.
   #94 closes here. Until a device run, the cases carry the storage design's
   Decision 3 caveat.
5. **Docs.** The storage design's platform table, its Decision 2 note, and
   the `EngramLocation` and `EngramStore.release` comments.

## Not decided here

- **A SAF backend.** Cloud-provider folders and Play builds that cannot get
  the permission are the two reasons one might still be wanted. It would be
  a second `EngramStore` plus SAF versions of everything listed under *Why a
  path everywhere*, and would be its own design.
- **Moving an engram between the container and an adopted folder.** Out of
  scope here, and adjacent to #100.
