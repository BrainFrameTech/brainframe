/// The editor's buffer, arriving as CRDT operations instead of a file write.
///
/// `dart:io`-only by way of [NoteDocument] and the materializer. Nothing in the
/// UI imports this file: it is handed up as a [NoteWriter], which is pure, so
/// the editor never learns whether an op-log is behind it.
library;

import '../engram_store.dart';
import '../note_writer.dart';
import 'identity_authorship_io.dart';
import 'materializer_io.dart';
import 'metadata_db_io.dart';
import 'note_document_io.dart';
import 'note_document_lock.dart';

/// Turns a saved buffer into operations on a note's document, then rewrites the
/// file from the result.
///
/// This is the inversion Decision 4 describes. Before it, the buffer was the
/// authority and the file was where it landed; now the CRDT is the authority
/// and the file is a projection of it. The user sees no difference — the same
/// bytes reach the same path — and everything that made the old path safe is
/// still here, one layer down: the write is still atomic, and it is still
/// ordered so a crash leaves a redundant diff rather than lost content.
class CrdtNoteWriter implements NoteWriter {
  const CrdtNoteWriter({
    required this.database,
    required this.engram,
    required this.lock,
    this.identity,
  });

  /// The engram's catalog and op-log.
  final MetadataDatabase database;

  /// Where the projection is written.
  final EngramStore engram;

  /// Shared with the scan, so a save and a reconciliation never hold the same
  /// note's document at once. The controller already serializes saves per
  /// file; this is what serializes them against everything else.
  final NoteDocumentLock lock;

  /// Where a mint is announced to other devices, or null when the engram has
  /// no shared map. A note minted here and recorded nowhere else is a note a
  /// second device will mint again under another ULID.
  final AuthoredIdentity? identity;

  @override
  Future<void> write(String path, String text) =>
      lock.run(() => _write(path, text));

  Future<void> _write(String path, String text) async {
    final row = database.catalog.byPath(path);

    // A path the catalog has never seen is a note nobody has minted. Since
    // step 11 the scan and the before-open reconciliation bring a file in
    // before the editor can save it, so this is reached only when neither ran
    // — a path that did not exist to be reconciled. Seeding with the buffer
    // rather than with the file's old content is deliberate: the buffer is
    // what the user means, and seeding with anything else would make the
    // user's first keystroke an edit against a document they never saw.
    if (row == null) {
      final note = NoteDocument.mint(
        store: database,
        path: path,
        content: text,
      );
      try {
        final committed = await materializeNote(
          store: database,
          engram: engram,
          note: note,
        );
        identity?.record(committed, deleted: false);
      } finally {
        note.dispose();
      }
      return;
    }

    final NoteDocument note;
    try {
      note = NoteDocument.open(store: database, ulid: row.ulid);
    } on NoteHistoryPendingException {
      // Decision 4's bounded exception. The ULID was adopted from another
      // device's identity map but its op-log has not arrived, so there is no
      // document to apply operations to. Writing directly keeps the user's
      // edit rather than refusing it, and the eventual arrival of the log
      // reconciles this content as ordinary drift. The exception ends the
      // moment the log lands.
      await DirectNoteWriter(engram).write(path, text);
      return;
    }

    try {
      // Minimal, never replace-all: a delete-everything-then-insert converges
      // and discards every concurrent remote insertion.
      note.applyExternalText(text);
      // Unconditional, even when the diff produced nothing. A buffer that
      // matches the CRDT can still differ from the *file* — non-canonical
      // terminators are the ordinary case — and skipping the write on "no
      // operations" is exactly the trap that leaves the hash stale and reports
      // drift on this note on every scan thereafter.
      await materializeNote(store: database, engram: engram, note: note);
    } finally {
      note.dispose();
    }
  }
}
