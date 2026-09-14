# The note size ceiling

- **Status:** accepted (2026-09-13) — the decisions were taken in the review
  thread of **#124**, and this is their single coherent statement; Decision 7
  amended 2026-09-13, when the job was built: it raises only
- **Author:** Claude
- **Date:** 2026-09-13
- **Companion to:** [note-identity-and-crdt.md](note-identity-and-crdt.md),
  whose "Performance envelope" carries the measurements this rests on, and
  whose Decision 3 this amends

## TL;DR

A note held as a CRDT costs about 550 bytes of memory per character, so the
largest note BrainFrame can open is set by the smallest machine it runs on.
That machine is the 512 MB Raspberry Pi Zero 2 W, and the ceiling is
**128 KiB of UTF-8 bytes on disk, per text note, on every target**.

Above it, a text note cannot keep a character-level history. This document
says what happens then, and it is the same everywhere:

- The user is **told before it happens and asked**. Nothing converts a note
  behind their back.
- The only conversion is **from a text history to a plain file** — a
  `blobLww` note, editable, whose saves are whole-file last-writer-wins. There
  is no way back; a note that wants history again is recreated.
- The editor shows a **status bar** with the note's size in bytes, a warning
  at 90 %, and the wall itself, so the limit is never a surprise.
- **Every file is tracked.** One that arrives already over the limit becomes a
  plain file and is reported, not refused.
- The ceiling is **recorded in each engram** and can only be changed by a
  deliberate, counted maintenance action, so every device agrees what it is.

## Why there is a ceiling

The locked storage model puts one Fugue element per character, so a note's
memory cost is set by its length rather than its edit history: ~550 bytes per
character on every machine measured, desktop and Pi 4 alike. Operations are
cheap and scale linearly; **memory is the constraint**. A 3.2 MB note — *War
and Peace* as one file — needs on the order of 1.5 GB to be open. Desktop
absorbs that; iOS terminates the process; a Raspberry Pi cannot open it at
all. The measurements and the reproduction recipe are in the companion
design's "Performance envelope".

Nothing here reopens the storage model, which is settled and correct for the
notes people actually write. It is a reason to know the ceiling before a user
finds it, and to decide what happens above it rather than discovering the
answer as an out-of-memory kill.

## Decisions

### Decision 1 — the unit is bytes on disk

**The ceiling is 128 KiB (131,072 bytes) of UTF-8 as the file exists on
disk, frontmatter included, line endings as found.** Not characters, not
code units, not the size after normalization.

*Why bytes, not characters.* The memory cost is per Fugue element, and an
element is a UTF-16 code unit — an emoji is two, a flag four, every combining
mark its own. That is not what anyone means by "character", so a character
limit would either be a lie or a third unit (graphemes) matching neither the
user's intuition nor the cost. Bytes on disk is the one measure a user can
check with `ls -l`, a file manager, or any editor's status bar, and it means
the same thing on every platform.

*The apparent unfairness to non-Latin scripts is not one.* UTF-8 bytes track
content across scripts far better than code points do: 128 KiB of English is
about 22,000 words; 128 KiB of Japanese is about 44,000 characters, roughly
the same amount of writing. A code-unit limit would give the Japanese writer
three times the content for the same memory — generous exactly where the
Zero 2 W hurts. Bytes keep the ceiling's stated property, "above every note
anyone writes by hand", uniform across scripts.

*The error is in the safe direction.* UTF-8 bytes are never fewer than
UTF-16 code units, so a byte limit can only under-use the memory budget,
never exceed it. And it is one check with no decode: `stat` answers it.

*Which bytes.* On disk, as found, line endings included. A CRLF file is
normalized to LF on the way into the sequence and so costs less in memory
than its size — but on-disk size is what `stat` returns, what the user sees,
and the conservative direction. Nobody should have to reason about "size
after normalization". Frontmatter counts: it is bytes in the file and
elements in the sequence, and user-facing copy says so.

*One helper.* The scan checks `stat` before any read. The editor holds a Dart
string, whose `.length` is code units and would let a CJK note past the
limit; its check is the UTF-8 encoded length. Both go through one function on
one named constant, the way every line-terminator door goes through
`normalizeTerminators`, so two doors can never disagree about the same note.

### Decision 2 — one ceiling, everywhere

**128 KiB on every target. Not a setting, not per device.**

The arguments against are understood: a desktop with 32 GB is limited by a
Pi Zero the user may never own, and the ceiling is artificial. It is the
price of the guarantee the whole design is built around — that a person can
work with the same data, in the same way, on every platform BrainFrame runs
on. A ceiling that varied by device would make a note a CRDT here and a plain
file there, which is a split-brain no merge rule can repair after the fact.

