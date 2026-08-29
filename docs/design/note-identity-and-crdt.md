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

The id lives in a **catalog table** (Decision 2), keyed to the note's current
engram-relative path, in `metadata.db` locally and in the exported state file
that travels with the engram. It is **not** written into the markdown file.
Ids therefore agree across devices that receive the state directory, and are
re-minted by a device that does not — see "Consequence: note identity travels,
but only with the state directory" below.

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

### Decision 2 — a device-local cache and a portable export

Each engram has exactly **two** SQLite artifacts. They have different jobs,
different lifetimes, and different rules, and keeping them straight is what
makes the rest of this design small.

| Artifact | Where | Role |
| --- | --- | --- |
| `metadata.db` | platform app-data directory, keyed by engram ULID | device-local **working cache** |
| `<peerId>.sqlite` | `<engram>/.brainframe/state/` | this device's **durable export** |

```text
<app data root>/                    <engram>/
  engrams/                            .brainframe/
    <engram ULID>/                      engram.json
      metadata.db  ← cache              state/
                                          <peerId>.sqlite  ← durable
```

BrainFrame opens `metadata.db` itself and injects the CRDT schema via
`CRDTSqlite.fromDatabase`, so the catalog, the op-log, this device's peerID,
and later the search and graph indexes all share one connection and one
transaction boundary. Decision 9 covers how the export is produced and read.

**`metadata.db` is a cache — a guarantee, not a description.** Everything in it
is either exported (Decision 9) or rebuildable by scanning the engram's
markdown. So the recovery action for *any* problem this design can produce — a
wrong id, a stale catalog, a corrupt database, a device restored from someone
else's backup — is one sentence:

> **Delete `metadata.db`. It rebuilds.**

That is the entire diagnostic tree, and it is deliberate. A power user should
never need to reason about op-logs, peers, or version vectors to repair an
engram; they need one safe action that cannot make things worse. Two
constraints keep the promise honest:

- **The export runs on clean shutdown**, not only on its debounce timer, so
  deleting the cache costs at most a crash's worth of *history* — never
  content, which is on disk as markdown regardless.
- **Human-relevant tables stay human-readable.** `path`, `ulid`,
  `merge_policy`, `peer`, `last_seen` are plain columns, so
  `sqlite3 metadata.db 'select path, ulid from catalog'` answers a real
  question in any SQLite browser. Operation payloads stay opaque blobs —
  nothing a person needs to read does.

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
a roaming profile is copied between machines at logon and logoff. A roamed
cache is not a correctness disaster now that the nonce in Decision 8 catches a
cloned identity, but it is still a live database copied out from under its
writer, and it would silently inflate a roaming profile that users already
complain is slow. `getApplicationCacheDirectory()` is the only `path_provider`
call that reaches the non-roaming `LocalAppData`; its name is an abstraction
leak, not a claim that the contents are disposable. Pin the mapping with a test
asserting the resolved path is under `LocalAppData`, because nothing else stops
an upstream change — or a well-meaning cleanup that "fixes" the odd-looking
call — from moving it back. The same call must **not** be reused on Linux,
where it resolves to `$XDG_CACHE_HOME` and invites a disk cleaner to delete an
op-log mid-session.

`$XDG_DATA_HOME` rather than `$XDG_CACHE_HOME` on Linux is deliberate for the
same reason. The word "cache" in this decision means *rebuildable from the
engram*, not *disposable at any moment by another program*.

**Debug and release builds are separate stores, by construction.** Every path
above derives from the platform application identity, and
[debug-build-identity.md](../debug-build-identity.md) already gives debug
builds a `.debug` suffix wherever there is an OS-level identity to suffix. A
debug build and a release build on one machine therefore hold different caches,
different peerIDs, and — writing to the same engram — two different export
files. They are two independent peers that happen to edit the same markdown,
which is the intended arrangement: the app stays usable in one window while
being developed in another. This is a **required property, not a side effect**,
and one target does not yet satisfy it — see "Platform consequences" for the
Windows fix.

**Why the live database is not in the engram, but the export is.** The
distinction is *mutation*, not SQLite.

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

An export is the opposite in every respect that matters: written once by a
single named writer, complete and self-contained when it appears, replaced
atomically, and never modified in place. Decision 9 is where those properties
are established and defended. A file with those properties is safe in a synced
folder — not because any particular sync service is trusted, but because there
is no interleaving for one to get wrong.

