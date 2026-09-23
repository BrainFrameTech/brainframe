# No web target

- **Status:** proposed (2026-09-22) — this document *is* the proposal; it
  becomes accepted when the PR introducing it merges
- **Author:** Claude
- **Date:** 2026-09-22
- **Supersedes:** [engram-storage.md](engram-storage.md) Decision 4 ("Web
  storage deferred; revisited post-Pi as its own backend") and the "Web has no
  CRDT" note in [note-identity-and-crdt.md](note-identity-and-crdt.md)

## TL;DR

**BrainFrame has no web target.** The `web/` platform directory, the seven
conditional-export seams that existed to serve it, their stubs, and the tests
covering those stubs are removed.

Web was never shipped, never tested, and never ran anything beyond the two
read-only built-in engrams. What it did do was put a platform seam in front of
every interesting file in the storage layer, so reading that layer meant
reading two files and a conditional to find the one arm that ever executed.

A web BrainFrame may still happen. It will be a **separate application against
a server backend**, not this codebase compiled for a browser. That was already
Decision 4's conclusion about the *storage* shape; this document extends it to
the whole app and stops paying for the option in the meantime.

## Why now

### The seam no longer branches

Every removed seam switched on `if (dart.library.io)`. After web, every
remaining target — Windows, macOS, Linux, Android, iOS, the Pi under
flutter-pi, and the software-rendering e-ink embedder in
[eink-embedder.md](eink-embedder.md) — has `dart:io`. The conditional had one
live arm on every platform that will ever run this code. It was a branch that
could no longer branch.

### The cost was on the reading path

Twenty files existed for the web target: seven facades, seven stubs, and six
test files whose only job was to cover throwers so the 90 % coverage gate
stayed green. They sat directly in front of the storage and CRDT layers, which
is where the design work is hardest to follow already. Opening `fs_store.dart`
told you nothing; you had to know to open `fs_store_io.dart`.

### Local-first and browser-first are a fork, not a flag

The op-log is `crdt_lf_sqlite` over `dart:ffi`; the catalog is `metadata.db`;
engrams are directories. A browser build cannot host any of it. The seam was
never a head start on a web BrainFrame — it only ever produced a build that
threw on contact with the app's actual model, which is why the sole thing it
could serve was the two asset-backed built-ins.

Decision 4 already reasoned this way about storage: a browser-local backend
(IndexedDB/OPFS) is single-user and serverless, so it is not a stepping stone
toward a multi-user site, and building one would be throwaway work. The same
holds one level up. Keeping a compiling-but-inert web build is not insurance;
it is a standing tax on every file it touches.

## Decisions

### Decision 1 — the web platform is removed, not deferred

`web/`, the `web` entry in `.metadata`, and the `flutter_launcher_icons` web
target are deleted. `flutter build web` is not expected to work and is not
supported. The previous status was "deferred" (engram-storage Decision 4); it
is now "removed".

### Decision 2 — the conditional seams collapse, the purity does not

The seven `if (dart.library.io)` exports become plain imports. Two shapes
resulted, and the difference is deliberate:

- **Genuine barrels keep their file.** `fs_store.dart`, `metadata_db.dart` and
  `app_data_resolver.dart` each group several exports — the implementation plus
  the pure value types beside it — so they remain as ordinary re-export files
  with the conditional removed.
- **Single-export pass-throughs collapse.** `cli_output.dart`,
  `window_state.dart`, `engram_container.dart` and `crdt_session.dart` existed
  only to hold a conditional. The `_io` implementation takes the facade's name
  and the facade is deleted. No caller changed.

What does **not** change is the separation the seams happened to sit on:
`EngramLocation`, `AppDataSource`, the `catalog.dart` row types and
`store_exceptions.dart` stay pure Dart in their own files. That purity is worth
having for layering and for tests that never touch a filesystem — it was not a
web accommodation, and it survives.

### Decision 3 — the `_io` suffix now means one thing

It marks a file that reaches `dart:io` or `dart:ffi` **directly**, and
therefore must not be imported by the pure layer. Previously it carried a
second, conflicting meaning — "the native arm of a conditional export" — for
the seven seam files. With the seams gone the suffix is consistent across the
CRDT layer, where the `_io` convention is load-bearing and stays.

### Decision 4 — a future web BrainFrame is a separate application

If it is built, it is a server-backed multi-user site with its own storage
implementation, sharing at most pure Dart model code with this repo. Nothing in
this repo is shaped to keep that door open, because the door was never open —
it led to a different building.

Removing the code does not destroy it. It is in the history, and re-adding a
platform directory is a one-command operation. What is *not* cheap is carrying
a permanent indirection in the storage layer against a possibility nobody is
scheduled to act on.

## What this changed outside `lib/`

- **Packaging.** Both AppImage builds took their icon from
  `web/icons/Icon-512.png`, a `flutter_launcher_icons` web artifact — so
  deleting `web/` would have broken Linux packaging. The icon now lives at
  `linux/packaging/brainframe-512.png`, regenerated from the master logo by
  `tool/gen_packaging_icon.py`. This is where it should have been: Linux has no
  in-toolchain launcher-icon mechanism, so its icon is a packaging input, not a
  web one.
- **`printHelpAndExit` returns `Never`.** It was declared `void` purely so its
  signature matched the web stub's. With the stub gone it can say what it does,
  and its one caller drops the unreachable `return`.
- **The engram switcher loses `allowCreateEngram`.** The parameter existed to
  hide **New engram** on web (`!kIsWeb` was the app's only `kIsWeb`). No
  shipping platform ever passed `false`. If a read-only case later wants to
  hide creation, it can reintroduce the parameter on its own terms rather than
  inheriting web's.

## Coverage

Deleting the stubs also deletes the six test files that existed to cover them,
which moves both sides of the ratio. The gate passes unchanged: **98.05 %**
(6287/6412) against the 90 % floor.
