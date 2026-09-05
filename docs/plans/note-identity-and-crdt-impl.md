# Implementation plan: Note identity and local CRDT storage

- **Status:** living — proposed, awaiting approval for implementation
- **Author:** Claude
- **Date:** 2026-08-30
- **Companion to:** `../design/note-identity-and-crdt.md` (the design and its
  nine decisions)

## Scope of this plan

The design is whole and accepted; this plan is only about **how it lands**.
It takes the design's five-phase suggestion and decomposes it into fifteen
steps, each of which is one worktree, one branch, and one pull request to
review — per the git-workflow rule.

The scope is the design's scope, unchanged: identity, the local op-log,
materialization, and reconciliation. No network, no transport, no peer
discovery (**#67**); no encryption (**#66**); no anchors, ink, or compound
anchors (the rest of **#49**).

What this plan adds on top of the design is a **review order**: which
property each PR is supposed to prove, and which tests are the ones that
would catch its removal. Where the design left a value unchosen, the step
that must choose it says so rather than letting it be picked in passing.

## Why this order

Three constraints set it, and they do not all point the same way.

**Identity must travel before notes exist.** A note minted before the
identity map is written is a note whose identity never leaves this device.
So the map (steps 5–6) lands directly after minting (step 4) and *before*
materialization — earlier than the design's phase list implies, for the
reason the design itself gives when it calls phase 2 "worth landing early".

**The diff is the risk, so it lands alone.** Decision 6 calls minimality "the
single most important rule in this document," and its failure mode is
invisible until a second device exists. Step 7 is a pure-Dart unit with no
filesystem and no UI, so the PR that carries it is small enough to read line
by line. Nothing else is in it.

**The user sees nothing until step 9.** Steps 0–8 build a layer the app does
not yet depend on; the editor keeps writing files exactly as it does today.
That is deliberate: the first user-visible change is the one that inverts the
save path, and it should land on a floor that is already tested rather than
alongside it.

## File layout

A new `lib/engram/crdt/`, following the conditional-import seam
`lib/engram/fs/` already establishes, because `crdt_lf_sqlite` needs
`dart:ffi` and web has none:

```text
lib/engram/crdt/
  app_data_resolver.dart    // where metadata.db lives, injected (Decision 2)
  metadata_db.dart          // export seam: stub unless dart.library.io
  metadata_db_io.dart       // open, schema, CRDT DDL injection, peerID
  metadata_db_stub.dart     // web: throws UnsupportedError
  catalog.dart              // rows, queries, merge policy, note state
  note_document.dart        // CRDTDocument + FugueTextHandler for one ULID
  identity_map.dart         // .brainframe/shared/<peerId>.db, read + merge
  line_chunked_diff.dart    // the wrapped myersDiff (Decision 6)
  materializer.dart         // the only writer of a note path (Decision 4)
  drift.dart                // hash, size, mtime (Decision 5)
  sketch.dart               // shingled content sketch (Decision 7)
  scanner.dart              // creations, moves, deletions, drift
  reconciler.dart           // drift -> operations -> re-materialize
  adoption.dart             // a folder with no .brainframe/ (Decision 7)
```

## Build order

Fifteen steps, fifteen PRs. Step 0 is near-trivial and independent; fold it
into step 1 if you would rather not review a two-line resource diff.

### Step 0 — Windows: separate debug and release identity (#117)

Give `ProductName` in [Runner.rc](../../windows/runner/Runner.rc) a `_DEBUG`
variant (`BrainFrame.debug`), the way that file already does for the dev
icon.

- **Property:** on Windows, a debug build and a release build resolve to
  different app-data directories — therefore different `metadata.db` files
  and different peerIDs. Every other target already has this.
- **Why first:** Decision 2 calls it a prerequisite, not a polish item, and
  it is a present-day bug independent of this design —
  `shared_preferences_windows` writes into that same `CompanyName\ProductName`
  directory, so the two builds share device settings today.
- **Honest limit:** this cannot be verified on Linux. Review is by reading
  the resource file; the behavioural check happens the first time anyone
  builds on Windows.

### Step 1 — The app-data resolver

**No new dependency.** This step was written as "add `sqlite3_flutter_libs`",
following the design's Platform consequences; both were wrong. `package:sqlite3`
v3, already resolved through `crdt_lf_sqlite`, ships its own sqlite3 on every
platform via Dart's build hooks, and that package is the obsolete v2-era way of
doing the same thing. The design records the correction.

Add `app_data_resolver.dart`: an injected
`Future<String> Function()` returning this engram's store directory,
`<app data root>/engrams/<engram ULID>/`, following the pattern
[container_resolver.dart](../../lib/engram/container_resolver.dart) already
sets — the choice lives in its own unit so tests cover it, rather than inline
in `main.dart`, which the coverage gate excludes as untestable bootstrap.

Nothing opens a database in this step.

- **Tests that matter:** Windows resolves under `LocalAppData` and **not**
  under `Roaming` — the pin Decision 2 asks for, since nothing else stops an
  upstream change, or a cleanup that "fixes" the odd-looking
  `getApplicationCacheDirectory()` call, from moving an op-log into a roaming
  profile. Linux resolves under `$XDG_DATA_HOME` and never
  `$XDG_CACHE_HOME`, where a disk cleaner would delete history mid-session.

### Step 2 — `metadata.db`: open, schema, per-engram peerID

BrainFrame opens the connection itself and injects the CRDT schema via
`CRDTSqlite.fromDatabase`, so the catalog and the op-log share one connection
and one transaction boundary. Our own schema-version row is checked strictly,
the way `EngramMetadata` rejects a future version rather than half-reading
it. The peerID is minted on first open and stored as a standalone value. It
is scoped **per device, per engram** — this engram's identity for this
install, living in this engram's `metadata.db` — which is design Decision 8:
independent engrams, and no correlatable device identifier spanning unrelated
ones.

Also here: the relocate case. An engram whose ULID no longer matches the
directory holding its database renames the directory; a destination that
already exists is **surfaced as a collision**, never silently merged or
clobbered.

- **Tests that matter:** a changed engram ULID relocates the store intact —
  every note ULID, catalog row, and operation unchanged. That test is trivial
  only while nothing inside the database references the engram ULID, which is
  exactly the property it defends.
- **Housekeeping in the same PR:** correct the stated motivation in
  [sqlite_shared_database_test.dart](../../test/crdt/sqlite_shared_database_test.dart)'s
  header. Its assertions are right and stay; only the claim that one file per
  engram is what makes an engram portable is wrong — that file is
  device-local, and what travels is the markdown plus the identity map.

### Step 3 — The catalog

The table, a typed row, and queries by path and by ULID. Columns: `ulid`,
`path`, `merge_policy`, `state`, `materialized_hash`, `size`, `mtime_utc`,
`sketch`, and this device's view of the seed claim.

`merge_policy` is an **open enum**, not a boolean — vector ink is a third
policy, not a variation of the two that exist. It defaults to `blobLww` for
an unrecognized extension, because character-merging a PNG is unrecoverable
while last-writer-wins on text loses an edit that still exists in the loser's
history. It is derived from the extension in v1 and fixed at note creation;
the column's ability to change is reserved, not built.

`state` carries live, history-pending, and tombstoned, plus the "unavailable"
case the storage design already has for engrams — a file missing because a
drive is unmounted is not a deleted file.

- **Tests that matter:** the human-readable claim — `select path, ulid from
  catalog` answers a question in a plain SQLite browser, because that is the
  whole diagnostic tree for this design.

### Step 4 — Note ULIDs and the durable op-log

Mint a ULID per note; the `documentId` handed to `crdt_lf` **is** that ULID,
so note identity and CRDT document identity are one string. `NoteDocument`
opens a `CRDTDocument` and its `CRDTFugueTextHandler` over
`changeStorageForDocument(ulid)`, and disposes it when done — the Performance
envelope's ~470 bytes per character is why holding many at once is not an
option.

Seed **only** on mint. Never seed under a ULID this device did not mint; the
guard belongs in code, not only in prose, because the failure it prevents is
content duplication that looks like a successful merge.

- **Tests that matter:** create, edit, close, reopen — history survives a
  restart; documents in one database stay isolated by id; deleting
  `metadata.db` loses history but not content.
- Still invisible: the editor writes through `writeString` exactly as today.

### Step 5 — The identity map: one file per peer, written and read

`<engram>/.brainframe/shared/<peerId>.db`, one per device, ever. Rows are
`(ulid, path, merge_policy, deleted, seeded_by, seed_hlc, hlc, peer)`.

The writer uses `VACUUM INTO` to a temporary name and renames over the
target, so the file is self-contained, has no `-wal` or `-shm` sidecars, and
is never observed partial. It writes **whole rows, never deltas** — a device
that changed only the path still carries forward every other field as it
currently understands it, or it silently blanks what it did not happen to
know. It reuses `DocumentEditController`'s existing debounce shape rather
than inventing a second timer discipline.

The reader scans the directory and unions every file's rows, including this
device's own. Peers appear as files, so nothing is discovered.

No merge rules yet — a single-device engram exercises both halves honestly.

- **Tests that matter:** the content hash never leaves the device. Assert
  `materialized_hash`, size, and mtime appear in no file under
  `.brainframe/`. It is a one-line test guarding a failure that is invisible
  until a second device holds unmerged operations, and Decision 5 spells out
  how it destroys edits rather than merging them.

### Step 6 — Merge rules, adoption, and history-pending notes

Two rules answering different questions:

1. **Contradictions about one ULID** resolve by the locked tiebreak
   comparator — HLC first, peerID second. Reuse the comparator the frozen
   suite pins; do not write a second one.
2. **Two live ULIDs claiming one path** elect the **lowest ULID**. This is an
   election between identities, not a last-writer-wins over one value, so the
   earliest mint wins rather than the latest.

The loser **retires its document**; it does not re-key onto the winner's
ULID. Re-keying is two `UPDATE` statements and is semantically wrong: both
documents were independently seeded, so re-pointing one at the other's id
puts two disjoint element universes under one document.

The seed claim becomes real here, and **"adopt" means two different things**
that must not be run together. *Adopting a folder* (step 12) mints and seeds
every note in it automatically on first open — nothing waits for the user.
*Adopting a ULID* from another device's map file records the identity
immediately and never seeds. Three cases, and only the third waits for an
edit:

| What the scan finds | What happens |
| --- | --- |
| No catalog row and no map row — the user's own vault, first open | Mint, seed from the file's text, take the claim |
| A map row carrying a `seeded_by` claim | Record the ULID, do **not** seed; the note is history-pending |
| A map row with no `seeded_by` — the map outlived every op-log that backed it | Record the ULID; seed, and claim, on the user's first edit |

Row two never seeds because seeding under a ULID another device already
seeded is the duplication hazard
[independent_seed_duplication_test.dart](../../test/crdt/independent_seed_duplication_test.dart)
pins: Fugue merges on element identity, so two independent seeds of identical
text merge to *doubled* text rather than to identical text.

Row three defers to an edit so that merely *opening* an engram does not stake
a claim — two devices that both open it while offline would otherwise race
for a seed neither is using. The race stays handled if it happens (comparator
on `seed_hlc`, the loser retracts its seeded elements); deferring only stops
it being provoked.

History-pending becomes a state the catalog, the editor, and the materializer
all understand.

- **A consequence that lands before #67.** A device in row two has working
  notes with **no local history** — edits save, drift reconciles, and
  Decision 4's direct-write path carries them, but no version history exists
  for those notes until sync delivers the log. On a two-machine shared folder
  today, whichever machine did not mint a note stays in that state
  indefinitely. It is the deliberate trade, since the alternative corrupts
  content, but it is invisible unless someone goes looking for history — so
  step 13 surfaces the count.

- **Tests that matter:** a cold copy adopts rather than mints, and deleting
  the map then reopening mints fresh ULIDs with unchanged content — the two
  halves of Decision 9's promise, the second being the degraded path people
  actually hit. A **non-minting device's rename propagates** to a third
  device: nothing surfaces when this breaks, so only a test catches it. A
  freed path does not resurrect a dead note. A contested seed heals.

### Step 7 — The line-chunked diff

One pure-Dart unit, no filesystem, no UI. Diff line sequences first and call
`myersDiff` only within a changed region, then apply the resulting segments
through the handler's own `insert`/`delete` path inside **one**
`CRDTDocument.runInTransaction`.

Two rules, both load-bearing:

- **Minimal, never replace-all.** A delete-everything-then-insert converges,
  passes a two-replica test, and discards every concurrent remote insertion.
- **`change()` is never handed a whole note.** `myersDiff` trims the common
  prefix and suffix and then runs with no size guard, at O(D x (n+m)) — a
  product. A CRLF round-trip makes every line differ, so prefix trimming buys
  nothing and `D` becomes the line count: about 6.4 GB for a 100 KB note.
  "Edited in another tool and synced back" is the case this design exists to
  serve, so that is the common path, not an exotic one.

- **Tests that matter:** device B's concurrent insertion survives an external
  edit applied on device A — the test a single-replica suite cannot write.
  A whole-file CRLF-to-LF change stays cheap. Surrogate pairs survive a diff
  boundary with no element split. An interrupted script leaves the note
  untouched, never half applied.
- **Read this PR closely.** It is the smallest one with real difficulty in
  it, and the only one whose defects are invisible until #67.

### Step 8 — Materializer, write ordering, drift detection

The materializer becomes the only writer of a note path, with one bounded
exception: a history-pending note, which is written directly the way notes
were written before this design.

The order is **materialize → write file → commit catalog row**, the catalog
update in a transaction, never reordered. A crash between the write and the
commit leaves a stale hash, so the next scan re-diffs our own output, finds
no semantic difference, and re-records — a redundant diff, not lost data.
Committing the hash first inverts that into silent loss.

The projection must be byte-stable, which forbids re-serializing frontmatter
through a YAML library on the way out.

- **Tests that matter:** byte-stable materialization across a save/reload
  cycle, including frontmatter with the comments, quoting, and key ordering
  the user chose. Crash-ordering recovery self-heals with nothing lost or
  duplicated. The size/mtime pre-filter is an optimization and never the sole
  test — same-size same-second edits are trivially achievable by a script.

### Step 9 — Editor rewiring (first user-visible step)

`DocumentEditController.flush` becomes "apply the buffer diff as operations,
then materialize" — the same call as reconciliation, which is a genuine
unification rather than two parallel paths. It stops calling `writeString`,
keeping that path deliberately for history-pending notes.

Flush points are unchanged: manual save, file switch, focus loss, and
lifecycle pause/detach. From the user's side, save status behaves as it does
today.

- **Manual test plan:** the existing editing and save cases are re-verified
  against a changed implementation, and a new case covers edit → quit →
  reopen with content and history intact.

### Step 10 — The scan: drift reconciliation

Decision 6 end to end. The scan runs on app start, on app resume, and
immediately before a file is opened for editing; the filesystem watcher
(**#70**) becomes another caller of the same entry point when it lands.

Per drifted note: flush the editor if that note is open, materialize, diff,
apply in one transaction, re-materialize, write back if it differs, commit
the new hash.

- **Tests that matter:** **two devices over one folder converge** — two
  `metadata.db` files and two peerIDs pointed at one engram directory, edited
  alternately with a scan between. This is the direct test of "locally
  arriving CRDTs work," and it is what proves the design's argument rather
  than restating it.

### Step 11 — The scan: creations, moves, and deletions

Decision 7's table, and the write that keeps the map honest.

A gone path plus a content-hash match is a move — keep the id and history,
exactly as `git` detects a rename. A gone path plus a highly similar new one
is rename-with-edit: re-associate, then reconcile the difference as ordinary
drift. Similarity comes from a shingled content sketch stored per note,
device-local, rebuilt by a scan. Below the threshold it is a delete plus a
create and **must be surfaced** — that is the honest price of rejecting a
frontmatter id, and it is not allowed to be silent. Absence is not deletion:
tombstone only when the scan is known-complete and the file is confirmed
absent.

File-management operations — new note, rename, delete, move — route through
the catalog **and** write the map row. A rename that updates the catalog and
stops there leaves the map stale, which is precisely Decision 9's silent
failure.

- **Decide here, and record it:** the sketch's shingle size, width, and
  cutoff, chosen against `test/fixtures/engram` rather than in the abstract,
  biased toward missing a match — too low re-associates unrelated notes and
  merges their histories, which is the worse direction. The design parks this
  question; this step retires it and updates the design's Open questions to
  say so.

### Step 12 — Adopting a folder with no `.brainframe/`

The normal way a real user starts, so it is a designed operation rather than
an edge case. Create the marker, then mint and seed incrementally, disposing
each document as it goes so peak memory is one note rather than the vault.

Resumable: a half-finished adoption is already a valid state, since a path
with no catalog row is simply "a new note" next time — claimed deliberately
here, because a step that mints ids before the scan is durable would break
it. Non-blocking, with progress, and never waiting for a peer.

- **Tests that matter:** adoption resumes after interruption — every note
  ends with exactly one ULID, none minted twice, no content duplicated. Two
  machines adopting one folder converge on the same ULID per path with each
  note's content appearing exactly once, not doubled by the loser's seed.
- **Manual test plan:** a new adoption section; user-visible progress and a
  usable engram while it runs.

### Step 13 — Housekeeping surface

Settings › Housekeeping gains what Decision 9 promises instead of a prompt on
open: peers seen, notes adopted from the map, notes minted locally, and the
below-threshold history-loss reports step 11 raises.

"Notes adopted from the map" is not a curiosity. Before **#67** exists it is
exactly the set of notes with no local history (step 6), and this panel is
the only place that state is visible at all.

This is where "no prompt on open" pays out — minting is reversible, most
users cannot answer "is this engram from another machine?", and refusing to
open until an unbuilt transport reaches an unreachable peer would trade a
possible history loss for a certain outage.

- Strings through `AppLocalizations`; manual test plan updated for the new
  panel content.

### Step 14 — `blobLww` for binary content

The op-log carries a register — content hash, size, and the HLC/peerID stamp
the comparator needs — never the bytes. The file stays in the engram as the
ordinary file it already is.

The v1 boundary is deliberate: a peer receiving a `blobLww` operation has the
*decision* but not the *bytes*, and transporting bytes is **#67**'s, alongside
every other transport question. Locally, where both live in one folder,
nothing is missing.

- **Tests that matter:** an image never enters the diff path; two concurrent
  writes resolve deterministically through the locked comparator; the
  database does not grow with the file.

## Rules that apply to every step

- **One worktree, one branch, one PR**, per the git-workflow rule, reviewed
  before it merges.
- **Coverage stays at or above the 90% gate**, honestly: the generated
  import-all helper means a new file with no tests reads as 0% rather than
  vanishing, so tests land in the same PR as the code.
- **The frozen suite in `test/crdt/` is untouched.** No assertion in it may
  be weakened to accommodate anything here. If a step cannot be built without
  changing one, that is a finding to surface, not a change to make.
- **Web never reaches SQLite.** `crdt_lf_sqlite` needs `dart:ffi`; the seam
  keeps it behind conditional import, and web — which has no filesystem store
  and only read-only built-in engrams — needs neither catalog nor op-log.
- **Read-only engrams have no catalog, op-log, or identity map**, and nothing
  is ever written into an asset-backed `.brainframe/`.
- **Every SQLite table BrainFrame creates is prefixed `bf_`.** SQLite has no
  namespaces, and these databases are shared with `crdt_lf_sqlite`, which
  claims the generic names `changes` and `snapshots`. A collision would be
  silent, not loud — the library's `CREATE TABLE IF NOT EXISTS` would simply
  skip a table of ours already sitting on one of those names, and then read and
  write our columns. The design states the rule; `lib/engram/crdt/schema.dart`
  holds it; a test asserts every table in an open store is either `bf_`-prefixed
  or one the library named.
- **No hardcoded UI strings** in the steps that touch UI (9, 12, 13).
- **The manual test plan moves in the same PR.** Steps 9, 12, and 13 are the
  user-facing ones and edit real cases. The rest add nothing a human can
  drive, so they belong in "Not yet testable" with the reason, and get
  promoted out of it by the step that makes them visible.

## Questions this plan does not answer

- **The note-size ceiling** (**#124**). Roughly 470 bytes per character puts
  a 3.2 MB note near 1.5 GB resident — comfortable on desktop, fatal on iOS
  and a 2 GB Pi. The measurement exists; the policy does not, and it needs
  numbers from targets we cannot measure yet. No step here may quietly pick
  one by adding a limit.
- **Snapshot and compaction policy** (**#118**). Purely local use has no
  stranded peers, so it stays deferred — but it must be settled before
  **#67**, which is the moment peers below the frontier become possible.
- **Everything about transport** (**#67**). This plan's job is to hand it a
  merge rather than a conflict, including the two requirements the design
  already hands over: peerID collision detection in the handshake, and an
  importer that treats a short return count from `importChanges` as a retry
  signal rather than a success.
