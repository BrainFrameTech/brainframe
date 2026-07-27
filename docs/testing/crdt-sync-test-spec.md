# BrainFrame — CRDT Sync: Edge-Case Test Specification

**Status:** Design-informing output of the sync research spike (Q1). Revised
for implementation handoff.
**Audience:** Claude Code, for rendering into executable tests during the
sync-layer implementation.
**Scope:** This document specifies the *behavioral* edge cases the sync data
model must handle correctly. It is deliberately implementation-agnostic about
the exact library API — it describes **what must be true after concurrent
edits converge**, not which method names to call.

---

## Handoff instructions for Claude Code (read first)

You are rendering this spec into an executable Dart test suite. Before writing
any test, internalize these rules — they govern *how* you build, not just what:

1. **This test suite is ground truth. Once written and reviewed, it is frozen.**
   When a test fails during implementation, the only permitted responses are
   (a) fix the implementation, or (b) surface the failing test to the human for
   an explicit, consciously-approved spec change. **You may never weaken,
   relax, broaden, or delete an assertion to make it pass.** Turning an
   exact-match into a `contains`, widening an expected-value set, or converting
   a byte-identity check into a length check are all prohibited edits. If you
   believe a test is wrong, stop and say so — do not edit it silently.

2. **This suite is pure in-memory unit testing of the data model — nothing
   else.** Replicas are plain in-process objects. Operation exchange between them
   is direct, in-harness method calls. The `exportChanges` / `importChanges` /
   snapshot round-trips in the serialization cases test `crdt_lf`'s **in-memory
   byte-level** serialization boundary — they are **not** persistence and **not**
   network, and must not be backed by either. **Do NOT introduce, mock, or depend
   on:** SQLite or any storage; the any-sync protocol or any transport/relay
   layer; an on-disk engram; or reading/writing markdown files or any filesystem
   access. If a test seems to need any of those, it is being built wrong — the
   data model is provable entirely in memory, and keeping it so is what makes this
   suite a clean checkpoint for the CRDT layer before the sync layer exists.

3. **Build the harness scaffolding first (see "Harness requirements"), then
   render the cases.** The scaffolding structurally enforces the cross-cutting
   requirements so individual tests can't accidentally skip them.

4. **Flag, don't paper over.** `crdt_lf` is the single CRDT library, and under
   the locked storage model BrainFrame uses **one handler type**:
   `CRDTFugueTextHandler` for the whole note (body + frontmatter). If `crdt_lf`
   cannot express a case, or resolves it differently from this spec, **that gap
   is a material finding — surface it to the human**, do not adapt the assertion
   to match the library's behavior and do not act on it upstream yourself.

5. **Assert convergence to a *specific value*, never merely that replicas are
   equal.** Two replicas that are identically corrupted are equal. A test that
   only checks "A == B" passes on shared corruption. Every convergence
   assertion must pin the exact expected materialized value.

6. **Deliverable is the test suite and its harness ONLY — build no production
   code.** Write the tests against `crdt_lf`'s **public API directly** (a replica
   is a `CRDTDocument` + a `CRDTFugueTextHandler`; materialize by reading the
   handler's value; merge via `exportChanges` / `importChanges`; reload via
   snapshot bytes). The **only** code you create beyond the tests is
   **test-support harness** (the peerID fixture, controlled-order merge helpers,
   the commutativity/idempotence wrapper, assertion helpers) — all living in the
   test tree.
   - **Do NOT create any BrainFrame production code** — no note model, no
     materialization layer, no sync engine, no storage adapter, nothing that
     would live in `lib/`. The rule is crisp: **`test/` is yours to build;
     `lib/` is not.**
   - **Tests not compiling because a BrainFrame type doesn't exist yet is the
     WRONG shape** — it means a test is reaching for a production abstraction.
     Rewrite it against `crdt_lf` directly. If a case genuinely cannot be
     expressed without a BrainFrame abstraction, that is a **finding to surface**,
     not a stub to create.
   - Tests going red because the *implementation* (the sync layer, built later)
     doesn't exist yet is a **different and expected** thing — but that comes
     after this suite is written and frozen, and it is not your job here. Your
     job is the suite.

---

## What this suite is (and is not)

