/// The turnstile that makes "hold one [NoteDocument] at a time" true.
///
/// Pure Dart: a future chain and nothing else. `NoteDocument` documents that
/// rule and, until step 10, had exactly one caller that could break it — the
/// editor's writer, which the controller already serializes per file. The scan
/// is a second caller, and it runs on its own triggers: app resume, and the
/// moment before a file opens. Nothing above the session sequences those
/// against a debounced save, so the session has to.
///
/// What goes wrong without it is not a crash but a silent duplication. Two
/// callers open the same note, each diffs its text against the same base, and
/// each applies its script — so an insertion the first one made is applied a
/// second time by the second, which computed its edits before the first
/// committed. Fugue merges both faithfully, and the note ends up with the text
/// twice. That is the same shape as the independent-seed hazard and it is just
/// as invisible in a single-caller test.
library;

import 'dart:async';

/// Runs actions one at a time, in the order they were queued.
///
/// One per session, not per note. Per-note locks would be finer, but every
/// action here is a diff and a file write — milliseconds — and a scan already
/// takes the lock per note rather than for its whole run, so an editor save
/// waits for at most one note's reconciliation, not the engram's.
class NoteDocumentLock {
  Future<void> _tail = Future<void>.value();

  /// Runs [action] once every previously queued action has completed, and
  /// returns its result. An action that throws releases the lock like any
  /// other; the error surfaces to its own caller and nobody else's.
  Future<T> run<T>(Future<T> Function() action) {
    final previous = _tail;
    final done = Completer<void>();
    _tail = done.future;
    return previous.then((_) => action()).whenComplete(done.complete);
  }
}
