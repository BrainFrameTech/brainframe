# The filesystem watcher

- **Status:** accepted (2026-09-26) — reviewed in **#204**; the choices left
  open for review are recorded under *Settled in review*; Decisions 5, 6 and
  7 amended 2026-09-26, as the save path, the merge and the editor were built
- **Author:** Claude
- **Date:** 2026-09-26
- **Issue:** **#70** (parallel track; must land before sync, **#67**)
- **Companion to:** [note-identity-and-crdt.md](note-identity-and-crdt.md),
  whose Decision 6 this amends, and [engram-storage.md](engram-storage.md),
  whose "designed-for-external-mutation" section this completes

## TL;DR

BrainFrame never holds an engram exclusively, and the drift scan already
folds whatever another program did to the folder into the catalog and the
notes' histories. What it lacks is a way to *notice*: the scan runs at open, on
resume, and before a note is opened, so a change that lands while the window
is focused waits — and a save made in that window overwrites it. The watcher
closes both halves:

- **It is a trigger, not a second reconciler.** Every event ends in the
  existing `reconcile(path)` or `scan()`; nothing about what a change *means*
  is decided here. A modified file the catalog knows is reconciled alone; any
  change to what is listed goes to a full scan.
- **It is our own thin layer over `dart:io`,** not `package:watcher`: one
  inotify watch per visible directory on Linux, Android and the Pi, so hidden
  trees such as `.git/` cost nothing; one recursive watch on macOS and
  Windows. Where watching is unsupported or fails, the app falls back to the
  triggers it has today and says so once.
- **It runs for the life of the session,** focused or not, on desktop and the
  Pi; on mobile it stops when the app is paused and the resume scan catches
  up.
- **No file is ever written over an unreconciled change** — the rule that
  makes the watcher safe, and the one sync will lean on. A save checks the
  file under the note lock and reconciles it first.
- **An open note with unsaved typing is merged, not replaced.** The editor
  keeps the text its buffer grew from, and an external change to the same note
  is merged three ways into the buffer: both the external edit and the typing
  survive, the caret stays where it was, and nobody is asked.
- There is **no setting** to turn it off.

## Why now, and what it closes

The manual test plan records the gap in two places (F29's notes and the
"Filesystem watcher (#70)" row of *Not yet testable*):

> Edits to a file while the app is focused and the note is open are *not*
> picked up until the next trigger. A save made in that state overwrites the
> external edit; that is the known gap, not a regression.

The second sentence is the dangerous one, and it is not a watcher problem. The
CRDT save path (`CrdtNoteWriter._write`) diffs the buffer against the note's
CRDT text and materializes the result over the file without ever looking at
the file. An external edit that has not been reconciled is overwritten, and
because it never became operations it is not in the history either — it is
gone. A watcher shrinks the window in which that can happen; it cannot close
it, because the external write and the debounced save can always interleave
between an event and its handling. The fix belongs in the save path, and it is
Decision 5.

The editor has the matching gap. `DocumentEditController.replaceFromDisk`
drops a dirty buffer on purpose — "the alternative, saving them, would discard
the external edit instead" — and the caret goes to the end of the text on
every reload. Both were tolerable when a reload could only follow a resume, a moment
at which the user was not typing. A watcher makes a reload something that
happens *while* the user types, which makes both intolerable. Decisions 6 and
7 replace them.

The issue also asks that sync not be built on a model that ignores external
edits. Decision 5's rule is what that means in practice; *Sync, #67* below
spells out what it asks of the sync design.

## Decisions

### Decision 1 — the watcher is a trigger; reconciliation stays where it is

The watcher's output is a request: "reconcile this path" or "scan". It never
reads a note, never touches the catalog, and never decides that a file moved
or died — those are Decision 7 of the companion design, and they need the whole
folder, which an event stream does not give. This keeps one reconciler, with
one set of tests, whatever the trigger.

It also means events may be lossy, duplicated, reordered, or coalesced — as
FSEvents' are by design, and inotify's are under overflow — without that being
a correctness problem. A spurious event costs a stat; a lost event is caught by
the next one, the next resume, or the next open. The only property the watcher
must have is that **a change eventually produces *some* event**, and where it
cannot promise that (an overflow, a watch that died), it asks for a full scan.