**This suite verifies the properties of `crdt_lf` that BrainFrame's correctness
depends on, exercising the library directly.** It is *not* a general test of
`crdt_lf` (Mattia maintains that) and it is *not* a test of BrainFrame code
(none exists yet). It is the executable statement of **the contract BrainFrame
requires from its CRDT foundation** — the selection of what to test and what to
assert is driven entirely by BrainFrame's needs, which is what makes it a
BrainFrame artifact even though every call goes to the library.

It serves two purposes, both BrainFrame concerns:

1. **Pre-build validation.** Before BrainFrame's persistence and materialization
   layers are built *on top of* these behaviors, this suite proves the behaviors
   actually hold — so a false assumption fails now (red test), not in production
   (corrupted note).
2. **Permanent regression guard.** Because the tests hit the real library, a
   future `crdt_lf` version bump that changes any depended-on behavior fails
   here. This generalizes the emoji-regression guard (Case 3) to all the
   properties BrainFrame relies on.

The stages that come *after* this suite — on-disk persistence (SQLite), wiring
BrainFrame's note model onto `crdt_lf`, materializing markdown, then the any-sync
transport — all build on the foundation this suite establishes. That ordering is
deliberate: prove the foundation naked before anything sits on it.

### Two kinds of pinned value — they mean different things when they go red

Every assertion pins a specific value (instruction 5), but the pinned values
fall into two classes, and a reader diagnosing a future failure must know which:

- **Load-bearing guarantees** — properties that must *never* change: causality
  preservation under a broken clock (Case 3a), run-contiguity / no interleaving
  (Case 1), no crash on tombstoned identities (Case 2), convergence itself
  everywhere. **If one of these goes red, surface it to the human as a suspected
  `crdt_lf` regression (`#103`-class) — do NOT report it upstream yourself, and
  do NOT adapt BrainFrame to it.** The determination of whether to file an
  upstream bug is the human's to make; your job is to flag it clearly with the
  failing case and observed behavior.
- **Confirm-then-pin observations** — values marked "confirm against the
  implementation on first run, then pin it" (e.g. Case 2's exact
  reattachment string). These pin `crdt_lf`'s *observed* boundary behavior as
  BrainFrame's expected behavior. They were never a guarantee — just a behavior
  chosen to depend on. **If one of these goes red after a version bump, it is a
  library *change*, not necessarily a bug** — the correct response may be
  "the library shifted; decide how BrainFrame absorbs it," which could mean
  updating the pinned value (a conscious spec change per instruction 1), not
  filing a bug. Mark these assertions in-code as confirm-then-pin so the
  distinction survives into the test source.

## Context Claude Code needs before writing tests

BrainFrame's markup layer syncs note content across devices (phone, desktop,
NAS hub) that may edit **offline and concurrently**. Conflict resolution uses
CRDTs, all provided by a single library, `crdt_lf` — there is no second CRDT
dependency, so there is **one serialization path, one op-log format, and one
import/export mechanism**.

### Storage model (LOCKED — 2026-07)

**The entire note — body prose *and* YAML frontmatter — is stored as a single
Fugue sequence (`CRDTFugueTextHandler`).** Frontmatter is not a structured CRDT
tree. It is text at the top of a markdown file, stored and merged as text.
**This includes `tags` and `links`** — they are not OR-Sets; they are text like
everything else, parsed into a derived index at the read layer for search and
graph features. There is exactly **one handler type in use**.

This was decided after an extended design spike; the alternatives were explored
and rejected. See the parked GitHub issue (structured-frontmatter) for the full
rationale, but in brief:

- **Handler-per-key fails** on concurrent lazy creation: two peers independently
  creating the same named handler resolve to one, and the loser is discarded
  entirely — silent data loss, not a merge.
- **Pre-declared schema fails** on usability: it imposes a user-facing type
  system, migrations, drift reconciliation, and promotion flows on something
  users expect to be free-form text.
- **Split storage (managed keys as handlers + rest as text) fails** on
  round-trip fidelity: YAML comments, anchors, quoting style, and key ordering
  have no home in the split, so every save risks reshaping the user's file.

