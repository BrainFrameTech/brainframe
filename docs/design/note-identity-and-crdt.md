# Note identity and local CRDT storage

- **Status:** draft (2026-08-16) — *not accepted*; open for refinement
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

The id lives in a **catalog table in the engram's `metadata.db`** (Decision 2),
keyed to the note's current engram-relative path. It is **not** written into
the markdown file. Because that database is device-local, so is the id — see
"Consequence: note identity is device-local" below.

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
addition if interop ever demands it, so it is reserved rather than built.

### Decision 2 — one device-local database per engram, in Application Support

Each engram gets exactly **one** SQLite database, holding BrainFrame's own
tables *and* the `crdt_lf_sqlite` tables, opened by BrainFrame and injected via
`CRDTSqlite.fromDatabase`. It lives in `Library/Application Support`, keyed by
the engram's ULID — **not** inside the engram:

```text
<application support>/
  engrams/
    <engram ULID>/
      metadata.db          ← catalog, op-log, and future per-engram state
```

`metadata.db` rather than a narrower name like `catalog.db`: the catalog is the
first tenant, not the only one. Per-engram state that is device-local and not
user content — snapshot bookkeeping, scan state, later the search and graph
indexes — belongs in the same file, and a name describing only the first table
leaves the next reader wondering whether they are in the right place.

**One database, not one per peer.** `crdt_lf_sqlite`'s `changes` table is keyed
`PRIMARY KEY (document_id, change_id)`, and `change_id` is
`OperationId.toString()`, which renders as `peerId@hlc`. The peer is therefore
*already* part of every row's key, so changes from any number of peers coexist
in one table with no possibility of collision, and `document_id` separates the
notes. A per-peer file would buy nothing the schema does not already give.

**Why Application Support and not the engram.** The database is not
file-syncable. A SQLite file is a page-structured binary with internal
consistency invariants; a sync service that merges, partially transfers, or
last-writer-wins two divergent copies produces a file that is not stale but
*corrupt* — silently and totally. Since an engram folder living in iCloud or
Dropbox is an explicitly supported arrangement, anything placed inside the
engram must survive being file-synced. The database cannot, so it does not go
there. This keeps [engram-storage.md](engram-storage.md)'s existing rule intact
rather than amending it.

**The peerID argument points the same way, independently.** Decision 8 stores
this device's `PeerId` alongside its op-log. If that database travelled inside
the engram folder, a second device opening a copied or synced engram would
inherit the *first* device's peerID and stamp its own operations with it. Two
devices sharing one peerID breaks the tiebreak comparator's uniqueness
assumption outright — genuinely concurrent operations stop being merely tied and
become indistinguishable. A device-local database makes a device-local identity
the natural, hard-to-get-wrong default.

**The cost, stated plainly: history does not travel with the engram folder.**
Copying an engram to a second machine carries the markdown and nothing else —
the new device sees ordinary files with no history. That is the correct trade
(an absent database is recoverable, a corrupt one is not), and history transfer
is properly **#67**'s job, moving `Change` objects over a transport rather than
a binary file through a folder. But it has a consequence for *identity* that is
not #67's job, and that is the open question below.

**One note on the shared-database test.**
[sqlite_shared_database_test.dart](../../test/crdt/sqlite_shared_database_test.dart)
still asserts exactly the right thing — BrainFrame's tables and the CRDT tables
must co-exist in one consumer-owned database — and that property stays
load-bearing here. Only its header's stated *motivation* ("one file per engram
is what makes an engram copyable, backup-able, and syncable as a unit") is
superseded: the file is not inside the engram and is not what makes it portable.
The assertions stand; the comment should be corrected when this is implemented.

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
   stamped with this device's peerID and current HLC.
5. Re-materialize. If the result differs from the file — which it will whenever
   unmerged operations from another device were also pending — write it back
   through Decision 4's path.
6. Commit the new `materialized_hash`.

**The minimality of step 3 is the single most important rule in this
document.** The naive implementation — delete everything, insert the new text —
converges, passes a two-replica test, and is catastrophically wrong: it
tombstones every element another device might concurrently be editing, so every
concurrent remote insertion is discarded. Nothing about it looks broken until a
second device exists. A line-level diff refined to characters within changed
regions keeps operation counts proportional to the actual edit.

The edit script must be computed in **identity space, not offset space**, which
is the invariant the frozen suite exists to defend. A diff naturally produces
offsets; converting them to handler operations is where that invariant is at
risk, and it is the place to be most careful.

**Attribution is honest by construction.** Synthesized operations carry this
device's peerID because we genuinely do not know who made the external edit.
They are indistinguishable from local edits, which is the correct answer rather
than a limitation.

**This is the same machinery #85 replaces.** A CRDT-aware editor emits real
operations instead of a reconstructed diff, and when it lands it bypasses steps
2–4 for the in-app path. The reconciliation path stays, because external edits
never stop arriving.

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
- **Below the threshold** — treat as a delete plus a create, and **surface it**.
  This loses that note's history, which is a real cost, so it must be visible
  rather than silent. This case is the honest price of Decision 1's rejection
  of a frontmatter id, and it is the strongest argument for the reserved hint.
- **A catalog path that is gone, with no candidate** — tombstone the note.

**Absence is not deletion.** A file missing because a drive is unmounted, an
engram is unavailable, or iCloud has not materialized a `.icloud` placeholder
must never tombstone anything. Only tombstone when the scan is known-complete
and the file is confirmed absent. The storage design already carries an
"unavailable" state for engrams; notes need the same state for the same
reason.