Two side benefits are real and recorded: the op-log's cost is per element,
so a bound on elements per note bounds how fast `metadata.db` can grow per
note, on every device; and the Zero 2 W is a first-class target running the
same policy as everything else, not a degraded one with its own rules.

**There is no per-target soft limit either.** The 90 % warning of Decision 5
is the only soft threshold, and it is the same on every target. The Zero 2 W
is slower as well as smaller — a ceiling-sized note is expected to take
several seconds to open there, unmeasured — but a lower "comfort" limit for
e-ink would be a per-device difference in behaviour, and "the same way on
every platform" rules it out. If opening a 128 KiB note there proves
unacceptably slow, that is a performance problem to fix or a reason to
revisit the number for everyone, never a reason for that target to warn at a
different size.

### Decision 3 — conversion is one way, by consent, and drops history

**A text note over the ceiling becomes a `blobLww` note — a plain file — and
never becomes a text note again.** The conversion is never automatic: the
user is told what they will lose, history and mergeability, and asked. On
consent the note's op-log is cleared and one register claim is written.

*Why the storage allows it.* `crdt_lf` stores changes per document and
filters by handler id only on read, so one ULID can carry Fugue `note`
changes and register `blob` changes: no re-keying, no new ULID, no schema
change. `merge_policy` already exists in the catalog and in the identity
map. The companion design's Decision 3 reserved this ability and did not
build it; this decision builds one direction of it.

*Why never back.* Promotion is a seed by another name, and a seed is the one
thing the design forbids doing twice: two devices seeding the same document
produce disjoint element universes that merge as duplicated text. Promotion
would need a second seed claim raced through the identity map, a
per-handler `open` guard (a converted note's log is non-empty, so
`NoteDocument.open` would hand back an empty sequence that the first write
silently seeds, on every device), and an epoch scheme so a note that went
text → blob → text does not replay its old text under the new seed. A note
hovering around the ceiling would re-seed on every crossing. **Recreate**
sidesteps all of it and is honest about what happens: a new note, seeded
fresh, the old one tombstoned — the same shape as a rename past recognition,
with the UX that already exists for it.

*Why history is dropped rather than frozen.* The user was told. Clearing the
op-log is also the clean epoch boundary: with nothing left to replay, "never
back" costs nothing to enforce. The catalog's rename sketch goes with it; a
converted note is matched across renames by exact hash, like any blob.

*A converted note stays editable.* It opens in the editor like any text
file. Its saves go through a writer that writes the file directly and
records one register claim — whole-file last-writer-wins, resolved by the
locked comparator, so whatever the most recent writer saves is what reaches
other devices. It is the "editable, no history" regime, and it is the only
one a text note can be in besides the CRDT.

### Decision 4 — the doors

Every place a user can meet the limit, and what happens there. Conversion is
consented to at the first two; the rest are consequences.