**Consequence accepted:** concurrent edits to the same frontmatter line produce
Fugue run-contiguity results (e.g. `published: truefalse`) rather than a clean
LWW resolution. This is user-visible wrongness, but it is **not silent data
loss** — both users' input survives and is repairable. Losing typed input was
the unacceptable failure; garbled-but-recoverable is not.

**Mitigation:** a semantic frontmatter validator (separate work item) parses the
frontmatter region, flags invalid YAML *and* invalid values for a small set of
known keys, and offers repair. The validator is a read-and-warn layer, not a
storage mechanism.

**The single most important invariant these tests defend:** operations are
resolved in **identity-space**, not **offset-space**. A sequence CRDT gives
every element a stable identifier encoding its position *between neighbors*,
not an integer index. Any test that reduces to "insert at position N" and
expects positional arbitration is testing the wrong thing — and if a test
*passes* only because the implementation used offset coordinates, that's a
red flag the sequence CRDT was bypassed.

**Definition of "converge" used throughout:** after all devices have exchanged
all operations (in any order, with arbitrary duplication and delay), every
device's materialized document is **byte-for-byte identical**. Convergence is
necessary but **not sufficient** — several tests below assert convergence *to a
specific meaningful state*, because converging on garbage still counts as
converging.

### The tiebreak comparator (LOCKED — referenced by Cases 1, 3, 5, 6)

Wherever two genuinely concurrent operations compete for the same position or
the same register, the winner is decided by a single, total comparator:

1. **HLC timestamp**, dominant. Higher logical time wins.
2. **peerID**, breaking equal timestamps. The ordering is a fixed, total order
   over peerIDs (see the deterministic-peerID fixture below).

This comparator is **the** determinism mechanism for the whole suite. Every
"assert the specific winner" instruction resolves through it. It is not
per-case discretion — it is one rule, stated once here, that all cases invoke.

---

## Harness requirements (build these as fixtures/scaffolding BEFORE the cases)

The prose spec assumes these exist. They are not optional plumbing; several
assertions are literally unwriteable without them.

- **N independent replicas of the same document.** Construct arbitrarily many
  replicas sharing a `documentId`.
- **Deterministic peerID assignment.** *(Blocker — nothing testable works
  without this.)* Replicas must be created with fixed, known peerIDs assigned
  in a controlled total order (e.g. replica A always lower than replica B).
  Every tiebreak in the suite resolves on peerID; if replicas get random UUIDs,
  the "assert the specific winner" requirement cannot be satisfied and the
  determinism tests are meaningless. Provide a fixture that yields replicas with
  caller-specified, ordered peerIDs.

  **Use human-auditable peerIDs so tiebreak assertions can be verified by eye.**
  Each ID is a single fill letter repeated, so a reviewer reads `aaaa… < bbbb… <
  cccc…` and can confirm a pinned winner against the comparator without computing
  anything. The version nibble (`4`) and the variant nibble (`8`) are fixed by
  RFC-4122 v4 and are **not** the fill letter — keep the variant nibble `8` for
  **all** peers (including A and B) so all three are structurally uniform and
  unambiguously valid; do not "regularize" the `8` back to the fill letter, as
  that can produce an invalid variant that `PeerId.parse` rejects.

  ```dart
  // Fill letter encodes identity; the 4 (version) and 8 (variant) nibbles are
  // fixed by RFC-4122 v4 and are the same across all peers.
  // Comparator ordering: peerA < peerB < peerC — VERIFY on first run (see below).
  final peerA = PeerId.parse('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');
  final peerB = PeerId.parse('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');
  final peerC = PeerId.parse('cccccccc-cccc-4ccc-8ccc-cccccccccccc');
  ```

  **Verify the ordering assumption, don't assume it.** The comparator breaks ties
  by peerID, but the *ordering rule itself* (lexicographic string vs. parsed-byte
  vs. numeric) is the library's, not this spec's. Confirm on first run that
  `peerA < peerB < peerC` holds under `crdt_lf`'s actual peerID comparison, and
  pin that as an explicit assertion — it underpins every determinism test in the
  suite, so a surprise here must fail loudly rather than silently invert an
  expected winner. (`PeerId.parse` with caller-supplied UUIDs is confirmed to
  exist; if the API surface differs from what's shown, use the real constructor
  and keep the fill-letter + fixed-`8`-variant convention.)