**One database, not one per note or per peer.** `crdt_lf_sqlite`'s `changes`
table is keyed `PRIMARY KEY (document_id, change_id)`, and `change_id` is
`OperationId.toString()`, which renders as `peerId@hlc`. The peer is therefore
*already* part of every row's key, so changes from any number of peers coexist
in one table with no possibility of collision, and `document_id` separates the
notes. Splitting by peer or by note would buy nothing the schema does not
already give — which is also why one export file can hold every peer's history
without ambiguity.

`metadata.db` rather than a narrower name like `catalog.db`: the catalog is the
first tenant, not the only one. Per-engram state that is device-local and not
user content — snapshot bookkeeping, scan state, later the search and graph
indexes — belongs in the same file, and a name describing only the first table
leaves the next reader wondering whether they are in the right place.

**What this costs, stated plainly.** History now travels with the engram
folder, which an earlier draft of this decision said it could not. The cost
moved rather than vanished: the engram directory grows by the size of the
op-log, and a device that copies an engram *without* `.brainframe/state/`
— a selective sync, a `cp` of only the markdown, an export from a tool that
does not know about the directory — still arrives with no history and mints
fresh ids. That case is now the exception rather than the default, and its
degradation is the one described under "Consequence: note identity travels,
but only with the state directory" below.