### Decision 2 — our own layer over `dart:io`, not `package:watcher`

`package:watcher` (1.2.1) was the obvious first choice and is the wrong one,
for two reasons found in its source:

- **It cannot prune.** Its Linux watcher places an inotify watch on every
  directory under the root. An engram that is also a Git checkout has at least
  256 directories under `.git/objects/` alone, plus whatever `.obsidian/` or a
  sync client keeps. Every one is a kernel watch counted against
  `fs.inotify.max_user_watches`, which the kernel sizes from RAM — the 512 MB
  Pi Zero 2 W is where the limit is lowest and the engram is least likely to
  be small. The scan already ignores every hidden path; watching them is pure
  cost.
- **It polls on Android.** Its factory chooses native watching only when
  `Platform.isLinux`, `isMacOS` or `isWindows`; Android, whose kernel has
  inotify and whose `dart:io` exposes it, gets a one-second polling walk of
  the whole tree.

The layer we need is small, because Decision 1 lets it be imprecise:

| Target | Primitive | Shape |
| --- | --- | --- |
| Linux desktop, Pi (flutter-pi), Android | `Directory.watch()` → inotify | One non-recursive watch per **visible** directory; hidden directories are never entered. A directory event rebuilds the affected subtree's watches. |
| macOS | `Directory.watch(recursive: true)` → FSEvents | One watch on the root; events on hidden paths are dropped on arrival. |
| Windows | `Directory.watch(recursive: true)` → `ReadDirectoryChangesW` | As macOS. The buffer can overflow under a burst; the stream then errors or closes, which Decision 3 treats as "restart, then scan". |
| iOS | none | `FileSystemEntity.isWatchSupported` is expected to be false on iOS; **to be confirmed on a device before implementation**. If it is, the resume scan is the only trigger — on an iPhone the Files app is foreground only while BrainFrame is not, so resume already covers the realistic case. |

Behind one pure interface — an `EngramWatcher` whose events are *path hints*
plus an "everything may have changed" signal — callers see no platform. The
interface also lets every test above it run against a fake, with no real
filesystem and no timing.

### Decision 3 — what an event turns into

Events are **batched**: a batch closes after 250 ms without a new event, or 2 s
after it opened, whichever comes first. An editor's save, a `git checkout`,
and a sync client's download all arrive as bursts, and one scan per burst is
the goal. Both durations are named constants beside the batcher, not literals
at their call sites, so tuning them is a one-line change. Then, per batch:

1. Drop every hidden path (`isHiddenEngramPath`) — this includes all of
   `.brainframe/`, so the app's own settings, identity-map and temp writes
   (Decision 4) never reach the reconciler.
2. If the batch holds **only modifications of files the catalog already
   knows**, call `reconcile(path)` for each. The common case — another editor
   saving the note — costs one stat per path, and a read only if the stat
   moved.
3. Otherwise — a create, a delete, a move, a directory event, a path the
   catalog does not know, or an overflow/restart signal — run **one**
   `scan(trigger: ScanTrigger.watcher)`. A move is a delete plus a create to
   every primitive above, and only the scan can pair them.