- **Isolated (offline) operation application.** Apply operations to one replica
  without any exchange, simulating an offline device.
- **Controlled-order merge, with replay.** Exchange/merge operations between
  replicas in a caller-specified order, including delivering the same operation
  twice (for idempotence).
- **Materialization + assertion helper.** Under the locked storage model the
  whole note — body and frontmatter — is one Fugue sequence, so there is a
  **single** assertion primitive: materialize to a **string** and assert exact
  string equality. Do not build per-tier helpers; there is one tier.
  *(Where a case involves a `truefalse`-style garbled frontmatter value, that is
  still just string equality against the pinned expected string.)*
- **Automatic commutativity + idempotence wrapper.** Provide a scenario runner
  that, given a setup + actions + expected value, **automatically** executes it
  under both merge orderings (A→B and B→A) *and* with duplicate delivery, then
  asserts the identical pinned value in every run. Individual cases should be
  expressed once and run through this wrapper, so it is structurally impossible
  to write a test that only checks one lucky order. (Exception: Case 3a, where
  ordering is the thing under test — see its note.)

---

## Edge Case 1 — Concurrent same-position insert (interleaving)

**This is the headline case.** It is the reason a sequence CRDT is required at
all rather than block-level last-writer-wins.

### Setup

- Two replicas, A and B (A's peerID ordered below B's), from an identical base
  block. Recommended base: `"the "` (trailing space intentional).
- Both go offline / isolated.

### Actions

- Replica A appends `cat` at the end of the base → A locally reads `"the cat"`.
- Replica B appends `dog` at the same end position → B locally reads
  `"the dog"`.
- Both insertions target what is, in offset terms, the *same* position.

### Merge

- Run through the commutativity+idempotence wrapper (both orderings, duplicate
  delivery).

### Expected outcome

- **Both replicas converge to the identical string.**
- The converged string is exactly **`"the catdog"` or `"the dogcat"`** — the two
  runs kept **contiguous and intact** — with the specific winner determined by
  the locked tiebreak comparator over A's and B's peerIDs. **Once observed,
  assert that specific string** (not "either of the two"), so a determinism
  regression fails loudly.
- **FAIL if the result interleaves the runs** (e.g. `"the cdaotg"`,
  `"the cadtog"`, or any character-shredded ordering). Interleaving means the
  sequence CRDT is not preserving run integrity — the exact failure Fugue
  exists to prevent.

### Why this holds

Fugue assigns stable identities that bias concurrent same-anchor runs to stay
grouped rather than merge character-by-character. The winner between `catdog`
and `dogcat` is fixed by the tiebreak comparator (timestamp then peerID), so it
is identical on every replica.

### Variations to generate

- Three replicas inserting `cat`, `dog`, `fish` concurrently at the same anchor
  → assert all three runs intact and contiguous, in the deterministic order the
  comparator dictates.
- Concurrent insert at the **same interior position**: base `"ab"`, A inserts
  `X` between a and b, B inserts `Y` between a and b → assert `"aXYb"` or
  `"aYXb"` (per comparator), never `"aXbY"`-style corruption of surrounding
  text.

---

## Edge Case 2 — Delete then concurrent edit of the deleted region (tombstones)

Sequence CRDTs don't physically remove deleted elements immediately; they leave
**tombstones** so identities referenced by concurrent operations remain
resolvable. This test defends that machinery.

### Locked semantic: insert-survives-at-boundary

This is a **locked data-model decision**, not an open choice. An insert anchored
*between* two elements survives even if its neighbor elements are concurrently
deleted; it reattaches to the nearest living anchor. (The earlier draft of this
spec presented delete-wins as an alternative — it is not. The data model chose
insert-survives-at-boundary; test only that.)

### Setup

- Two replicas A and B from base `"hello world"`.

### Actions (offline)

- Replica A deletes the word `world` (the run of elements spelling it).
- Replica B, concurrently, inserts `!` between `wor` and `ld` — anchored
  *between* elements A is deleting.

### Merge

- Both orderings; also run with duplicate delivery of the delete.

### Expected outcome

- **Convergence** to an identical state on both replicas.
- Per the locked semantic, B's `!` **survives**, reattached to the nearest
  living anchor. Specify and assert the exact converged string (e.g. `"hello !"`
  — confirm the precise result against the implementation on first run, then pin
  it).
