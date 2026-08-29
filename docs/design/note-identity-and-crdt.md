# Note identity and local CRDT storage

- **Status:** accepted (2026-08-29)
- **Author:** Claude
- **Date:** 2026-08-16

## TL;DR

BrainFrame has a frozen, in-memory CRDT test suite proving what `crdt_lf`
guarantees, and it has notes on disk identified only by their path. Nothing
connects the two: `lib/` contains no CRDT code at all. This document designs
that connection — **the entirely local half of sync** — and nothing else.

Four things have to exist:

1. **Stable note identity** independent of the file's path.
2. **A durable local op-log**, so a note's history survives app restart.
3. **Materialization** — turning the CRDT's value back into the `.md` file on
   disk that every other tool sees.
4. **Reconciliation** — turning a file that changed *without* us into
   operations, so an edit made in Obsidian, arriving over iCloud, or landing
   via `git pull` merges instead of clobbering.

No network, no transport, no peer discovery. When those land (**#67**), they
deliver *changes* into a layer that already knows how to apply them.

## Relationship to #49 and #50

Build-order step 4 (**#49**) is the omnibus data-model design: anchored ranges,
vector ink payloads, EPUB CFI / PDF-region compound anchors, the web-source
anchor variant, the encryption unit and key model, note-state scoping. This
document is deliberately **a proper subset of #49** — the identity and storage
substrate — and defers the anchor/payload half to a follow-on design.

That split is a claim, so here is the argument for it. #49's governing
discipline is *"reserve now, retrofit painfully later."* That warning applies
hardest to **identity**: once notes exist on disk with no stable id, minting
ids after the fact is a migration over real user data. Anchors, ink payloads,
and recognized-text fields all *reference* a note; they attach to an identity
that already exists, so adding them later is additive rather than a migration.
Doing identity first therefore honors #49's discipline rather than dodging it.

The deferred half is also largely unexercisable today: compound anchors cannot
be validated without PDF (**#53**) or ePub (**#54**), and the ink model cannot
be validated without handwriting capture (**#52**). Designing them now would
produce paper decisions with no implementation to keep them honest — the exact
failure mode #50 exists to prevent.

What this document must not do is *preclude* the deferred half. Two places
where that matters are called out explicitly in Decision 3 and Decision 5.

## Scope

### In scope

- Note identity: minting, storing, and re-associating note ids.
- The per-engram catalog and its schema.
- The durable op-log and where its files live.
- Per-document merge policy (mergeable text vs. whole-blob last-writer-wins).
- Materializing CRDT state to disk, and the write-ordering that makes a crash
  mid-save recoverable.
- Reconciling external edits, moves, creations, and deletions into operations.
- How the existing editor and save pipeline rewire onto this.

### Out of scope

- **Network transport and peer exchange** (**#67**). Explicitly excluded.
- **Encryption** (**#66**, spike **#69**).
- **Anchored ranges, ink payloads, compound anchors, recognized text** — the
  rest of **#49**, per the section above.
- **Version-history UX** (**#84**). This design is what makes it possible; the
  browsing and restore surface is its own work.
- **The CRDT-aware editor** (**#85**). Noted below where the two meet: the
  diff-to-operations path designed here is the same machinery #85 replaces with
  direct operation emission.
- **Structured frontmatter as a CRDT tree** (**#106**) — explored and rejected;
  frontmatter is text inside the note's single sequence.
- **The frontmatter semantic validator** (**#104**) — a read-and-warn layer
  above materialized text.

## What already exists

Grounding, so this design is not re-deciding settled things:

- **The frozen edge-case suite.** [test/crdt/](../../test/crdt/) renders
  [crdt-sync-test-spec.md](../testing/crdt-sync-test-spec.md) into executable
  tests. It is ground truth and must not be weakened. It is deliberately
  in-memory only — no storage, no filesystem, no transport.
- **The locked storage model.** The entire note — body *and* YAML frontmatter —
  is one `CRDTFugueTextHandler` over a `CRDTDocument`. One handler type, one
  materialization primitive: read the handler's `value` as a string.
- **The locked tiebreak comparator.** Concurrent competitors resolve by HLC
  timestamp first, peerID second. Any new last-writer-wins rule in this design
  must invoke that comparator rather than inventing a second one.
- **The dependencies.** `crdt_lf: ^3.5.0` and `crdt_lf_sqlite: ^0.1.0+2` are in
  `pubspec.yaml` and used by tests only.
- **Consumer-owned database, already proven.**
  [sqlite_shared_database_test.dart](../../test/crdt/sqlite_shared_database_test.dart)
  pins that `CRDTSqlite.fromDatabase` accepts a connection BrainFrame opens and
  manages, and that its `CREATE TABLE IF NOT EXISTS` DDL can be injected
  repeatedly into a schema holding BrainFrame's own tables. That test was
  written precisely so this design could assume it.
- **Document isolation by id.** `changeStorageForDocument(documentId)`
  partitions one database across many notes, proven in the smoke test.
- **The current save path.**
  [document_edit_controller.dart](../../lib/engram/ui/document_edit_controller.dart)
  owns one open file, debounces autosave, and writes the whole buffer through
  `EngramStore.writeString`. It already flushes on file switch, focus loss, and
  app pause/detach — a property Decision 6 depends on.
- **Engram identity, but not note identity.** `EngramMetadata` gives each
  engram a ULID in `.brainframe/engram.json`. Individual notes have no id of
  any kind anywhere in `lib/` or the design docs.

## Decisions

### Decision 1 — a note's identity is a ULID held in a catalog, not in the file

Every note gets a **ULID**, minted once, that never changes for the life of the
note. It is the `documentId` handed to `crdt_lf`, so note identity and CRDT
document identity are the same string — one concept, not two that must be kept
in step.

The id lives in a **catalog table** (Decision 2), keyed to the note's current
engram-relative path, in `metadata.db` locally and in the exported state file
that travels with the engram. It is **not** written into the markdown file.
Ids therefore agree across devices that receive the engram's identity map, and
are re-minted by a device that does not — see "Consequence: identity is shared,
history is not" below.

ULID rather than UUIDv7 for consistency with `EngramMetadata.id`, which already
uses one and already has an `isCanonicalUlid` validator in
[id.dart](../../lib/engram/id.dart). This is unrelated to `crdt_lf`'s `PeerId`,
which is a UUID and identifies a *device*, not a note.

**Why not in YAML frontmatter.** An `id:` key in the note's frontmatter is the
obvious alternative — it travels with the file through any tool, and a rename
in Obsidian or a `mv` in a terminal preserves identity for free. It is rejected
as the *authority* for three reasons, the first of which is decisive:

- **Frontmatter is mergeable text under the locked storage model.** It is part
  of the note's single Fugue sequence, and the accepted consequence of that
  model is that concurrent edits to one frontmatter line produce
  run-contiguity garbling (`published: truefalse`). Making identity depend on a
  field that the storage model explicitly permits to garble is building the
  foundation out of the one material known to be soft.
- **Copy-paste duplicates it.** A user duplicating a note in Finder produces two
  files claiming one id — two notes sharing one op-log, which is corruption
  rather than a merge. A catalog can detect and repair a duplicate path; it
  cannot repair two files that both insist they are the same note.
- **It is user-visible clutter in a file the user owns**, and it collides with
  the frontmatter feature (**#57**) and validator (**#104**).

**Reserved, additive escape hatch.** A frontmatter stamp may later be added as
a pure *hint* — read to speed up re-association, never trusted as authority,
rewritten by us whenever it drifts. Because a hint that garbles simply fails to
match and falls through to content matching (Decision 6), the mergeable-text
objection does not apply to that role. This is a one-column, one-code-path
addition if interop ever demands it, so it is reserved rather than built —
and the Open questions section records the review that considered building it
now and declined.

### Decision 2 — one local database, plus a small shared identity map

Two artifacts, sized very differently, and the size difference is the design.

| Artifact | Where | Holds |
| --- | --- | --- |
| `metadata.db` | platform app-data directory, keyed by engram ULID | op-log, catalog, this device's peerID, content hashes, scan state |
| `shared/<peerId>.db` | `<engram>/.brainframe/shared/` | engram-level shared state; today, the identity map |

```text
<app data root>/                    <engram>/
  engrams/                            .brainframe/
    <engram ULID>/                      engram.json
      metadata.db  ← everything         shared/
                                          <peerId>.db  ← shared state
```

BrainFrame opens `metadata.db` itself and injects the CRDT schema via
`CRDTSqlite.fromDatabase`, so the catalog and the op-log share one connection
and one transaction boundary. Decision 9 covers the map.

**The op-log is local; identity is shared.** That division is the whole
decision, and each half has an independent reason.

*History stays local* because moving it is **#67**'s job. A network transport
that exchanges `Change` objects is the designed path for that, and building a
second, file-based transport alongside it would mean two mechanisms carrying
one payload — with the file-based one inheriting every hazard of putting a
mutable database in a synced folder.

*Identity travels* because without it, two devices opening one engram mint
**different** ULIDs for the same file. Their op-logs are then keyed to
different documents, and #67 can only elect a winner and discard the loser's
history. Sharing a few kilobytes of path-to-ULID mapping converts that into an
ordinary merge: both devices build on the same `document_id`, so when P2P
connects the two histories combine instead of competing.

**What is deliberately *not* shared.** `materialized_hash`, and the size and
mtime beside it, are device-local — see Decision 5, which explains why sharing
them silently destroys edits rather than merging them. Scan state and the
peerID are local for the same reason: they describe a device, not a note.

**Recovery.** Deleting `metadata.db` costs **history, never content, and never
identity**. The markdown is on disk, and the identity map is in the engram, so
a rebuilt database re-adopts the same ULIDs it had before. That is the whole
diagnostic tree for this design, and it is why the human-relevant tables —
`path`, `ulid`, `merge_policy` — must be plain columns rather than blobs, so
`sqlite3 metadata.db 'select path, ulid from catalog'` answers a question in
any SQLite browser. Operation payloads stay opaque; nothing a person needs to
read does.

**Where `metadata.db` goes.** There is no single directory name across the six
targets, and — as the Windows row shows — the two obvious `path_provider` calls
do not agree on which one is correct. Resolution goes through a single injected
resolver, mirroring `applicationEngramContainerPath()` in
[fs_store_io.dart](../../lib/engram/fs/fs_store_io.dart), rather than being
called ad hoc at each use site:

| Platform | Resolver | Release build resolves to |
| --- | --- | --- |
| Linux | `getApplicationSupportDirectory()` | `$XDG_DATA_HOME/tech.brainframe.app/`, default `~/.local/share/tech.brainframe.app/` |
| macOS | `getApplicationSupportDirectory()` | `~/Library/Application Support/tech.brainframe.app/` |
| Windows | `getApplicationCacheDirectory()` | `%LOCALAPPDATA%\tech.brainframe\BrainFrame\` |
| Android | `getApplicationSupportDirectory()` | `/data/data/tech.brainframe.app/files/` |
| iOS | `getApplicationSupportDirectory()` | `<app container>/Library/Application Support/` |
| Raspberry Pi | configuration override | operator-chosen path on the mounted volume |

**Windows takes `getApplicationCacheDirectory()` on purpose.**
`getApplicationSupportDirectory()` maps to **`RoamingAppData`** on Windows, and
a roaming profile is copied between machines at logon and logoff — a live
database copied out from under its writer, and an op-log silently inflating a
roaming profile users already complain is slow. `getApplicationCacheDirectory()`
is the only `path_provider` call reaching the non-roaming `LocalAppData`; its
name is an abstraction leak, not a claim the contents are disposable. Pin the
mapping with a test asserting the resolved path is under `LocalAppData`, since
nothing else stops an upstream change — or a well-meaning cleanup that "fixes"
the odd-looking call — from moving an op-log into a roaming profile. The same
call must **not** be reused on Linux, where it resolves to `$XDG_CACHE_HOME`
and invites a disk cleaner to delete history mid-session.

`$XDG_DATA_HOME` rather than `$XDG_CACHE_HOME` on Linux follows from the same
reasoning: an op-log is not derived from anything and cannot be rebuilt by
rescanning.

**Debug and release builds are separate stores, by construction.** Every path
above derives from the platform application identity, and
[debug-build-identity.md](../debug-build-identity.md) already gives debug
builds a `.debug` suffix wherever there is an OS-level identity to suffix. A
debug build and a release build on one machine therefore hold different
databases and different peerIDs while sharing one engram's markdown and one
identity map. They are two independent peers, which is the intended
arrangement: the app stays usable in one window while being developed in
another. This is a **required property, not a side effect**, and one target
does not yet satisfy it — see "Platform consequences" for the Windows fix.

**Why the database is not in the engram, but the map is.** The distinction is
*mutation*, not SQLite.

A live database is opened, held across a session, and written in place. It is a
page-structured binary with invariants spanning pages, plus `-wal` and `-shm`
sidecars whose contents must match it. A sync service that copies those files
seconds apart, transfers one partially, or resolves two divergent copies by
last-writer-wins produces a file that is not stale but **corrupt** — silently
and totally. Since an engram folder living in iCloud or Dropbox is an
explicitly supported arrangement, nothing placed inside the engram may be a
live database. This keeps
[engram-storage.md](engram-storage.md)'s existing rule intact rather than
amending it.

The map is the opposite: written by a single named writer, complete when it
appears, replaced atomically, never modified in place, and small enough that
rewriting it whole costs nothing. Decision 9 establishes those properties.

`metadata.db` rather than a narrower name like `catalog.db`: the catalog is the
first tenant, not the only one. Per-engram state that is device-local and not
user content — snapshot bookkeeping, scan state, later the search and graph
indexes — belongs in the same file, and a name describing only the first table
leaves the next reader wondering whether they are in the right place.

**One database, not one per note or per peer.** `crdt_lf_sqlite`'s `changes`
table is keyed `PRIMARY KEY (document_id, change_id)`, and `change_id` renders
as `peerId@hlc`. The peer is therefore already part of every row's key, so
changes from any number of peers coexist in one table with no possibility of
collision once #67 delivers them, and `document_id` separates the notes.

**One note on the shared-database test.**
[sqlite_shared_database_test.dart](../../test/crdt/sqlite_shared_database_test.dart)
still asserts exactly the right thing — BrainFrame's tables and the CRDT tables
must co-exist in one consumer-owned database — and that property stays
load-bearing. Only its header's stated *motivation* ("one file per engram is
what makes an engram copyable, backup-able, and syncable as a unit") needs
correcting: the file it describes is device-local, and what makes an engram
portable is the markdown plus the identity map beside it.

### Decision 3 — merge policy is per note, recorded in the catalog

Each catalog row carries a `merge_policy`:

| Policy | Meaning | Applies to |
| --- | --- | --- |
| `fugueText` | Whole file is one `CRDTFugueTextHandler` sequence — the locked model. | `.md`, `.txt`, and other text |
| `blobLww` | Whole file is one opaque value; concurrent writes resolve by the locked tiebreak comparator. | images, PDF, EPUB, archives |

**The default for an unrecognized extension is `blobLww`.** The asymmetry is
deliberate: character-merging two versions of a PNG produces a corrupt file
that no one can recover, while last-writer-wins on a text file loses one edit
that still exists in the loser's history. Default toward the recoverable
failure.

**Policy travels with identity, not with the device.** `merge_policy` is a
property of the note, so it lives in the shared identity map (Decision 9)
beside the ULID, and the catalog holds the local copy. Two devices that
disagreed about a note's policy would apply incompatible semantics to one
op-log — character-merging what the other treats as an opaque blob — which is
corruption rather than divergence. In v1 policy is derived from the extension,
so devices would usually agree by construction; "usually agree by accident" is
a worse guarantee than one shared column.

**Policy is fixed at note creation for v1.** Changing it mid-life means
reinterpreting an existing op-log under different semantics, which needs a
migration story. Reserve the column's ability to change; do not build it.

**`blobLww` stores a register, not the bytes.** The op-log carries the content
hash, size, and the HLC/peerID stamp that the comparator needs — not the file's
contents. The bytes stay in the engram as the ordinary file they already are.
This keeps the database small, and it is honest about what LWW actually
requires: only an ordering, never the content. The consequence is a deliberate
v1 boundary — a peer receiving a `blobLww` operation has the *decision* but not
the *bytes*, so transporting bytes is part of **#67**, alongside every other
transport question. Locally, where both live in the same folder, nothing is
missing.

**Reserved for #49's deferred half.** `merge_policy` is an open enum, not a
boolean. Vector ink (atomic, immutable, add/delete-only strokes) is a third
policy, not a variation of either of these, and it will be added as one.

### Decision 4 — the file on disk is a projection, written by the materializer

The CRDT is the authority for a `fugueText` note. The `.md` file is a
projection of it, and **only the materializer writes it**. Nothing else in the
app calls `writeString` on a note path.

That inverts today's flow, where the editor's buffer is the authority and the
file is where it lands. Consequences are covered in Decision 6.

**We write what the user wrote; we never write what only we can read.** The
materializer puts the user's own words back on disk, which is why writing their
file is legitimate at all. It is not licence to add machine tokens to a
document they own — an id, a checksum, a sync marker — that they did not ask
for, cannot use, and cannot delete without us silently restoring it. The
markdown is the user's permanent copy; the op-log and the databases are ours.
This is the rule that settles the frontmatter-id question below, and it is
worth checking any future addition against.

The projection must be **byte-stable**: materializing the same CRDT state twice
produces identical bytes. Anything else makes drift detection (Decision 5)
report phantom changes forever. Concretely, this forbids re-serializing
frontmatter through a YAML library on the way out — which the locked storage
model already implies, since frontmatter is text in the sequence and never a
parsed structure.

### Decision 5 — drift is detected by content hash, with a strict write order

Each catalog row records `materialized_hash`: the hash of the exact bytes the
materializer last wrote. Drift detection is one comparison — hash the file, and
if it differs from `materialized_hash`, the file changed without us.

Writes are ordered **materialize → write file → commit catalog row**, with the
catalog update in a transaction, and never reordered.

A crash between the file write and the catalog commit leaves the file changed
and the recorded hash stale, so the next scan reports drift for a file *we*
wrote. Reconciliation then diffs our own output against the CRDT, finds no
semantic difference, and re-records the hash. The failure mode is a redundant
diff, not a lost or duplicated edit — self-healing, which is the property being
bought. Committing the hash *before* the write inverts this into silent data
loss, so the ordering is load-bearing rather than stylistic.

**`materialized_hash` is device-local, and must never be shared.** It records
what *this device's* materializer last wrote, not a property of the note, and
two devices legitimately hold different values at the same instant. Sharing it
converts drift detection into silent data loss:

1. Device A materializes and writes the file; the recorded hash becomes `H_A`.
2. Device B — holding unmerged local operations — reads the shared `H_A`.
3. B hashes the file, gets `H_A`, and concludes there is **no drift**.
4. B therefore never reconciles A's edit into its own CRDT.
5. B materializes later and writes its own content over the file. A's edit is
   now gone from disk as well as from B's history.

That is the exact failure the write ordering above exists to prevent, arriving
through a different door. The same reasoning covers the size and mtime
pre-filter: all three describe a device's own last write.

Store the file's size and mtime alongside the hash as a cheap pre-filter — if
both are unchanged, skip hashing. This is an optimization and must never be the
sole test, because same-size same-second edits are entirely achievable by a
script.

### Decision 6 — external edits become operations via a minimal diff

This is the heart of "locally arriving CRDTs work." A scan runs on app start,
on app resume, on filesystem-watcher events once **#70** lands, and immediately
before a file is opened for editing.

For each note whose file has drifted:

1. Flush the editor first if this note is open (`DocumentEditController.flush`
   already exists and is already wired to file switch, focus loss, and
   lifecycle). Reconciling underneath an unsaved buffer would race.
2. Materialize the CRDT to `crdtText`.
3. Compute a **minimal edit script** from `crdtText` to the file's current text.
4. Apply that script as `insert`/`delete` operations on the Fugue handler,
   inside **one** `CRDTDocument.runInTransaction`, stamped with this device's
   peerID and current HLC.
5. Re-materialize. If the result differs from the file — which it will whenever
   unmerged operations from another device were also pending — write it back
   through Decision 4's path.
6. Commit the new `materialized_hash`.

**Steps 3 and 4 are `crdt_lf`'s to perform, not ours.** The library already
ships both halves: `myersDiff(oldText, newText)` returns coalesced
equal/insert/remove segments, and `CRDTFugueTextHandler.change(newText)` runs
that diff and converts each segment into handler `insert`/`delete` calls.

Using the library's application path matters more than using its diff. The
offset-to-identity conversion is the invariant the frozen suite exists to
defend, and it is upstream's code, tested upstream and shared with every other
consumer. Reimplementing it here would be strictly more risk for no gain.

**The minimality of step 3 is the single most important rule in this
document.** The naive implementation — delete everything, insert the new text —
converges, passes a two-replica test, and is catastrophically wrong: it
tombstones every element another device might concurrently be editing, so every
concurrent remote insertion is discarded. Nothing about it looks broken until a
second device exists. Myers is a genuine shortest-edit-script algorithm, so it
satisfies this rule where a replace-all does not.

**But `change()` must never be handed a whole note.** `myersDiff` trims the
common prefix and suffix, then runs Myers on the remaining middle with **no
size guard**. Its `_shortestEditScript` snapshots the whole frontier array once
per edit-distance step, so memory is O(D x (n+m)) — a product, not a sum.

The trigger is not a large note; it is a **dispersed** edit, and the ordinary
one is a line-ending change. A note round-tripped through a Windows editor
comes back CRLF, so every line differs, prefix trimming stops at the first line
ending and buys nothing, and `D` becomes the line count. A 100 KB note of ~2000
lines then wants roughly 2000 x 400,001 ints — about **6.4 GB** — to diff a
change that is semantically trivial. Trailing-whitespace stripping and a
markdown reflow have the same shape. "Edited in another tool and synced back"
is precisely the case this decision exists to serve, so this is the common
path, not an exotic one.

**So: chunk by line, refine by character.** Diff line sequences first, and call
`myersDiff` only within a changed region. That bounds `D` to the size of one
region rather than the whole note, which is what makes the memory profile
linear instead of a product. This is the one place the design deliberately
wraps the library rather than calling it directly, and the reason is the
missing guard, not a disagreement about the algorithm.

**One transaction for the whole script.** `change()` registers an operation per
segment and does not open a transaction itself — its own documentation only
recommends one. Without it, reconciliation is not atomic, and a crash partway
through leaves a half-applied edit that Decision 5's write ordering assumes
cannot exist.

**Surrogate pairs need a test, not an assumption.** `myersDiff` operates on
UTF-16 code units, so an edit boundary can fall between the halves of an
astral-plane character. The materialized string still reconstructs correctly,
but the two halves become independently addressable Fugue elements, and a
concurrent edit could tombstone one of them. An emoji-bearing reconciliation
test is cheap; reasoning about it in the abstract is not.

**Attribution is honest by construction.** Synthesized operations carry this
device's peerID because we genuinely do not know who made the external edit.
They are indistinguishable from local edits, which is the correct answer rather
than a limitation.

**This is the same machinery #85 replaces.** A CRDT-aware editor emits real
operations instead of a reconstructed diff, and when it lands it bypasses steps
2-4 for the in-app path. The reconciliation path stays, because external edits
never stop arriving.

See "Performance envelope" below for the measured cost of the operations this
decision generates, and the note size at which the storage model itself becomes
the limit.

### Decision 7 — creations, moves, and deletions are inferred from the scan

The scan compares the catalog against what is actually on disk:

- **A path in neither the catalog nor any content match** — a new note. Mint a
  ULID, create the `CRDTDocument`, seed it with the file's full text as a single
  insert.
- **A catalog path that is gone, plus a new path whose content hash matches** —
  a move. Keep the id and history; update the path. This is exactly how `git`
  detects renames.
- **A catalog path that is gone, plus a new path that is highly similar** — a
  rename *and* edit in one offline window. Re-associate above a similarity
  threshold, then reconcile the content difference as an ordinary drift.
  Similarity is estimated from a **content sketch** — shingled MinHash or
  equivalent — stored per note in the catalog beside the hash, so an unmatched
  path is compared against the sketches of recently-missing notes rather than
  against their full text. The sketch is device-local derived data: it lives in
  `metadata.db`, is rebuilt by a scan, and is never shared.
- **Below the threshold** — treat as a delete plus a create, and **surface it**.
  This loses that note's history, which is a real cost, so it must be visible
  rather than silent. This is the honest price of Decision 1's rejection of a
  frontmatter id, and the sketch above exists to make this cell rare rather
  than to eliminate it.
- **A catalog path that is gone, with no candidate** — tombstone the note.

**Absence is not deletion.** A file missing because a drive is unmounted, an
engram is unavailable, or iCloud has not materialized a `.icloud` placeholder
must never tombstone anything. Only tombstone when the scan is known-complete
and the file is confirmed absent. The storage design already carries an
"unavailable" state for engrams; notes need the same state for the same
reason.

### Decision 8 — device identity is per device, per engram

`crdt_lf` needs a stable `PeerId` — a UUID — for this device. It is minted on
first write to an engram and stored in that engram's `metadata.db`, alongside
the op-log its operations are stamped with. Scoping per engram rather than one
identity per device keeps engrams independent and avoids leaking a correlatable
device identifier across unrelated engrams.

The property that must hold is narrow: **two live writers must never share a
peerID.** Two devices stamping operations with one identity makes genuinely
concurrent operations indistinguishable rather than merely tied, which breaks
the tiebreak comparator's uniqueness assumption.

"Device" here means **build install, not machine**. A debug and a release build
on one computer resolve to different databases (Decision 2) and are therefore
different peers, deliberately.

**A cloned identity is detected where it matters, which is #67.** Copying or
restoring a `metadata.db` onto a second machine duplicates its peerID. That is
harmless for exactly as long as the two logs never meet: each device edits its
own markdown, Decision 6 reconciles the content through the file, and neither
log observes the other. The damage requires two logs carrying one peerID to
**merge** — and there is precisely one place that happens.

So collision detection belongs in **#67**'s handshake, where two peers announce
themselves before exchanging changes and a duplicate is both visible and
actionable (the newer install re-mints and re-stamps nothing, since its
operations are still its own). This design hands #67 that requirement rather
than solving it here.

**Why not exclude the database from backups.** Considered and rejected. It
needs platform configuration on Android (`dataExtractionRules`) and iOS
(`NSURLIsExcludedFromBackupKey`); it is unenforceable on the three desktops
against `restic`, Backblaze, or image-based backup; and when it fails it fails
**silently**. It would also be defending against a state that is harmless until
the moment #67 can see it directly.

**Why not tie the peerID to hardware.** Also rejected:

- **It does not deliver uniqueness.** `/etc/machine-id` is baked into golden
  images and cloned across VM fleets; MAC addresses are randomized on modern
  mobile and cloned by hypervisors; iOS `identifierForVendor` resets when the
  last app from a vendor is deleted; Android exposes no stable device id to
  unprivileged apps. The result is an identifier that is sometimes duplicated
  and sometimes reset — worse than random at its one job.
- **It is a privacy regression.** A hardware identifier stamped into every
  operation and shipped to every peer at #67 is a permanent, correlatable
  fingerprint in a log that never forgets — the opposite of the per-engram
  scoping above.
- **It detects rather than prevents**, and the handshake already detects,
  without reading anything about the machine.

**The cost of minting freely.** `VersionVector` is `Map<PeerId, HLC>` — one
entry per peer ever seen, 24 bytes each — embedded in every `Snapshot`, which
is per note. The count is bounded by distinct installs written from, not by
sessions. Peer retirement is a Housekeeping job, not a runtime concern.

### Decision 9 — engram-level shared state, one file per peer

Each device writes a small database to
`<engram>/.brainframe/shared/<peerId>.db`. Its first tenant is the **identity
map**: engram-relative path, ULID, and merge policy for the notes this device
minted. No op-log, no content, no hashes — a busy engram's map is measured in
kilobytes.

`shared/<peerId>.db` rather than a narrower name like `ids.sqlite`, for the
same reason Decision 2 chose `metadata.db` over `catalog.db`: the identity map
is the first tenant, not the only one. Engram-level state that must agree
across devices — later perhaps saved searches, pinned notes, or template
definitions — belongs in the same file rather than accreting a new dotfile per
concern.

**What may live here.** The file is general-purpose but not unbounded, and
three properties decide membership:

- **It describes the engram or its notes, never a device.** Content hashes,
  scan state, and the peerID fail this and stay in `metadata.db` — Decision 5
  spells out what sharing a hash destroys.
- **It has a deterministic merge rule, and carries the stamp that rule needs.**
  Every reader must reach the same answer from the same set of files without
  coordinating. In practice that means every row carries `hlc` and `peer`, so
  contradictory claims resolve by the locked comparator; a future tenant that
  cannot be stamped that way does not belong here.
- **It is bounded, and does not grow with edit history.** The whole-file
  rewrite below is cheap only while the payload is small. The op-log fails this
  test, which is why it is not here.

Four properties define the file itself:

- **One writer per file — but any device may write about any note.** The
  filename *is* the writer's identity, so no two installs write one path and no
  file-level conflict can be created. That is a claim about *files*, not about
  rows. A rename or a deletion is performed by whichever device notices it,
  which is frequently not the device that minted the ULID, so each device
  records what it knows about any note in its own file and contradictions are
  resolved on read.
- **Atomically replaced.** Written with `VACUUM INTO` to a temporary name, then
  renamed over the target — `VACUUM INTO` refuses a destination that exists.
  The result is self-contained and internally consistent, with no `-wal` or
  `-shm` sidecars, and a sync service never observes a partial file. Because
  the map is tiny, rewriting it whole costs nothing; this is the discipline
  that would have been ruinous applied to an op-log.
- **Read every file, write exactly one.** A device scans the directory and
  unions every file's rows, including its own. Peers appear as files, so
  nothing needs to be discovered.
- **Deterministically merged, by two rules answering different questions.**
  Each row is `(ulid, path, merge_policy, deleted, hlc, peer)`, where `hlc` and
  `peer` stamp the moment the writing device recorded it.

  1. **Contradictions about one ULID** — two files each carrying a row for it —
     resolve by the **locked tiebreak comparator**: HLC first, peerID second.
     A rename is a row with a new `path`; a deletion is a row with `deleted`
     set. Both are ordinary field updates needing no special case.
  2. **Two live ULIDs claiming one path** — both devices cold-minted for the
     same file — elect the **lowest ULID**, and the loser re-keys. ULIDs are
     time-ordered, so this is "the earliest mint wins". It deliberately does
     *not* use the comparator: this is not a last-writer-wins over one value
     but an election between distinct identities, and the answer that should
     survive is the earliest rather than the latest.

**Why the rows carry a clock.** An earlier draft had rows union by ULID with no
stamp, on the assumption that a ULID is minted once and never changes. The
ULID does not change, but the row about it does, and the mutation is not always
made by the minter. Without a stamp, this goes wrong silently:

1. Device A mints `01ABC` for `trails/cedar.md` and writes it to `A.db`.
2. The user renames the file to `journal/cedar.md` outside the app.
3. Device B scans first and infers the move — correctly, per Decision 7.
4. B cannot write `A.db`, so if it records nothing the shared map still says
   `trails/cedar.md`.
5. Device C opens the engram cold, finds no row for `journal/cedar.md`, and
   mints a fresh ULID.

The map has then caused exactly the mis-identification it exists to prevent,
and — unlike a bad adoption, which surfaces — C's fresh ULID is
indistinguishable from an ordinary new note. Deletion has the same shape:
without somewhere to record a retraction, a path freed by a delete and reused
later adopts the dead note's ULID and resurrects its history under unrelated
content.

The stamp costs nothing that does not already exist. Every device has an HLC
and a peerID, and "What already exists" already requires that any new
last-writer-wins rule invoke the locked comparator rather than invent a second
one — satisfied here by construction.

**What a lost race costs.** If a delete and an edit are concurrent and the
delete wins, the file is still on disk with its content: the next scan finds a
file with no live catalog row and mints a fresh ULID for it. Content survives,
history does not, and Decision 7 already requires that class of loss to be
surfaced rather than silent. A lost rename race is cheaper still — one of two
paths wins and the other device moves its file to match.

**The identity map is authoritative for adoption, advisory otherwise.** When
the local catalog has no row for a path, the map's ULID is adopted. When the
catalog already has one, the map is reconciled against it by the rule above.
The catalog remains the operational source of truth for everything the running
app does.

**Re-keying is cheap, which is what makes the tiebreak affordable.** A `Change`
carries its `OperationId`, its dependencies, and its payload — never a document
id. The document id exists only as the `document_id` column in
`crdt_lf_sqlite`'s tables, so adopting a different ULID is two `UPDATE`
statements against `changes` and `snapshots`, with history preserved intact.

**No sync mechanism is named or supported.** This design does not promise that
Dropbox, OneDrive, iCloud Drive, Syncthing, a roaming profile, or a network
share works. It promises properties:

> Files in `.brainframe/shared/` are written by exactly one device each, replaced
> atomically, and never modified in place. Any mechanism that transfers whole
> files and preserves renames carries them correctly.

That statement is testable, does not age, and does not commit the project to a
vendor matrix.

**What the map does not carry.** A device that cold-copies an engram gets the
right ULIDs and an **empty op-log**. Identity travels; history does not. That
is the trade, and it is why the map stays small enough to be safe in a synced
folder.

**A constraint this hands to #67.** When changes finally do cross the network,
`importChanges` topologically sorts a batch, applies what it can, and catches
*every* exception a change raises — `CausallyNotReadyException` included —
skipping it silently. A change whose dependencies are absent is never stored,
so supplying its ancestors afterwards does not heal it. The only signal is the
return value. Measured against `crdt_lf` 3.5.0 and pinned by
[import_causal_readiness_test.dart](../../test/crdt/import_causal_readiness_test.dart):

| Import | Applied | Result |
| --- | --- | --- |
| an orphan alone | 0 of 1 | dropped; document untouched, version empty |
| its ancestors | 2 of 2 | orphan still absent — it was not queued |
| the orphan again | 1 of 1 | fully recovered |
| the complete set, reversed | 3 of 3 | correct; the sort handles the order |

So #67 must import a causally-complete batch and must treat a short return
count as a retry signal rather than a success. An importer that ignores the
return value loses data with no exception, no log, and no queue to inspect.

## Platform consequences

- **`sqlite3_flutter_libs` becomes a real dependency.** Linux and macOS have a
  loadable system sqlite3; Android, iOS, and Windows generally do not. The
  smoke test's header already flags this, and deliberately did not add the
  package while nothing in `lib/` used SQLite. That changes here.
- **Web has no CRDT, and that is consistent.** `dart:ffi` does not exist on the
  web, so `crdt_lf_sqlite` cannot load there. Web already has no filesystem
  store and offers only the read-only built-in engrams, so it needs neither a
  catalog nor an op-log. The seam must keep SQLite behind the existing
  conditional-import boundary so a web build never reaches it.
- **Read-only engrams have neither catalog, op-log, nor identity map.** The
  asset-backed tutorial and help engrams cannot drift and cannot be edited.
  `Engram.readOnly` already gates this, and nothing may be written into an
  asset-backed engram's `.brainframe/`.
- **Windows needs a `Runner.rc` fix before debug and release are separable.**
  `path_provider_windows` builds its directory from `CompanyName\ProductName`
  in the `VERSIONINFO` resource, and
  [Runner.rc](../../windows/runner/Runner.rc) sets both unconditionally — so
  Windows is the **only** target where a debug build and a release build
  resolve to the *same* `metadata.db`, with the same peerID, opened by two
  processes. The fix is local — give `ProductName` a `_DEBUG` variant
  (`BrainFrame.debug`), which the same file already does for the dev icon. This
  is a prerequisite of Decision 2, not a polish item, and it is already a
  present-day settings bug: `shared_preferences_windows` writes into that same
  `CompanyName\ProductName` directory, so the two builds share device settings
  today. Tracked as **#117**.
- **No backup-exclusion configuration is required on any platform.**
  `metadata.db` may be backed up and restored freely. A restored copy
  duplicates a peerID, which is inert until two logs meet, and Decision 8 puts
  detection in #67's handshake where that actually happens. Nothing here needs
  a platform manifest change.

## Performance envelope

The locked storage model puts **one Fugue element per character**, so a note's
cost in memory is set by its length, not by its edit history. Measured against
`crdt_lf` 3.5.0 on Linux desktop, building a handler from a single insert and
then materializing it:

| Characters | Build | `value` | 100 scattered edits | Resident |
| ---: | ---: | ---: | ---: | ---: |
| 120,000 | 153 ms | 9 ms | 5 ms | 87 MB |
| 240,000 | 235 ms | 16 ms | 2 ms | 113 MB |
| 480,000 | 541 ms | 31 ms | 2 ms | 225 MB |

Two of those columns are reassuring and one is not.

**The operations are cheap and the scaling is linear.** Build and
materialization are both O(n) with small constants, and a hundred scattered
single-character edits cost about 2 ms even at half a million characters — so
index-to-node resolution is not a linear scan, and the operation volume
Decision 6 generates is not the problem. A dispersed reconciliation is
affordable once its diff is chunked.

**Memory is the constraint, at roughly 470 bytes per character.** That is the
cost of the tree itself: a `Map<FugueElementID, FugueNodeTriple>` entry per
character, each holding two element IDs and two child lists. Extrapolating
linearly — which the measurements support — a 3.2 MB note such as *War and
Peace* as a single note needs on the order of **1.5 GB resident** to be open,
with materialization around 200 ms every time Decision 6 re-materializes it.

That is a structural property of the locked storage model, not a tuning
problem, and it lands hardest exactly where headroom is smallest: iOS
terminates around 1-2 GB, and a 2 GB Raspberry Pi cannot open such a note at
all. Desktop absorbs it; the other targets do not.

Nothing here is a reason to reopen the storage model, which is settled and
correct for the notes people actually write. It is a reason to know the ceiling
before a user finds it, and to decide deliberately what happens above it —
refuse to open, open read-only without CRDT backing, or split the note — rather
than discovering the answer as an out-of-memory kill. That decision is recorded
as an open question below rather than made here, because the right answer
depends on measurements from the other targets that do not exist yet.

To reproduce: build a `CRDTFugueTextHandler` at each size, timing the insert,
the `value` getter, and a transaction of scattered inserts, sampling
`ProcessInfo.currentRss` around each. Numbers above are one desktop run and are
indicative, not a budget.

## What changes in `lib/`

A new `lib/engram/crdt/` holding the catalog, the op-log adapter, the
materializer, the reconciler, and the policy table. Above it:

- `DocumentEditController` stops calling `writeString`. Its flush becomes
  "apply the buffer diff as operations, then materialize" — the same call as
  reconciliation step 3–5, which is a genuine unification rather than two
  parallel paths.
- The engram open path gains opening (or creating) `metadata.db`, injecting the
  CRDT schema, reading `.brainframe/shared/` to adopt known ULIDs, and running a
  first scan — the last two behind the UI, per the Performance envelope. The
  close path writes the map and closes the database.
- A reader/writer pair owns `.brainframe/shared/`: the `VACUUM INTO`-and-rename
  writer for this device's file, the directory scan that reads every peer's
  rows, and the two-rule merge — comparator per ULID, lowest-ULID election per
  path — with its re-keying `UPDATE`s. Every row this device writes is stamped
  with its HLC and peerID, including rows about notes another device minted. It
  reuses `DocumentEditController`'s existing debounce shape rather than
  inventing a second timer discipline.
- File-management and move detection gain a write to the shared database, not
  only to the catalog. A rename or delete that updates the catalog and stops
  there leaves the map stale, which is the silent failure Decision 9 describes.
- File-management operations (new note, rename, delete, move) route through the
  catalog so the app's own moves are recorded rather than rediscovered by
  content matching on the next scan.

## Testing

The frozen suite in `test/crdt/` is untouched. Everything here is a **new
layer** above it, with its own tests, and no assertion in the frozen suite may
be weakened to accommodate any of it — if something in this design cannot be
built without changing one, that is a finding to surface, per the spec's own
handoff rules.

The new tests that matter most, because they are the ones that fail late and
expensively otherwise:

- **Minimal-diff preservation.** Apply an external edit on device A while
  device B holds an unmerged concurrent insertion; assert B's insertion
  survives. This is the test that catches a replace-all diff, and a
  single-replica test cannot.
- **A dispersed edit stays cheap.** Reconcile a note whose line endings all
  changed CRLF to LF. This is the case that makes an unchunked `myersDiff`
  allocate gigabytes, and it is indistinguishable from a trivial edit until the
  diff is actually run — so it needs a test rather than a comment.
- **Reconciliation is atomic.** Interrupt a multi-segment edit script partway
  and assert the note is either fully reconciled or untouched, never half
  applied. This is what the single `runInTransaction` in Decision 6 buys, and
  nothing else in the suite would notice its removal.
- **Surrogate pairs survive a diff boundary.** Reconcile a note containing
  emoji where the edit lands adjacent to an astral-plane character; assert the
  materialized text is byte-identical and that no element was split.
- **Crash-ordering recovery.** Write the file, skip the catalog commit,
  rescan; assert self-healing with no lost or duplicated content.
- **Move detection**, including rename-with-edit and the below-threshold
  fallback.
- **Absence is not deletion** — a missing file with an incomplete scan must not
  tombstone.
- **Byte-stable materialization** across a save/reload cycle, including
  frontmatter with comments, quoting, and key ordering the user chose.
- **A cold copy adopts, rather than mints.** Copy an engram with its
  `.brainframe/shared/` to a second machine and open it; assert every note
  keeps its ULID and no new ones are minted. Then delete the map and repeat;
  assert fresh ULIDs and unchanged content. These are the two halves of
  Decision 9's promise, and the second is the degraded path people will
  actually hit.
- **The map merges deterministically, under both rules.** Have two devices
  cold-mint different ULIDs for one path; assert both converge on the lowest
  ULID and that the loser's history survives re-keying intact. Separately, have
  two devices write contradictory rows for *one* ULID; assert both resolve to
  the same row under the locked comparator.
- **A non-minting device's rename propagates.** Device A mints a note; device B
  detects the rename and records it; assert a third device reading the
  directory finds the note at its new path and adopts the original ULID. This
  is the silent failure in Decision 9 — nothing surfaces when it breaks, so
  only a test catches it.
- **A freed path does not resurrect a dead note.** Delete a note, create an
  unrelated file at the same path, rescan; assert a fresh ULID is minted and no
  history from the deleted note is attached to it.
- **A lost delete race keeps the content.** Delete on one device while another
  edits concurrently; assert the delete wins or loses deterministically, and
  that in either case the file's content still exists on disk and is reachable
  under some ULID.
- **The content hash never leaves the device.** Assert `materialized_hash`,
  size, and mtime appear in no file under `.brainframe/`. This is a
  one-line test guarding the failure written out in Decision 5, which is
  invisible until a second device holds unmerged operations.
- **Deleting `metadata.db` loses history, not content or identity.** Populate
  an engram, delete the database, reopen; assert every note's ULID is
  unchanged, content is unchanged, and history is empty.
- **The import contract still holds.**
  [import_causal_readiness_test.dart](../../test/crdt/import_causal_readiness_test.dart)
  characterizes `crdt_lf`'s silent-drop behaviour. It is not a test of
  BrainFrame code; it exists so that an upstream change to buffering, throwing,
  or reporting fails here rather than in a user's engram at #67.
- **Two devices over one folder converge.** Two independent catalogs and
  op-logs (two `metadata.db` files, two peerIDs) pointed at one engram
  directory, edited alternately with a scan between; assert both converge on
  the same content. This is the direct test of "locally arriving CRDTs work,"
  and it is what proves the fresh-id consequence is benign rather than merely
  argued to be.

## Suggested phasing

Design is whole; implementation need not land at once.

1. **Catalog, identity, and durable op-log**, with BrainFrame as the only
   writer. Notes get ids and history; nothing external is reconciled yet.
2. **The identity map** — Decision 9's writer, reader, and merge rule, plus the
   Windows `Runner.rc` fix (**#117**), without which Windows debug and release
   builds share one database and step 2's guarantees are false there. Small,
   and worth landing early: a note minted before the map exists is a note whose
   identity never travels.
3. **Materialization and editor rewiring.** The file becomes a projection.
4. **Scan and reconciliation** — Decisions 6 and 7. This is where "locally
   arriving CRDTs work fully" becomes true.
5. **`blobLww` for binary content.**

Op-log exchange is deliberately not in this list — it is **#67**'s, and this
design's job is to hand it a merge rather than a conflict. Step 4 is the one
with real difficulty in it; steps 1 through 3 are mostly plumbing, and are
worth landing first precisely so step 4 has a stable floor.

## Consequence: identity is shared, history is not

This falls out of Decisions 2 and 9 and deserves stating on its own, because it
is the one place where a choice made here constrains **#67**.

Two devices opening one engram — over Dropbox, a network share, or a plain copy
— agree on every note's ULID, because the identity map travels with the folder.
They build **separate op-logs keyed to the same `document_id`**. Content
converges immediately through Decision 6, with no network code: each device
sees the other's edits as ordinary file drift and reconciles them as a minimal
diff. What differs is that each holds its own private history of how it got
there.

**That is what makes #67 an ordinary merge.** Two histories over one document
combine the way any two replicas of one document combine. There is no winning
ULID to elect and no losing history to discard, which is precisely the outcome
a device-local catalog could not offer.

**The exception is a copy that leaves `.brainframe/shared/` behind** — selective
sync, a `cp` of the markdown alone, an archive built by a tool that skips
dotfiles, or an engram created before this design shipped. Such a copy mints
fresh ULIDs, and #67 then has to elect a winner per note, with the loser
keeping content and losing history. Re-keying is two `UPDATE` statements, so
the machinery is cheap; the loss is the history, not the work.

**No prompt on open.** An engram whose notes have no catalog entries and no
identity map is a normal, recoverable situation rather than an error to
interrogate the user about. Minting is reversible, most users cannot answer "is
this engram from another machine?", and refusing to open an engram until an
unbuilt transport can reach an unreachable peer would trade a possible history
loss for a certain outage. Housekeeping surfaces it instead: peers seen, notes
adopted from the map, notes minted locally.

## Open questions

They are not all the same kind of question, and the difference decides which
ones may survive into an accepted document. **Parked** questions need data that
does not exist yet; recording them is the right answer. **Answerable now**
questions need an hour with a library already in `pubspec.yaml`, and leaving
one unanswered inside a decision is how a design acquires a soft spot nobody
remembers is there.

One such question has already been retired this way: how `crdt_lf` treats a
change whose dependencies have not arrived. It is answered in Decision 9 and
pinned by
[import_causal_readiness_test.dart](../../test/crdt/import_causal_readiness_test.dart)
rather than tracked as an issue, because the answer was an hour away in an
installed dependency and it decides how defensive the importer must be.

### Parked — waiting on data that does not exist yet

- **The similarity threshold's value.** Decision 7 now names the metric — a
  shingled content sketch — but the shingle size, sketch width, and the cutoff
  itself still need choosing against the real fixture engram rather than in the
  abstract. Picking them wrongly fails in one direction only: too low
  re-associates unrelated notes and merges their histories, which is worse than
  too high, so bias toward missing a match.
- **Snapshot and compaction policy.** Case 5b of the frozen suite pins that
  garbage collection can strand a peer below the frontier. Purely local,
  single-device use has no stranded peers, so this can be deferred — but it must
  be settled before **#67**, since that is the moment peers below the frontier
  become possible. Tracked as **#118**, whose scope narrows with this revision:
  there are no export files to compact, only the local op-log.
- **The note-size ceiling.** "Performance envelope" above measures roughly 470
  bytes per character, putting a 3.2 MB note near 1.5 GB resident — comfortable
  on desktop, fatal on iOS and on a 2 GB Pi. The measurement exists; the policy
  does not, and setting one needs real numbers from the other targets. Tracked
  as **#124**, and hardware-blocked until those targets can be measured.

### Decided during review — recorded so it is not relitigated

- **Retractions and non-owner updates in the identity map: decided.** Review
  found that Decision 9's original "union by ULID, lowest wins" rested on an
  assumption that each ULID is only ever written by the device that minted it.
  Renames and deletions are performed by whichever device notices them, so
  rows now carry an HLC and peerID stamp and contradictions resolve by the
  locked comparator. Decision 9 records the reasoning and the silent failure
  that motivated it. Tombstones are a `deleted` field on an ordinary row rather
  than a separate mechanism.
- **Stamping the ULID into YAML frontmatter: decided, no.** Decision 1 reserves
  an `id:` frontmatter key as an additive *hint* — written and read, never
  trusted — and the question was whether to build it now. It is not being
  built.

  The value is narrower than it first appears. A **pure move** is already
  handled by content-hash match in Decision 7, with no hint and no history
  lost, so the stamp does nothing there. Its only cell is move *and*
  significant edit in one window, falling below the similarity threshold — a
  rare case intersected with a rare case. Nor does the identity map cover it:
  the map is keyed by path, so a rename is a lookup miss.

  Against that: every note in every engram carries a machine token forever,
  adopting an existing engram rewrites thousands of files on first open, and
  ULIDs are ours rather than the user's. Decision 4's rule settles it — the
  stamp is precisely a thing only we can read.

  The residual risk is bulk reorganization, which is rare but **correlated**:
  one restructuring touches many notes at once, and history loss goes unnoticed
  because history is invisible until sought. That is answered by the content
  sketch in Decision 7, which attacks the same case without touching a file the
  user owns, and by Decision 7's requirement that the below-threshold case be
  surfaced rather than silent.

  Reversible if evidence arrives. If real use showed move-with-edit happening
  often enough for history loss to become routine, the stamp is purely additive
  and can be built then. Decision 1's reservation stays in place for exactly
  that reason.