**Housekeeping records what it records today, and no more.** A full scan from
the watcher is recorded like a resume scan, with its trigger ("from the
watcher"). A targeted `reconcile(path)` is not recorded, exactly as the
before-open reconcile is not: a content change folded into history is the
ordinary case, not a finding. Without this rule a side-by-side editor saving
every few seconds would write a Housekeeping card per save. The tree and the
open note learn of changes the way they already do — `scanReports` and
`reconciled` — so neither needs to know a watcher exists.

**A scan requested during a scan runs again afterwards.** Today a second
`scan()` joins the one in flight and receives its report, which is right for
a resume that lands during the start-up scan and wrong for a watcher: the
running scan may already have listed the folder, or passed the very note the
event is about. `DriftReconciler.scan` gains a single "again" flag — any number
of requests during a scan produce at most one follow-up scan, recorded with
the trigger of the first request that set it.

### Decision 4 — the app's own writes are recognized by content, not suppressed

Every save is visible to the watcher: the materializer and the blob writer
write `X.tmp` and rename it over `X`. The tempting fix — suppress events for
paths the app just wrote — is a race with a real external write landing in the
same moment, and it would need a clock. None is needed: the drift check
already recognizes our writes. The materializer stats the file after writing
and commits the size, mtime and hash under the note lock, so the targeted
`reconcile(path)` a self-write provokes waits on that lock, finds the pre-filter
unchanged, and returns. The cost of a save is one extra stat.

What does need fixing is the **temp file's name, which is visible today and
becomes hidden.**

| | Before this design | Under it |
| --- | --- | --- |
| Temp file for `notes/a.md` | `notes/a.md.tmp` | `notes/.a.md.bf-tmp` |
| Seen by the scan and the watcher | yes | no — a leading dot is a hidden path |

The visible name was never a choice. It predates the drift scan and its
hidden-path rule, and nothing documents a reason for it. It is now a defect on
two counts:

- **A scan mid-save can adopt it.** A scan that lists the folder between the
  temp file's write and its rename sees `a.md.tmp` as a new file and mints it
  as a blob. The watcher makes this far more likely, since every save now
  provokes the events that start a scan.
- **A crash leaves it behind as content.** A temp file orphaned by a crash or
  power loss is a visible file that the next scan *will* mint.

The temp file stays **in the same directory** as its target, because `rename`
is only atomic within one filesystem, and a note folder on another mount than
the engram root is rare but possible. Hidden, it is dropped by step 1 of
Decision 3 and by the scan's listing alike. The same naming applies to
`settings.json` and `engram.json` inside `.brainframe/` for uniformity, though
their directory already hides them.

**Orphans are swept by the scan.** A hidden orphan can no longer be minted, but
nor can it be seen in a file manager, so without a sweep they would accumulate
silently. Every **complete** full scan — one whose listing did not fail —
deletes each `.*.bf-tmp` file it finds anywhere in the engram, `.brainframe/`
included, whose modification time is **more than ten minutes old**.

- **Why the age, and not the note lock.** The lock serializes this app's own
  saves, but a second BrainFrame instance over the same folder (F36) has a
  lock of its own, and its in-flight temp file must not be deleted from under
  it. A save holds its temp file for milliseconds; ten minutes is a margin no
  real write approaches, and costs nothing, since an orphan harms nothing
  while it waits.
- **Why only a complete scan.** It is the only point at which the folder has
  been walked in full, so the sweep adds no walk of its own. The one
  exception is `.brainframe/`, which the listing skips. It is swept with a
  listing of its own, which is cheap because the directory holds a handful
  of files.
- **Only our own suffix.** The sweep deletes `.bf-tmp` files and nothing else.
  Another program's hidden temp files are not ours to judge. Nor are leftover
  *visible* `*.tmp` files from before this change: by now the scan may have
  minted them as notes, and a visible file may be the user's.
- **Failures are logged, not reported.** A temp file that cannot be deleted is
  retried on the next scan. It is not a finding, so it never reaches
  Housekeeping.

### Decision 5 — nothing writes over an unreconciled change

**Every path that writes a note's file checks it first, under the note lock,
and reconciles any drift into history before writing.** This is the invariant
the watcher needs and the one sync will need; it is stated once, here, so
neither re-derives it.

For the editor's save, `NoteWriter.write` gains the text the buffer grew from:

```dart
Future<String> write(String path, String text, {required String base});
```

Under the lock the CRDT writer then:

1. Stats the file and applies the drift pre-filter and hash, exactly as the
   scan does.
2. If it has **not** drifted, proceeds as today: `applyExternalText(text)`,
   materialize.
3. If it **has** drifted, to file text `F`: first reconciles `F` as ordinary
   drift (Decision 6 of the companion design — the external edit becomes
   operations, stamped as they are today, and the path is announced on
   `reconciled`); then computes `M = merge(base, text, F)` (Decision 6 below)
   and applies `M` as this device's save.
4. Returns what the note now holds — `text` in the ordinary case, `M` after a
   merge — so the editor can take it as its new saved text.

The blob writer and `DirectNoteWriter` follow the same rule with the tools
they have: the blob writer reconciles drift as a last-writer-wins claim first
(the merge of a blob is "the later write wins", and the external one is
recorded before ours replaces it); `DirectNoteWriter`, with no catalog, reads
the file and merges if it differs from `base`.

*Amended 2026-09-26, when the save path was built:*

- **`base` is optional.** The editor always passes it. A caller with no base
  — a test, a tool over a folder it owns — gets the drift reconciled into
  history all the same, and its text then saved over it as the caller's
  word. Requiring it would have changed ~150 call sites to no one's benefit.
- **The check is the reconciler's.** The writers ask it through a small seam
  (`PreSaveCheck.reconcileBeforeSave`) rather than repeating the scan's stat,
  hash, ceiling and states, so there is one answer to "has this file
  changed". The session wires it; a writer built without one writes without
  looking, as every save did before.
- **The save's reconciliation is not announced on `reconciled`** (step 3
  above said it would be). The saving editor learns the result from the
  save's return; an announcement would make the pane reload from disk,
  racing the very save it is waiting on.