### Decision 8 — device identity is per device, per engram

`crdt_lf` needs a stable `PeerId` — a UUID — for this device. It is minted on
first write to an engram and stored in that engram's `metadata.db`, not in
device settings, so it lives and dies with the op-log its operations are
stamped with. A peerID that outlived its log, or a log whose peerID could not
be recovered, would both break the tiebreak comparator's totality.

Because that database is device-local by Decision 2, this is automatically a
*per device, per engram* identity — the property that must hold, since two
devices sharing a peerID would make genuinely concurrent operations
indistinguishable rather than merely tied.

Scoping per engram rather than one identity per device also keeps engrams
independent, and avoids leaking a correlatable device identifier across
unrelated engrams.

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
- **Read-only engrams have neither catalog nor op-log.** The asset-backed
  tutorial and help engrams cannot drift and cannot be edited. `Engram.readOnly`
  already gates this.

## What changes in `lib/`

A new `lib/engram/crdt/` holding the catalog, the op-log adapter, the
materializer, the reconciler, and the policy table. Above it:

- `DocumentEditController` stops calling `writeString`. Its flush becomes
  "apply the buffer diff as operations, then materialize" — the same call as
  reconciliation step 3–5, which is a genuine unification rather than two
  parallel paths.
- The engram open path gains opening (or creating) `metadata.db`, injecting the
  CRDT schema, and running a first scan; the close path closes the database.
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
- **Crash-ordering recovery.** Write the file, skip the catalog commit,
  rescan; assert self-healing with no lost or duplicated content.
- **Move detection**, including rename-with-edit and the below-threshold
  fallback.
- **Absence is not deletion** — a missing file with an incomplete scan must not
  tombstone.
- **Byte-stable materialization** across a save/reload cycle, including
  frontmatter with comments, quoting, and key ordering the user chose.
- **Two devices over one folder converge.** Two independent catalogs and
  op-logs (two `metadata.db` files, two peerIDs) pointed at one engram
  directory, edited alternately with a scan between; assert both converge on
  the same content. This is the direct test of "locally arriving CRDTs work,"
  and it is what proves the device-local-identity consequence is benign rather
  than merely argued to be.

## Suggested phasing

Design is whole; implementation need not land at once.

1. **Catalog, identity, and durable op-log**, with BrainFrame as the only
   writer. Notes get ids and history; nothing external is reconciled yet.
2. **Materialization and editor rewiring.** The file becomes a projection.
3. **Scan and reconciliation** — Decisions 6 and 7. This is where "locally
   arriving CRDTs work fully" becomes true.
4. **`blobLww` for binary content.**

Step 3 is the one with real difficulty in it; steps 1 and 2 are mostly
plumbing, and are worth landing first precisely so step 3 has a stable floor.

## Consequence: note identity is device-local

This falls out of Decision 2 and deserves stating on its own, because it is the
one place where a choice made here constrains **#67**.

Since the catalog lives in a device-local database, two devices opening the
same engram folder — over Dropbox, or via a plain copy — independently mint
**different** ULIDs for the same file. Each builds its own CRDT document and its
own history for `trails/cedar-marsh.md`.

**Locally, this is harmless, and the reason is Decision 6.** Each device sees
the other's edits arriving as ordinary file drift and reconciles them as a
minimal diff. Content converges on both devices with no network code and no
corruption; the only thing that differs is that each device holds its own
private history of how it got there. A shared folder between two devices
already works under this design.

**At #67 it becomes a real decision.** Two documents describing one file cannot
be merged into a unified history — a device must elect a winning ULID and
absorb its own current content into the winner. That is not new machinery: it
is exactly Decision 6's reconciler, pointed at a document that arrived over the
wire instead of a file that changed on disk. So the cost is bounded and
concrete — the losing device keeps its *content* and loses its *history* — but
it is a cost, and it is paid once per device pair.

The alternative, if that is judged too expensive, is a small **portable
identity map** in the engram — a text file beside `engram.json` mapping paths
to ULIDs. It does not have the database's syncability problem: a text map
mangled by a sync service is repairable and human-readable, not destroyed, and
last-writer-wins on a mostly-append map is benign. That would make ULIDs agree
across devices from the start and give #67 one document per note.

**Recommendation: defer it.** It is additive, it costs nothing local, and the
degradation path above is real rather than theoretical. Revisit when #67 is
designed, with the cross-device history question actually in front of us.

## Open questions

- **The similarity threshold** in Decision 7 needs a concrete value and metric,
  which is better chosen against the real fixture engram than in the abstract.
- **Snapshot and compaction policy.** Case 5b of the frozen suite pins that
  garbage collection can strand a peer below the frontier. Purely local,
  single-device use has no stranded peers, so this can be deferred — but it must
  be settled before **#67**, since that is the moment peers below the frontier
  become possible.
- **Large notes.** The frozen suite explicitly excludes performance. A
  multi-megabyte note as one Fugue sequence has a cost that should be measured
  before it is discovered.
- **Whether the reserved frontmatter hint should simply be built now.** It
  turns Decision 7's worst case from "history lost, warning shown" into "always
  re-associated." The case against it is Decision 1's; the case for it is that
  Decision 7's fallback is the only place in this design where user data is
  knowingly discarded.