**One note on the shared-database test.**
[sqlite_shared_database_test.dart](../../test/crdt/sqlite_shared_database_test.dart)
still asserts exactly the right thing — BrainFrame's tables and the CRDT tables
must co-exist in one consumer-owned database — and that property stays
load-bearing here, for both artifacts. Only its header's stated *motivation*
("one file per engram is what makes an engram copyable, backup-able, and
syncable as a unit") needs correcting: that is now the export's job, and the
file it describes is the cache.

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

### Decision 8 — device identity is per device, per engram, and self-correcting

`crdt_lf` needs a stable `PeerId` — a UUID — for this device. It is minted on
first write to an engram and stored in that engram's `metadata.db`, alongside
the op-log its operations are stamped with. Scoping per engram rather than one
identity per device keeps engrams independent and avoids leaking a correlatable
device identifier across unrelated engrams.

The property that must hold is narrow and absolute: **two live writers must
never share a peerID.** Two devices stamping operations with one identity makes
genuinely concurrent operations indistinguishable rather than merely tied,
which breaks the tiebreak comparator's uniqueness assumption outright.

"Device" here means **build install, not machine**. A debug and a release build
on one computer resolve to different caches (Decision 2) and are therefore
different peers, deliberately: developing the app in one window while using it
in another must not produce two writers on one identity.

**The claim nonce.** `metadata.db` stores `(peer_id, nonce)`, where the nonce is
a random value minted with the peerID. This device's export file carries the
same nonce. Before every export, the writer reads the nonce out of the existing
`<peerId>.sqlite`:

- **Nonce matches, or the file is absent** — this device owns that peerID.
  Export proceeds.
- **Nonce differs** — some other install owns it. Mint a fresh peerID and
  nonce, and export under the new name. The previous file is left untouched.

That is the whole mechanism, and it replaces an entire apparatus. A
`metadata.db` restored from a phone backup, cloned to a second machine, or
copied by an image-based restore now **detects itself on first export** and
steps aside. Because the export is regenerable from the cache, the worst case
is one cycle of one device's export being overwritten before both settle on
distinct identities.

**Why not exclude the database from backups instead.** That was the obvious
alternative and it is worse on every axis. It needs platform configuration on
Android (`dataExtractionRules`) and iOS (`NSURLIsExcludedFromBackupKey`); it is
unenforceable on the three desktops against `restic`, Backblaze, or image-based
backup; and when it fails it fails **silently**, with two devices already
writing under one identity. The nonce is a check this codebase runs itself, on
every export, on every platform, with nothing for a user to configure and
nothing for an administrator to override. Depending on both would be worse than
depending on either, because the unverifiable mechanism would mask bugs in the
verifiable one.

**Why not tie the peerID to hardware.** Also considered, also rejected:

- **It does not deliver uniqueness.** `/etc/machine-id` is baked into golden
  images and cloned across VM fleets; MAC addresses are randomized on modern
  mobile and cloned by hypervisors; iOS `identifierForVendor` resets when the
  last app from a vendor is deleted; Android exposes no stable device id to
  unprivileged apps. The result is an identifier that is sometimes duplicated
  and sometimes reset — worse than random at the one job it was chosen for.
- **It is a privacy regression.** A hardware identifier stamped into every
  operation and shipped to every peer at #67 is a permanent, correlatable
  fingerprint in a log that never forgets, which is the opposite of the
  per-engram scoping above.
- **It detects rather than prevents**, and the nonce already detects, without
  reading anything about the machine.

**The cost of minting freely.** `VersionVector` is `Map<PeerId, HLC>` — one
entry per peer ever seen, 24 bytes each — and it is embedded in every
`Snapshot`, which is per note. Peers are therefore not free. The count is
bounded by *distinct installs written from*, not by sessions, because a
returning install reuses its stored identity; the genuine worst case is
non-persistent VDI, where the cache is wiped every logon and a peer is minted
daily. Peer retirement is a Housekeeping job, not a runtime concern.

### Decision 9 — the export is a whole-database snapshot, one file per peer

Each device periodically writes everything it knows to
`<engram>/.brainframe/state/<peerId>.sqlite`. Four properties define it, and
each one closes a specific failure:

- **Self-contained and internally consistent.** Produced with
  `VACUUM INTO`, which yields a fresh, compact, transactionally consistent
  database with no `-wal` or `-shm` sidecars, taken against the live cache
  without quiescing writers. (The Dart `sqlite3` binding exposes no online
  backup API; `VACUUM INTO` is plain SQL and needs none.)
- **Atomically replaced.** `VACUUM INTO` refuses a destination that already
  exists, so the sequence is: vacuum to a temporary name, then rename over the
  target. A sync service never observes a partially written file.
- **Single-writer.** The filename *is* the writer's identity, so no two
  installs ever write one path. There is no conflict to resolve because none
  can be created — and Decision 8's nonce is what keeps that true when a cache
  is cloned.
- **Complete.** Each file holds the entire op-log this device knows, its own
  and every peer's, plus the catalog. Any single file is therefore enough to
  reconstruct a working engram, which is what makes a partial sync or a
  vanished peer survivable. The cost is redundancy across files; compaction
  bounds it.

**Read every file, write exactly one.** Synchronization scans the directory,
imports every file that is not its own, and exports to the one that is.
Before #67 there is only ever one file and the loop is trivial — but writing it
as "resolve my file" would bake in the wrong shape, and the correct loop is not
larger.

**Causally-unready changes are dropped, not buffered.** `importChanges`
topologically sorts the batch, applies what it can, and catches *every*
exception a change raises — `CausallyNotReadyException` included — skipping it
silently. A change whose dependencies are absent is never stored, so supplying
its ancestors afterwards does not heal it. The only signal available is the
return value, which counts changes actually applied. Measured against
`crdt_lf` 3.5.0 and pinned by
[import_causal_readiness_test.dart](../../test/crdt/import_causal_readiness_test.dart):

| Import | Applied | Result |
| --- | --- | --- |
| an orphan alone | 0 of 1 | dropped; document untouched, version empty |
| its ancestors | 2 of 2 | orphan still absent — it was not queued |
| the orphan again | 1 of 1 | fully recovered |
| the complete set, reversed | 3 of 3 | correct; the sort handles the order |

Two consequences follow, and they are the reason this was worth settling before
implementation rather than after:

- **Import each peer file as one batch.** Because every file holds everything
  its device knows, a file is causally self-contained, and a self-contained
  batch is order-independent. Orphans then cannot arise at all. This is a
  second dividend from the completeness property above — it was chosen for
  bootstrap, and it happens to make the importer's hardest case unreachable.
- **Treat a short return count as a retry signal, not a success.** If
  `importChanges` returns fewer than it was given, changes were discarded and
  must be offered again. Nothing else will ever report it: there is no
  exception, no log, and no queue to inspect. An importer that ignores the
  return value loses data silently.

**No sync mechanism is named or supported.** This design does not promise that
Dropbox, OneDrive, iCloud Drive, Syncthing, a roaming profile, or a network
share works. It promises properties:

> Files in `.brainframe/state/` are written by exactly one device each,
> replaced atomically, and never modified in place. Any mechanism that
> transfers whole files and preserves renames carries them correctly.

That statement is testable, does not age, and does not commit the project to a
vendor matrix or to chasing behavior changes in software it does not own. It
also tells an advanced user why an untested tool will work, without anyone
having tried it.

**Costs to hold in view.** `VACUUM INTO` copies the whole database each cycle —
O(total size), not O(changes since last export) — so the debounce interval must
be generous, gated on a dirty flag, and revisited if engrams grow large enough
to make it the wrong shape. Each peer's file grows without snapshot-and-prune,
making compaction a real Housekeeping job rather than a someday one. A retired
device's file lingers until retired explicitly. And import should skip
unchanged peers on mtime and size, or every cycle re-parses everything.

**Startup must not replay.** Opening an engram is a `SELECT` against the
materialized catalog, never a replay of the op-log, and the scan fast-paths on
mtime and size with full content hashing only where those disagree. Import of
peer files happens in the background *after* the UI is live. This is a stated
requirement because the alternative is technically correct and unusable: an
engram with thousands of changes would spend its startup replaying history
before showing a single note.

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
- **Windows needs a `Runner.rc` fix before debug and release are separable.**
  `path_provider_windows` builds its directory from `CompanyName\ProductName`
  in the `VERSIONINFO` resource, and
  [Runner.rc](../../windows/runner/Runner.rc) sets both unconditionally — so
  Windows is the **only** target where a debug build and a release build
  resolve to the *same* `metadata.db`. Decision 8's nonce does not save this
  case and is not meant to: the two builds do not hold cloned caches, they hold
  one cache, with the same peerID and the same nonce, opened by two processes.
  The fix is local — give `ProductName` a `_DEBUG` variant
  (`BrainFrame.debug`), which the same file already does for the dev icon. This
  is a prerequisite of Decision 2, not a polish item, and it is already a
  present-day settings bug: `shared_preferences_windows` writes into that same
  `CompanyName\ProductName` directory, so the two builds share device settings
  today. Tracked as **#117**.
- **No backup-exclusion configuration is required on any platform.** An earlier
  draft called for `dataExtractionRules` on Android and
  `NSURLIsExcludedFromBackupKey` on iOS. Decision 8's nonce makes both
  unnecessary: `metadata.db` may be backed up and restored freely, because
  being restored onto another device is now a handled case rather than a
  hazard. Nothing here needs a platform manifest change.

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
  CRDT schema, importing any peer files in `.brainframe/state/`, and running a
  first scan — the last two behind the UI, per Decision 9. The close path
  exports and then closes the database.
- A new export/import pair owns `.brainframe/state/`: the debounced
  `VACUUM INTO`-and-rename writer, the nonce check from Decision 8, and the
  directory scan that imports every file that is not this device's. It reuses
  `DocumentEditController`'s existing debounce shape rather than inventing a
  second timer discipline.
- A rebuild path that reconstructs `metadata.db` from `.brainframe/state/` plus
  the markdown, so "delete the cache" is an implemented guarantee and not an
  aspiration.
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
- **The cache is rebuildable.** Populate an engram, export, delete
  `metadata.db`, reopen; assert the catalog, every note ULID, and the op-log
  come back. This is the test that keeps Decision 2's one-sentence recovery
  action true, and it is the one most likely to rot silently as tables are
  added.
- **A cloned cache steps aside.** Copy a populated `metadata.db` to a second
  cache location, point both at one engram, export from both; assert two
  distinct peerIDs, two export files, and no lost operations. This is
  Decision 8's nonce, and it is the direct replacement for the
  backup-exclusion configuration that is deliberately absent.
- **The import contract still holds.**
  [import_causal_readiness_test.dart](../../test/crdt/import_causal_readiness_test.dart)
  characterizes `crdt_lf`'s silent-drop behaviour. It is not a test of
  BrainFrame code; it exists so that an upstream change to buffering, throwing,
  or reporting fails here rather than in a user's engram.
- **An export is consistent under a concurrent writer.** Export while
  operations are being applied; assert the resulting file opens, passes
  `PRAGMA integrity_check`, and contains a prefix of history rather than a torn
  one.
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
2. **Export and rebuild** — Decision 9's writer, Decision 8's nonce, and the
   path that reconstructs `metadata.db` from `.brainframe/state/`. Small, and
   worth landing early: it is what makes the cache claim in Decision 2 true,
   and every later step inherits a safe recovery action. **Includes the Windows
   `Runner.rc` fix (#117)** — without it, Windows debug and release builds share
   one cache and step 2's guarantees are false on that platform.
3. **Materialization and editor rewiring.** The file becomes a projection.
4. **Scan and reconciliation** — Decisions 6 and 7. This is where "locally
   arriving CRDTs work fully" becomes true.
5. **`blobLww` for binary content.**

Multi-peer **import** is deliberately not in this list. Until #67 or a shared
folder exists there is only ever one file in `.brainframe/state/`, so the
import loop has nothing to read; Decision 9 fixes its shape so that adding it
later is not a rewrite. Step 4 is the one with real difficulty in it; steps 1
through 3 are mostly plumbing, and are worth landing first precisely so step 4
has a stable floor.

## Consequence: note identity travels, but only with the state directory

This falls out of Decisions 2 and 9 and deserves stating on its own, because it
is the one place where a choice made here constrains **#67**.

The catalog — every note's path and ULID — is part of the export. So an engram
copied *with* `.brainframe/state/` carries its identities: the receiving device
adopts the existing ULIDs rather than minting new ones, both devices build on
one document per note, and #67 inherits a single history to merge instead of
two to reconcile. That is the common case, and it is the reason the identity
map is a table in the export rather than a separate portable file: it needed a
container that merges, and the op-log already is one.

**The exception is a copy that leaves the state directory behind.** Selective
sync, a `cp` of the markdown alone, an archive built by a tool that does not
know the directory exists, or an engram created before this design shipped —
each arrives as ordinary files, and the receiving device mints fresh ULIDs.

**Locally, that remains harmless, and the reason is Decision 6.** Each device
sees the other's edits arriving as ordinary file drift and reconciles them as a
minimal diff. Content converges on both devices with no network code and no
corruption; the only thing that differs is that each holds its own private
history of how it got there.

**At #67 it is a bounded, once-per-device-pair cost.** Two documents describing
one file cannot be merged into a unified history — a device elects a winning
ULID and absorbs its own current content into the winner. That is not new
machinery: it is Decision 6's reconciler pointed at a document that arrived
over the wire rather than a file that changed on disk. The losing device keeps
its *content* and loses its *history*.

Re-keying is cheap, which is what makes electing a winner tolerable. A `Change`
carries its `OperationId`, its dependencies, and its payload — never a document
id. The document id exists only as the `document_id` **column** in
`crdt_lf_sqlite`'s tables, so adopting a different ULID for a note is two
`UPDATE` statements against `changes` and `snapshots`, with the history
preserved intact. A device that mints an id today can adopt the canonical one
whenever it learns it.

**So no prompt on open, and no blocking.** An engram whose notes have no
catalog entries and no state directory is a normal, recoverable situation, not
an error to interrogate the user about. Minting is reversible, most users
cannot answer "is this engram from another machine?", and refusing to open an
engram until an unbuilt transport can reach an unreachable peer would trade a
possible history loss for a certain outage. Housekeeping surfaces it instead:
peers seen, last export, and a rebuild action, with history linking available
once #67 exists.

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

- **The similarity threshold** in Decision 7 needs a concrete value and metric,
  which is better chosen against the real fixture engram than in the abstract.
- **Snapshot and compaction policy.** Case 5b of the frozen suite pins that
  garbage collection can strand a peer below the frontier. Purely local,
  single-device use has no stranded peers, so this can be deferred — but it must
  be settled before **#67**, since that is the moment peers below the frontier
  become possible. Tracked as **#118**.
- **Compaction policy for export files.** Decision 9 states that each file
  holds everything the device knows, which is what makes any single file
  sufficient to rebuild. Without snapshot-and-prune those files grow without
  bound, and the point at which that stops being acceptable has not been
  measured. The same question as the one above, arriving from the export side;
  tracked together as **#118**.
- **What happens above the note-size ceiling.** "Performance envelope" above
  measures roughly 470 bytes per character, putting a 3.2 MB note near 1.5 GB
  resident — comfortable on desktop, fatal on iOS and on a 2 GB Pi. The
  measurement exists; the *policy* does not. Refuse to open, open read-only
  with no CRDT backing, or split the note are all defensible, and choosing
  between them needs per-target numbers rather than the single desktop run
  recorded above.

### Deliberate design choice, still open

- **Whether the reserved frontmatter hint should simply be built now.** It
  turns Decision 7's worst case from "history lost, warning shown" into "always
  re-associated." The case against it is Decision 1's; the case for it is that
  Decision 7's fallback is the only place in this design where user data is
  knowingly discarded.