- **A merge over the ceiling is refused whole** with a
  `NoteMergeOverLimitException` carrying the merge and what the note now
  holds. The external edit is already history; the editor holds the merge as
  a withheld buffer, as though it had been typed.
- **The base is compared with the note's history, not only the file**
  *(amended again 2026-09-26, when the editor step was built)*. A scan that
  reconciles the file under an open, dirty buffer leaves the file matching
  the history, so a check of the file alone sees nothing when that buffer
  saves — and the save would write the buffer, which never had the change,
  over it. Merging whenever the history differs from `base` catches that,
  a change this save's own check took in, and operations arriving from sync,
  all by one test.

This retires Decision 6 step 1 of the companion design — "flush the editor
first" — as a *correctness* requirement. A reconcile under an unsaved buffer
no longer races the save, because the save now notices. The resume path keeps
its flush as a courtesy; the watcher does not flush, which is what makes it
safe to run while the user types. The `NoteReconciler` doc comment that says a
watcher "owes the same courtesy" is amended to say why it no longer does.

### Decision 6 — the three-way merge

`merge(base, mine, theirs)` produces one text from two edits of a common base.
It is pure, deterministic, and has one rule, borrowed from the CRDT so the
result is what two devices editing the same base would converge to:

- **Nothing either side inserted is lost.** Both sides' edits are computed
  against `base` with the line-chunked diff the save path already uses.
  Non-overlapping edits are both applied. Where the edits overlap, the base
  text there is removed if either side removed it, and both sides' inserted
  text is kept — `theirs` first, then `mine`, so the order is stable and the
  user's own typing ends up nearest the caret. Identical edits on both sides
  are applied once.
- **No conflict markers, no prompt.** A note with `<<<<<<<` in it is broken
  markdown that the user must notice and clean up, and a prompt appears
  while they are typing. The cost of the rule is visible instead: two
  different rewrites of the same sentence both appear, which the user sees and
  can edit — exactly what sync will produce for the same concurrent edit.