- **FAIL on:** crash, dangling-identity error, non-convergence, the insert being
  discarded, or reattachment to an unintended/nondeterministic anchor.

### Companion sub-case — insert strictly inside a single deleted element

Also cover an edit that targets an identity being deleted with no surviving
between-neighbor anchor (e.g. replacing `o` with `0` inside `world`). Assert the
convergence result is deterministic and matches the documented reattachment rule
— this is where a dangling-identity crash would surface.

### Why this holds

Tombstones keep deleted identities addressable so concurrent operations
referencing them resolve rather than throwing. The test proves (a) no crash on
referencing a deleted identity, and (b) the reattachment rule is deterministic
and matches the locked choice.

### Implementation note

If `crdt_lf`'s default behavior differs from insert-survives-at-boundary, **that
gap is a finding** — report it, do not silently adopt the library's default as
the spec.

---

## Edge Case 3 — Future-clock fairness skew (HLC max rule)

HLC protects **causal** ordering unconditionally, but a badly-set physical clock
can **skew fairness** of tiebreaks between genuinely concurrent edits. This test
separates the guarantee (causality) from the wart (fairness).

### Part 3a — causality survives a broken clock (hard guarantee)

**Note on ordering:** unlike every other case, 3a's "both delivery orders" is
**the assertion itself**, not the commutativity wrapper. The point is that no
delivery order can make the dependent op sort before its dependency. Do **not**
route 3a through the generic wrapper as if order-independence were incidental —
here it is the thing under test.

- **Setup:** Replica P with its physical clock set **10 minutes fast**.
- **Actions:** P inserts `X`, then P makes a second op that **causally depends**
  on the first (e.g. deletes `X`, or inserts `Y` immediately after `X` with
  knowledge of it).
- **Merge:** deliver P's ops to a correct-clock replica Q, in both orders and
  with duplication.
- **Expected:** causal order is **always preserved** — the dependent op never
  sorts before the op it depends on, regardless of the inflated timestamp.
  Assert delete-after-insert (or Y-after-X) holds on Q. This must **never**
  fail; it is the load-bearing guarantee.

### Part 3b — fairness skew is observable but convergence holds (documented wart)

- **Setup:** Replica P (10 min fast) and replica Q (correct clock). Use the
  **string** assertion primitive.
- **Actions:** P and Q each make a **genuinely concurrent** insert at the same
  anchor in the note's Fugue sequence — the same competition Case 1 tests, but
  with a clock gap instead of equal timestamps deciding it. Use a frontmatter
  line as the fixture (e.g. base `"status: "`, P appends `done`, Q appends
  `wip`), since that is the real-world shape of this conflict under the locked
  storage model.
- **Merge:** exchange.
- **Expected:**
  - **Convergence holds** — both replicas land on the same string (assert equal
    *and* pin the exact value).
  - **The inflated clock decides the ordering deterministically** — pinned to
    `"status: wipdone"`. **FINDING — direction confirmed against the
    implementation, opposite to this spec's original prose.** The original draft
    asserted `"status: donewip"` on the theory that P's inflated HLC would make
    its run sort *first* (leftmost). In practice `crdt_lf` replays a handler's
    changes in **ascending** HLC order and lays the sequence out left-to-right,
    so the **higher (inflated) HLC sorts LAST** — P's `done` lands to the right
    of Q's `wip`. Everything the case is actually defending still holds: the HLC
    term dominates the tiebreak (it overrides the peerID order that equal
    timestamps would have used — here `peerP` < `peerQ` would have put `done`
    first, and the clock skew overrides that), convergence is exact, and the
    runs stay whole. Only the left/right *direction* differed from the guess, so
    we pin `"status: wipdone"` as the observed, deliberately-depended-on value.
    This is a **confirm-then-pin** assertion (see "Two kinds of pinned value"),
    not a load-bearing guarantee: if a future `crdt_lf` changes the replay
    direction it is a library *change* to absorb consciously, not necessarily a
    bug. Document this as expected skew, not a bug.
  - Both runs remain **contiguous and intact** — clock skew changes *which run
    wins the ordering*, never whether runs stay whole.
  - After merge, Q's own HLC has **jumped forward** to at least P's timestamp
    (max-and-increment propagates the inflated clock). Assert Q's post-merge
    logical time ≥ P's op time.

