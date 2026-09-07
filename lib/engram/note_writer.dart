/// How the editor's buffer reaches storage.
///
/// One seam with two implementations, because Decision 4 inverts the save path
/// for notes the CRDT owns while leaving it alone everywhere else. Keeping it
/// an interface — rather than a flag inside the controller — is what lets the
/// editor stay ignorant of whether an engram has an op-log behind it, and lets
/// the CRDT implementation live in a `dart:io`-only file the UI never imports.
library;

import 'engram_store.dart';

/// Writes a note's full text to wherever that note lives.
///
/// The editor holds a buffer, so what it has to offer is always a whole
/// document rather than a stream of edits. Turning that into something smaller
/// is the implementation's problem, not the caller's.
abstract class NoteWriter {
  /// Persists [text] as the content of the note at engram-relative [path].
  ///
  /// Completes when the write is durable. Throws on failure, which the
  /// controller surfaces as [SaveStatus.error] and retries on the next flush.
  Future<void> write(String path, String text);
}

/// Writes the buffer straight to the store, the way notes were written before
/// the CRDT existed.
///
/// Still the correct writer in three cases, none of them a fallback in the
/// apologetic sense: a read-only engram, an engram with no op-log at all (web
/// has no SQLite), and Decision 4's bounded exception — a history-pending note,
/// whose op-log has not arrived, so there is no document to project from.
class DirectNoteWriter implements NoteWriter {
  const DirectNoteWriter(this.store);

  final EngramStore store;

  @override
  Future<void> write(String path, String text) =>
      store.writeString(path, text);
}
