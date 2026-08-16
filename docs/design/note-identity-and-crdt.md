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

The id lives in a **catalog table inside the engram's database** (Decision 2),
keyed to the note's current engram-relative path. It is **not** written into
the markdown file.

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

### Decision 2 — the op-log lives inside the engram, in per-device files

The engram's marker directory gains a database per writing device:

```text
<engram root>/
  .brainframe/
    engram.json            ← unchanged: engram identity
    catalog.db             ← this device's catalog + its own op-log
    oplog/
      <peerId>.db          ← one file per device that has ever written
```

Each device opens **its own** file for writing, via `sqlite3` directly, and
injects the `crdt_lf_sqlite` tables into it with `CRDTSqlite.fromDatabase`. It
opens every *other* device's file **read-only** and imports their changes. No
two processes ever write the same SQLite file.

**This amends an accepted design doc.**
[engram-storage.md](engram-storage.md)'s on-disk layout rules state that
app-level and derived state never goes in the documents directory, and that
derived per-engram caches live in `Library/Application Support`, keyed by
engram id.
That rule stands for genuinely derived state — the search index and the graph
index, which any device can rebuild from content alone. **The op-log is not
derived.** The markdown file is the *projection*; the op-log is the authority
that produced it and the only thing that can merge a concurrent edit. It cannot
be rebuilt from the file, so if it does not travel with the engram, then copying
an engram to a new machine, restoring it from backup, or handing it to a second
device silently discards all history and all merge capability.

**Why per-device files rather than one shared database.** The single-file layout
is what the shared-database test's rationale assumed, and it is simpler. It is
rejected because the storage design already promises that *"BrainFrame is never
guaranteed to be the sole writer"* — an engram folder in iCloud or Dropbox,
opened on a desktop and a laptop, is an explicitly supported arrangement. Two
processes writing one SQLite file through a file-syncing service is a
well-known corruption path, and the corruption is silent and total. Under
writer-owned files, the worst a file-sync service can do is deliver a stale or
half-written copy of *someone else's* log, which import either rejects or
applies partially — and a partially-applied CRDT log is not corruption, it is
simply a peer you have not fully caught up with.

The bonus is that this makes the thing actually asked for work end to end: a
change file appearing in a synced folder **is** a locally-arriving CRDT, with
no network code anywhere. That turns **#67** into a transport optimization over
a working model rather than the moment the model is first exercised.

The cost is honest: more files, a read-many/write-one open path, and a
retirement story for devices that no longer exist. Retirement rides with the
existing peer-retirement item noted under Housekeeping and is not built here.

**Conservative alternative, if the above is judged over-built:** keep one
`catalog.db` per engram, write only from one process, and declare
concurrently-file-synced engrams unsupported until **#67**. It is less
machinery and defers the multi-writer question. It is not recommended, because
"unsupported" here means "silently corrupts," and the arrangement is one the
storage design already invites.

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
first write to an engram and stored in that engram's catalog, not in device
settings, so it travels with the op-log that its operations are stamped with.
A peerID that outlived its log, or a log whose peerID could not be recovered,
would both break the tiebreak comparator's totality.

Scoping it per engram rather than per device also keeps engrams independent:
copying one engram elsewhere carries a coherent identity with it, and does not
leak a correlatable device identifier across unrelated engrams.

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
- The engram open path gains catalog opening, peer-file discovery, and a first
  scan; the close path releases every database handle.
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

## Suggested phasing

Design is whole; implementation need not land at once.

1. **Catalog, identity, and durable op-log**, with BrainFrame as the only
   writer. Notes get ids and history; nothing external is reconciled yet.
2. **Materialization and editor rewiring.** The file becomes a projection.
3. **Scan and reconciliation** — Decisions 6 and 7. This is where "locally
   arriving CRDTs work fully" becomes true.
4. **`blobLww` for binary content**, and per-device peer file import.

Step 3 is the one with real difficulty in it; steps 1 and 2 are mostly
plumbing, and are worth landing first precisely so step 3 has a stable floor.

## Open questions

- **Decision 2's per-device files** is the most debatable call here, and the
  conservative single-file alternative is stated alongside it. This is the
  first thing to push back on.
- **The similarity threshold** in Decision 7 needs a concrete value and metric,
  which is better chosen against the real fixture engram than in the abstract.
- **Snapshot and compaction policy.** Case 5b of the frozen suite pins that
  garbage collection can strand a peer below the frontier. Purely local use has
  no stranded peers, but per-device files reintroduce them the moment a second
  device exists. When to snapshot, and what frontier to keep, is reserved here
  and needs deciding before **#67**.
- **Large notes.** The frozen suite explicitly excludes performance. A
  multi-megabyte note as one Fugue sequence has a cost that should be measured
  before it is discovered.
- **Whether the reserved frontmatter hint should simply be built now.** It
  turns Decision 7's worst case from "history lost, warning shown" into "always
  re-associated." The case against it is Decision 1's; the case for it is that
  Decision 7's fallback is the only place in this design where user data is
  knowingly discarded.