### Why this holds

HLC updates as `max(local_physical, local_hlc, incoming_hlc) + counter_bump`.
The `max` makes causality bombproof (3a) but also drags every replica toward the
fastest clock (3b), skewing concurrent tiebreaks toward the fast device until
clocks re-sync. Convergence is never at risk; only fairness is.

---

## Edge Case 4 — Non-BMP (surrogate-pair) content survives serialization

*(New case. Motivated directly by crdt_lf issue #103 — non-BMP characters
corrupting to U+FFFD across serialize/deserialize, fixed in 3.4.2. Cases 1–3
would all pass with ASCII fixtures and never exercise the surrogate path, so
this class of bug slips through them entirely. This case is the regression guard
and belongs in the permanent suite regardless of the upstream fix.)*

### Setup

- Replica A with a fresh document. Materialize via the **string** primitive.

### Actions & merges — three sub-cases

- **4a — sequence insert, second replica.** A inserts a non-BMP string
  (e.g. `"😀"`, U+1F600; also cover a CJK Extension B ideograph and a
  ZWJ sequence such as `"👨‍👩‍👧"`). Build replica B from A's exported changes.
  **Assert B's materialized string is byte-for-byte identical to A's** (i.e.
  `"😀"`, code units `[55357, 56832]`), **not** `"��"` (`[65533, 65533]`).

- **4b — edit that splits a surrogate pair.** A inserts `"a😀b"`, then edits to
  `"a😃b"` (a change that, per diff, touches only the low surrogate). Build
  replica B from exported changes. Assert B materializes `"a😃b"` exactly.

- **4c — single-doc snapshot round-trip (no second replica).** A inserts
  `"😀"`, take a snapshot, serialize it to bytes, rebuild the document from those
  bytes alone (same peerID, same documentId — **simulating** a restart /
  load-from-disk, entirely in memory: the snapshot bytes stay in a variable, no
  file is written). Assert the reloaded value is `"😀"`. This proves the guard
  covers **persistence**, not
  just cross-replica sync.

### Why this holds

The corruption occurred at the serialization boundary (encoding a lone surrogate
half), so it is invisible in-memory on the originating replica and only appears
after a serialize/deserialize round-trip — whether to another replica or to disk
and back. The corrupted output is still well-formed UTF-16, so a validity check
never catches it; only an exact-value assertion does.

### Regression-guard note

Run this suite against every `crdt_lf` version bump. A silent reintroduction —
or a transitive change in how element values are encoded — must fail here rather
than reaching a user's notes.

---

## Edge Case 5 — Convergence after snapshot / garbage collection

*(New case. This is the highest-risk untested interaction in the system: a peer
that garbage-collected history receives, or must reconcile with, changes from a
peer that was behind. `takeSnapshot` is non-destructive, but `garbageCollect`
strands any peer not in the `VersionVector.intersection` — a critical
operational constraint. This is a data-model convergence question, not a
transport one, so it belongs in this suite despite the transport exclusion
below.)*

### Setup

- Replicas A and B (known, ordered peerIDs), synced to a shared baseline so both
  observe a common frontier.

### Sub-case 5a — snapshot is non-destructive to convergence

- A takes a snapshot (history retained). A and B each make a concurrent edit.
  Merge. **Assert convergence to the same pinned value as if no snapshot had been
  taken** — snapshotting must not change the converged result.

### Sub-case 5b — GC strands a peer below the frontier (the constraint, made a test)

- A and B are synced; a third replica C has been offline and is **behind the
  version-vector frontier**. A runs `garbageCollect`, pruning history C still
  needs. C then attempts to sync.
- **Assert the documented behavior explicitly** — do not let this be an accident.
  The locked operational rule is that a peer outside
  `VersionVector.intersection` at GC time is stranded and cannot cleanly merge
  incremental changes; recovery is a cold resync from a snapshot, not a
  history replay. The test must assert that the stranded-peer condition is
  **detected** (not a silent divergence, not a crash) and that a cold resync
  from A's snapshot brings C to byte-identical convergence with A and B.