- **Line endings are not edits.** *(Amended 2026-09-26, when it was built.)*
  All three texts are normalized to LF before they are diffed, and the
  result is LF, which is how the note is written back anyway (the companion
  design's Decision 10). Without this, a file converted to CRLF outside the
  app is an edit to every line end, and it collides with any typing at the
  end of a line, splitting the user's text off from its line with a stray
  `\r`.

Doing this as text, rather than by forking the CRDT at `base` and letting it
merge, is deliberate. `crdt_lf` offers no fork, and emulating one with this
device's peer ID would mint the same operation counters on both branches; a
temporary peer ID would put a phantom device into the history. The text merge
is a few hundred lines of pure Dart that the size of a note bounds, and it is
testable exhaustively.

### Decision 7 — the editor merges instead of replacing, and keeps the caret

`DocumentEditController.replaceFromDisk` becomes `mergeFromDisk(text)`:

- **Clean buffer:** as today — the disk text becomes both buffer and saved
  text.
- **Dirty buffer:** the buffer becomes `merge(savedText, buffer, text)`, the
  saved text becomes `text`, and the status stays `dirty`, so the ordinary
  debounce saves the merge. A second `reconciled` for a file that already
  matches `savedText` is then a no-op, which makes a duplicate notification
  harmless.

The save's return value (Decision 5) is applied the same way: if the buffer is
still what was sent, it becomes the returned text; if the user typed during the
write, it becomes `merge(sent, buffer, returned)`.

**The caret, the selection and the scroll offset are mapped through the
change,** not reset. An offset before an edit stays; one after it shifts by
the edit's length; one inside a replaced span moves to the span's end. The
same mapping applies to a clean reload. Today's caret-to-end is recorded in
F29 as "accepted for now"; with reloads arriving mid-typing it is not
acceptable at all, so it is fixed here rather than deferred.

The pane's special cases stay: a withheld (over-limit) buffer still defers its
reload until after the rollback; a note awaiting a size decision still
reopens.

*Amended 2026-09-26, when it was built:*

- **`mergeFromDisk` does the read itself**, given a reader, and only once no
  save of the controller's is in flight — re-reading if one started meanwhile.
  A file read before our own save lands is older than the saved text, and
  merging it would undo that save.
- **Text changed under the user reaches the field at once**, not on the next
  rebuild: the pane pushes it into the field the moment the controller
  changes. A keystroke in between would otherwise report the field's old text
  back as the buffer and silently undo the merge.
- **The caret rule for an insertion exactly at the caret:** the caret stays
  before it, so the user keeps typing where they were.

### Decision 8 — lifetime: owned by the session, not by focus

The watcher belongs to the `CrdtSession` — started when the session opens,
stopped when it closes — and is driven from `CrdtSessionHost`, which already
owns the other two scan triggers:

- **Started before the open scan,** so a change during a long first scan
  produces an event, and Decision 3's "again" flag re-scans once it finishes.
- **Desktop and the Pi:** runs regardless of focus. The side-by-side editor is
  the case the watcher exists for. On flutter-pi, which has no focus events and
  so no resume scan, it is the *only* live trigger.
- **Android and iOS:** stopped on `AppLifecycleState.paused`, started again on
  `resumed` **before** the resume scan, for the same ordering reason. Nothing
  useful can be done with an event in the background, and the resume scan is
  exactly the catch-up.
- **A read-only engram** has no session, so it has no watcher — consistent
  with it having no reconciler.

`EngramStore.release()` mentions "a file watcher" as a thing a store might
hold. It will not: the session is the right owner, because the watcher's only
consumer is the session's reconciler. The comment is amended.

### Decision 9 — no toggle, and a failure is said once

There is no setting. Where the watcher cannot start or dies for good — the
inotify limit (`ENOSPC`, which `dart:io` surfaces as `FileSystemException`
errno 28), an unsupported platform, a root that is a network mount which
refuses — the session carries on with the triggers it has today, and the
Housekeeping panel shows one line saying live updates are off for this engram
and why. Nothing interrupts the user; a snackbar would repeat on every
launch of an engram that will never be watchable. A watch that dies and can be
re-established (a Windows overflow, a directory recreated) is restarted, and a
scan follows, without a notice.

The line is new UI and therefore new strings, `Semantics` and a test-plan
case; it is the only user-visible surface this design adds.

## What this asks of the implementation

In dependency order; each is a separately reviewable step.

1. **Hidden temp files and the sweep** (Decision 4) —
   `FileSystemEngramStore._atomicWrite` and the scan. Tests: no visible `.tmp`
   ever appears; a hidden temp is never minted; a complete scan deletes a
   `.bf-tmp` older than ten minutes and keeps a fresh one; a scan whose
   listing failed deletes nothing; another program's hidden file is left
   alone.
2. **`merge(base, mine, theirs)`** (Decision 6) — pure, in `lib/engram/`,
   with a table-driven test of the overlap rules and a property test: for
   random edits of a base, the result contains every inserted run of both.
3. **The save path checks first** (Decision 5) — `NoteWriter.write` gains
   `base` and returns the note's text; all three writers implement the rule.
   Tests: a drifted file is reconciled before the save and neither edit is
   lost; the external edit is in the history as operations of its own.
4. **The editor merges** (Decision 7) — `mergeFromDisk`, the save's returned
   text, caret/selection/scroll mapping. Closes the untested case the
   research found: a reload over a dirty, non-withheld buffer.
5. **Scan "again" flag** (Decision 3) — `DriftReconciler.scan`.
6. **`EngramWatcher`** (Decision 2) — pure interface; the per-directory
   inotify implementation and the recursive one; the batcher and dispatcher
   of Decision 3, tested with `fake_async` against a fake watcher. The inotify
   implementation is tested against real temp directories on Linux CI; the
   recursive one against an injected event stream, since CI cannot run it
   natively.
7. **Lifetime and the failure notice** (Decisions 8, 9) — session ownership,
   the mobile pause/resume ordering, the Housekeeping line.
8. **Docs** — the `NoteReconciler` and `EngramStore.release` comments, and
   the manual test plan (below). The companion design's Decision 6 already
   carries this design's amendment. Once the watcher ships, its trigger list
   drops "once **#70** lands".

Steps 1–4 are worth landing even if the watcher itself were never built: they
close the save-overwrites-external-edit loss on today's triggers.

## Sync, #67

The issue's constraint is that external edits and sync-delivered operations
are two inputs to one model. With Decision 5 the model is:

- **The CRDT is the only merge point.** An external edit enters it as
  operations (reconciliation); a remote change enters it as operations
  (import). Neither ever meets the other as text.
- **The file is a projection, and only a reconciled file may be overwritten.**
  Sync, applying imported operations to a note, must materialize through the
  same check-first path as a save: under the lock, reconcile drift, then
  materialize. An external edit racing a remote change is therefore always
  folded in first and merged by the CRDT, never overwritten.
- **An open note is updated the same way for both.** A materialization after
  an import announces the path on `reconciled`, and the editor's
  `mergeFromDisk` merges it into a dirty buffer exactly as it does an external
  edit.

What remains for #67 is its own: transport, ordering, and what a remote change
to a note awaiting a size decision means. Nothing here constrains those.

## The manual test plan

In the same change as the implementation (not this design):

- **F29** gains live-watch steps: an edit in a side-by-side editor appears in
  the open note while BrainFrame is focused, with the caret where it was; the
  same with unsaved typing in BrainFrame, where both survive; a `git checkout`
  that rewrites several notes and adds and removes files produces one scan.
- F29's "window of loss" and "known gap" notes are **retired**, and its
  caret-to-end acceptance is replaced by "the caret stays".
- The Pi column changes: live updates work without focus, which removes the
  "no resume event" caveat for steps that only needed *a* trigger.
- A new case covers the failure notice (Decision 9), driven on Linux by
  lowering `fs.inotify.max_user_watches`.
- "Filesystem watcher (#70)" leaves *Not yet testable*.

## Adjacent, and deliberately not decided here

- **Who made an external edit.** Still this device's peer ID, as the companion
  design's Decision 6 says; the watcher knows no more than the scan did.
- **Half-written files.** An editor that writes in place rather than by rename
  can be caught mid-write. The 250 ms quiet window makes this rare; when it
  happens, the half file is reconciled and the next event reconciles the
  whole one. The history carries a transient truncation; the content
  converges. Not worth a heuristic until it is seen.
- **iCloud placeholders** (`.icloud` stubs) and Location B folders arrive with
  engram-storage v2 and will need their own events; nothing here precludes
  them.
- **E-ink.** A live reload is a repaint; on the panel that is a refresh. The
  e-ink embedder decides when frames reach the panel, so nothing here changes,
  but the rate of external change is a thing that design should know about.

## Settled in review

Three choices were left open for review in **#204**, and were settled there:

- **The batch timings** (250 ms quiet, 2 s cap, Decision 3) are the starting
  values. They live as named constants so they can be tuned when a
  measurement or a report calls for it — the Pi Zero 2 W being the likeliest
  place for one to come from. Until then they stand.
- **Decision 6's overlap order** — `theirs`, then `mine`, with duplicated
  text preferred to conflict markers — is the rule. It is revisited only if
  real use turns up a case that demands it.
- **Decision 3's recording rule** stands as written: a targeted reconcile is
  not recorded in Housekeeping, so F29 step 13's "Housekeeping counts it"
  holds only for a change a full scan found. The test plan is to be written
  to match.