| Door | What the user sees | The choices |
| --- | --- | --- |
| **An in-app edit** crosses the line | The save is refused at the writer; the editor's status bar (Decision 5) enters its wall state and says text and Markdown notes are limited to 128 KiB. | **Undo** — the buffer returns to the last saved state, keeping history and merging. **Convert to a plain file.** |
| **An external edit** grows a tracked note past the line | The scan finds it and does not touch the file. The note enters a persisted *oversized, awaiting decision* state, surfaced in Housekeeping like a scan notice, and opens **read-only** with the status bar in its wall state. The state survives a restart: the scan that finds it is usually the launch scan, and the user may quit before answering. | **Reconstruct the last safe version** — the CRDT's last state is materialized over the file, and the oversized version is kept beside it (`Note (oversized).md`) so the external work is never destroyed. **Convert to a plain file.** |
| **Another device** converted it | The identity map carries the new policy (latest row wins); this device **follows without asking** — one device keeping a character history for a note another has made a plain file is exactly the split-brain Decision 2 exists to prevent. The user is informed by a scan notice: converted elsewhere, and how many unsynced local edits to it are now unreachable. Consent was given once, by the person who did it. | None; informational. |
| **Adoption** finds files already over the line | No history exists to lose, so they are tracked as plain files without asking (Decision 6). The adoption's completion states the count. | Proceed or cancel, as adoption already offers. |
| **An external create** of an already-oversized text file | Tracked as a plain file. A scan notice in Housekeeping. | None; informational. |
| **Shrinks back under** after conversion | Nothing. It is a plain file. | Recreate, if the user wants history: a new note with the content, the old one deleted. |
| **Sync (#67)** | Cannot deliver a text note over the ceiling from a peer: one ceiling everywhere, and a peer's conversion arrives through the map before or with its claims. Fugue operations a peer wrote before learning of a conversion are unreachable history, reported as above. | — |

The kept-aside copy from the reconstruct door needs no special treatment: it
is a file in the folder, over the limit, and the next scan tracks it as a
plain file like any other arrival.

### Decision 5 — the user sees the wall coming

**A status bar at the bottom of the editor** shows three labeled statistics,
recomputed on the edit controller's existing change notification rather than
per keystroke, with no animation on any state change (Reduce Motion, and
e-ink):

- **Bytes**, as the file would be on disk: the UTF-8 length of the buffer,
  which is already LF-normalized, so the figure is exact. Shown as a plain
  count with thousands separators (`Bytes: 118,204`) — it is the number the
  limit is stated in and the one `ls -l` shows, and KiB rounding hides
  exactly the digits that matter near the wall. The limit appears beside it
  only in the warning and wall states (`Bytes: 118,204 of 131,072`).
- **Words**: whitespace-separated runs. Dart has no word segmenter and no
  dependency is worth taking for one. Honest for Latin scripts, meaningless
  for CJK (no spaces); accepted, because bytes is the count that matters and
  words is a courtesy. Grapheme count via `characters` is the fallback if this
  ever matters.
- **Lines**: LF count plus one; zero for an empty note.

**The warning** appears at **90 % — 117,965 bytes** — one tier, about two
pages of headroom. Two tiers would add ceremony without adding a decision. It
is a button, labeled for a screen reader, whose popup says how close the note
is, what happens at the limit, and what the user can do: move some of it to
another note, trim it, or continue and decide at the wall.

**The wall** is the same bar in a further state, with the same affordance.
Its popup carries the door's two verbs (Decision 4). Paste and typing are
treated differently:

- A **paste** that would cross the line is refused at the paste, immediately,
  with the popup: undo the paste or convert. Paste is how the wall is usually
  hit in one go, and undoing it there loses nothing.
- **Typing** past the line is allowed — the app never fights the keyboard —
  but the save is **withheld**, the save-status chip says so, and the bar is
  in the wall state. The choice is *roll back to the last saved version*
  (honest about what it is: the save is debounced, so this can discard a few
  seconds of typing plus whatever went past) or convert. Nothing is lost
  until the user picks.

**The external-edit door uses the same surface.** A note that came back
oversized from outside opens read-only with the bar already in the wall
state and the same popup with that door's verbs. One surface for both doors,
two sets of verbs.

**The regime shows in the bar, not the tree.** With every file tracked there
is nothing to mark in the tree. When a plain-file note with a text extension
is open, the status bar says so in the slot the warning would occupy —
*Plain file — edits are saved whole; no history or merging.* The information
exists at the moment it matters, without decorating the tree.

### Decision 6 — every file is tracked, and the app never splits a note

**A text file that arrives already over the limit is tracked as a plain
file, without asking, and reported.** "Never automatic" (Decision 3) is
about losing a history a note has; an arrival has none. That the tracking is
irreversible — trim the file later and it is still a plain file — is
accepted; the path to history is recreate, as for any plain file.

Reporting is Housekeeping's: a scan-history event kind for a note oversized
on arrival and one for a note converted (here or elsewhere), so the panel
lists them and the ledger can count them; scan cards' paths become
tap-to-open, so "find the three files that could not keep history and start
moving their content" is one tap from the notice; and one line at the end of
adoption with the count. Not a notification on every scan — Housekeeping is
the durable surface.

**The app never splits a note.** That is the user's writing, and nothing is
done to it that does not absolutely have to be. The status bar's warning can
suggest moving content to another note; the moving is theirs to do.

### Decision 7 — the ceiling is part of the shared format

The number is a derived value — bytes per element × the memory the smallest
target can spare — and not every input is the project's: the per-element
cost is `crdt_lf`'s and a later version could raise it; "one document at a
time" is what makes 70 MB affordable and a future feature could need two;
the Zero 2 W figure is unmeasured; newer hardware could justify more. So the
number can move, in either direction.

**Lowering costs nothing to support**: a tracked text note over the ceiling
is already the external-edit door of Decision 4, and a lowered limit produces
that state for every note between the old and new values with no new code.
Raising is likewise free. The only rule is that **no code may assume the
ceiling is monotonic** — for instance, skipping the over-ceiling check on
already-tracked notes because "they were checked at mint", which external
edits make wrong anyway.

**But any change is a protocol change.** One ceiling everywhere holds only
when every device agrees what the ceiling *is*, and "same source code" is not
an agreement on a fleet of mixed builds: a newer build with a higher limit
tracks a 150 KiB note as text; an older build receives its operations over
**#67**, cannot open it, enters the door, its user converts, the map
propagates the conversion, and the newer device loses the history. Lowering
does the same in mirror. So:

- **The ceiling is recorded in `.brainframe/engram.json`**, beside
  `schemaVersion`, `id`, `displayName`, and `createdUtc`: one value per
  engram, synced with the folder. Not the identity map (per peer) and not
  `metadata.db` (device-local — the one place it must not be).
- **Two numbers, two meanings.** The build's constant is a *capability*: the
  largest note this build can hold on the smallest hardware it supports —
  128 KiB today. The engram's recorded value is what is *enforced* for that
  engram, on every device.
- **At engram open** — per engram, not at app start — the only check is:
  **if the engram's ceiling exceeds this build's capability, refuse to open
  it**, the way an unreadable `schemaVersion` is refused today, with a
  message that names the fix: update BrainFrame on this device. The other
  direction, a newer build opening an older engram, is fine and changes
  nothing.
- **A newer build never raises the value on open.** If it did, the first
  device to update would lock out every device that had not. The recorded
  value is authoritative; the constant only bounds it.
- **A new engram** records the creating build's capability. **An engram with
  no value** — everything created before this lands — means 128 KiB, the
  number that was implicitly true, and nothing writes the field until an
  explicit change.
- **Changing it is a Housekeeping job**, deliberate and counted, and it
  **raises only, to the running build's capability**: *Raise this engram's
  note size limit to 256 KiB — N notes waiting for a decision will be
  editable again; devices running BrainFrame older than X will no longer
  open it.* The confirmation states the consequence before anything
  happens. Same shape as forget and the planned garbage collection and peer
  retirement: a maintenance action, never a side effect of opening.
- **Why one direction, one value.** The only event that calls for a change
  is a newer build whose capability has passed what the engram recorded,
  and then exactly one value is worth moving to. Nothing calls for
  lowering: no user has a smaller number to prefer, and a menu of them
  would be a menu of values nobody has measured — so the job offers none,
  and an engram at the capability sees a statement, not a control. The
  engine underneath (the marker write, the reconciler's re-scan) takes any
  value in either direction, so a reason to lower, if one appears, adds a
  caller, not a mechanism. The one candidate on the horizon is a capability
  that goes *down* — the Zero 2 W measurement of **#156** coming back
  worse. That would leave every engram recording the old value refused by
  the new build, and the place to lower is then the refusal itself, which
  can offer to lower to this build's capability, counted — not
  Housekeeping, which a refused engram never reaches. Not built until the
  measurement asks for it.

## What this asks of the implementation

Recorded here so the steps that build it do not re-derive it.

- One named constant for the capability, beside `fugueTextExtensions`, and
  one size helper used by the scan (on the `stat`) and the editor (on the
  buffer).
- The `engram.json` field, its default, the refusal at open, and the
  Housekeeping job that raises it.
- A writer for plain-file notes — write the file, record one register claim
  — so a converted note stays editable through the existing `NoteWriter`
  seam.
- The persisted *oversized, awaiting decision* note state, and the reader's
  read-only presentation of it.
- Applying a policy change to a **known** catalog row when the identity map
  carries one. Today the merge adopts a policy only for an unknown path;
  Decision 9 of the companion design says a known row is reconciled against
  the map, and this column needs that code to exist.
- Scan-history event kinds: oversized on arrival, converted here, converted
  elsewhere, kept aside. Tap-to-open on scan cards' paths.
- The status bar, its three statistics, its warning and wall states, the
  paste refusal, the withheld save, and the popups — all strings through
  `AppLocalizations`.
- The manual-testing fixture gains a note just over 128 KiB and one just
  under 117,965 bytes, and the manual test plan gains a case covering the
  warning, the wall by paste and by typing, and the external-edit door.

## Adjacent, and deliberately not decided here

- **Reader rendering is a separate cost.** A `.md` tracked as a plain file
  can be any size, and rendering a multi-megabyte one is the reader's
  problem, not the CRDT's; a user will experience both as "big note = slow".
  Not measured now; measure when a large-file viewer (PDF, EPUB) is on the
  table, since that is when the reader's own limits get looked at anyway.
- **Future indexes must not inherit the ceiling.** Search and graph index
  every note with a text extension, whether it is a CRDT or a plain file.
  "Not a CRDT note" is never "not a note".
- **Is ~550 bytes per element improvable within the locked storage model?**
  Open, and now less urgent: the ceiling is enforced regardless, and a leaner
  element would raise the capability, not change the policy.

## What remains, and where it is tracked

- **The Raspberry Pi Zero 2 W measurement — #156.** The 128 KiB figure was
  measured on a Pi 4 and extrapolated to the Zero 2 W's 512 MB; the
  companion design's own words are "unmeasured and should be, once one is
  on the bench". If it comes back worse than expected, Decision 7 is how the
  number moves — for everyone.
- **The implementation — #157.** The "What this asks of the implementation"
  list above, as checkboxes, so the plan steps have somewhere to hang before
  they are written.

**#124**, where the decisions were taken, is closed by this document.