- **FAIL on:** silent divergence (C converges to a *different* value and no
  error surfaces), crash on missing history, or C appearing converged while
  actually holding stale state.

### Why this holds

GC trades recoverability for space. The danger is not that stranding happens —
that's the designed behavior — but that it happen **silently**. This case pins
"stranding is detected and recoverable via cold resync," turning a dangerous
operational footgun into a checked, observable state transition.

---

## Edge Case 6 — Empty and degenerate boundaries

*(New case. Concurrency tests jump to the interesting scenarios and skip the
trivial bases they stand on — which is exactly where off-by-one and null-anchor
bugs live. Each is cheap; collectively they catch a category the headline cases
assume away.)*

- **6a — insert into empty document.** Two replicas from an empty doc, each
  inserts concurrently at position 0. Assert contiguous, deterministic
  convergence per the tiebreak comparator (same rule as Case 1, degenerate
  base).
- **6b — delete-to-empty then concurrent insert.** A deletes all content
  (document now empty); B concurrently inserts into what A is emptying. Assert
  deterministic convergence, no dangling-anchor crash (relates to Case 2's
  tombstone machinery at the whole-document boundary).
- **6c — one side makes no changes.** A edits; B makes zero operations. Merge
  both directions. Assert B converges to A's state and A is unchanged — the
  no-op merge must be a clean identity, not a divergence or a spurious rewrite.
- **6d — idempotent re-merge of an already-merged op.** Deliver a fully-merged
  operation a third time. Assert the value is unchanged (idempotence at the
  degenerate "nothing new" boundary).

---

## Cross-cutting requirements (apply to every case)

1. **Order independence.** Every case (except 3a, where order *is* the subject)
   runs under at least A→B and B→A merge orderings with identical final
   assertion, via the commutativity wrapper. Divergence between orderings is a
   commutativity failure.
2. **Idempotence.** At least one delivery in each case is duplicated. A
   re-delivered operation must not change the converged state.
3. **Identity-space, not offset-space.** No test may pass by relying on integer
   positions surviving concurrency. Assert on the *content* of the converged
   document, not positional indices.
4. **Deterministic tiebreaks via the locked comparator.** Where two outcomes are
   both structurally valid (e.g. `catdog` vs `dogcat`), the winner is fixed by
   timestamp-then-peerID and must be stable across replicas and runs. Assert the
   specific value so nondeterminism regressions surface.
5. **No crashes on deleted/absent identities.** Referencing a tombstoned or
   never-observed identity resolves per spec, never throws.
6. **Pin the value, never just "equal."** Every convergence assertion states the
   exact expected materialized value. "A == B" alone is insufficient — it passes
   on shared corruption.
7. **Structure, not just values, must round-trip.** Where a note is rebuilt from
   serialized bytes (Cases 4, 5), assert the reconstructed state is identical —
   not merely that a spot-checked value matches. Corruption materializes
   plausibly and passes value-only checks.

---

## What this spec deliberately does NOT cover

- **Persistence, transport, and filesystem — see handoff instruction 2.** No
  SQLite or storage, no any-sync/transport, no on-disk engram, no markdown-file
  or filesystem access. This suite runs entirely in memory; the export/import and
  snapshot round-trips are in-memory byte operations, not persistence or network.
- Network transport, batching, or the WebSocket/relay layer (that's the
  sync-*build* phase — not the data model). *Note: GC-vs-late-peer convergence
  (Case 5) is in scope despite touching sync operationally, because it is a
  data-model correctness question, not a transport one.*
- Encryption / multi-tenant access boundaries (spike questions Q2/Q3 — separate
  decisions).
- **Structured frontmatter as a CRDT tree.** Explored and rejected (see the
  storage-model decision above and the parked GitHub issue). Frontmatter is part
  of the note's Fugue sequence; there is no handler tree to test.
- **The frontmatter semantic validator.** Separate work item — a read-and-warn
  layer over the materialized text, not a storage or convergence mechanism.
- Performance/throughput of large documents (blocks-as-optimization is a later
  concern; correctness first).
- The exact `crdt_lf` public API surface — map these behaviors onto whatever the
  library actually exposes, and **flag any case the library cannot express or
  resolves differently from this spec**, as that gap is a material finding for
  the data-model decision.
