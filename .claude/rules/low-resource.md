# Low-Resource Targets (Raspberry Pi)

The smallest machine BrainFrame runs on sets the limits for every machine. That
is a Raspberry Pi with 512 MB of RAM — the Zero 2 W the e-ink device is built
on — which leaves the app about **448 MB**. Desktop hides every mistake this
rule is about: a diff that needs a gigabyte finishes on a workstation and gets
the process killed on the board, with no stack trace, no log line, and nothing
to show which note did it.

So memory safety is designed in and proven by tests, never discovered on the
device. This applies to all code, not only code that "is for the Pi": there is
no Pi detection in `lib/` and there should be none. Code fits the budget
everywhere.

## Memory is bounded by construction

- **Anything that scales with a note or an engram has a stated bound.** A text
  note is capped at **128 KiB** on disk (`defaultNoteSizeCeilingBytes`,
  recorded per engram), because a note held as a CRDT costs ~550 bytes of
  memory per character. See `docs/design/note-size-ceiling.md`.
- **Every text diff goes through `lineChunkedDiff` / `boundedMyersDiff`.**
  Never call `crdt_lf`'s `myersDiff` or `CRDTFugueTextHandler.change` on a
  whole note: uncapped Myers is `O(D × (n + m))` in memory, a product rather
  than a sum. The bounded diff caps its trace at 32 MB and degrades to a
  coarser, still-correct script past it. The reasoning is in the header of
  `lib/engram/crdt/line_chunked_diff.dart`.
- **Blobs are streamed, never read whole.** Hash and compare them through
  `openRead` / `digestFile`. A text note is read whole only after a `stat` has
  shown it is under the ceiling.
- **Iterate; don't accumulate.** Work over an engram goes a note or a file at a
  time. Never hold every note's content, or every note's document, at once.

## The op-log grows with the edit, not the note

- **Minimal edits, never replace-all.** Deleting everything and inserting the
  new text converges and passes a two-replica test, but it bloats the log and
  discards every concurrent remote edit. The only coarse edit allowed is the
  bounded diff's fallback for a line rewritten almost entirely.
- **A line-ending-only change produces no operations** (the CRDT design's
  Decision 10). Normalize terminators before diffing, not after.

## Prove it with an input an unbounded path cannot survive

- **Memory-sensitive code gets a test that an unbounded implementation would
  fail on any machine**, not just the board. Size the input so the unbounded
  path would need gigabytes, keep it under the note ceiling so a real note can
  take that shape, and give the test a timeout.
- **Use a *dispersed* edit, not a contiguous one.** Myers trims the common
  prefix and suffix first, so one contiguous change — even the 8190-byte note
  that took the Pi down — is cheap for *any* diff, and a test on it proves
  nothing. The hazard is changes scattered along one long region: uncapped
  `myersDiff` on one line of scattered changes measured ~40 MB at 2000
  characters and ~500 MB at 8000. The "memory stays bounded" group in
  `test/engram/text_merge_test.dart` is the pattern.
- **Measure before claiming a bound.** Compare against the uncapped path with
  `ProcessInfo.maxRss` and a stopwatch in a throwaway test, and say what was
  measured in the test's comment.

## What is different at runtime under flutter-pi

- **No window focus, so no resume events.** Anything that runs "on resume"
  needs another trigger there — the manual test plan's Pi column marks these.
- **No `window_manager`.** Its initialization throws `MissingPluginException`,
  and `lib/window/window_state.dart` falls back to exiting the process
  directly.
- **No debugger.** `--trace-scan` narrates the drift scan to stderr, one line
  per note *before* the note is touched, so an OOM kill leaves the culprit's
  name as the last line. `BRAINFRAME_ARGS` passes arguments where there is no
  command line to edit.
- **Kernel limits sized from RAM are lowest here** — inotify watches, for one.
  Anything that consumes a per-user kernel resource says what happens when
  it runs out.

## Scope

This rule is about memory and runtime. The e-ink panel's refresh model — no
animations, frames pushed only on deliberate actions — is a separate
constraint, described in `CLAUDE.md` and `docs/design/eink-embedder.md`.
