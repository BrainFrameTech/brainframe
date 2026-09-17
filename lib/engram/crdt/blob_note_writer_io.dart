/// The editor's buffer, arriving as a file write and one register claim.
///
/// `dart:io`-only by way of [BlobDocument]. This is how a `blobLww` note with
/// a text extension — a note the ceiling converted, or one that arrived too
/// large to keep a history (the note size ceiling design, Decisions 3 and 6)
/// — stays editable: the editor is handed a [NoteWriter] as for any note, and
/// what it does not know is that its saves are whole-file last-writer-wins
/// rather than operations.
///
/// The order is the opposite of [CrdtNoteWriter]'s, deliberately. There the
/// CRDT is the authority and the file is a projection of it; here the file is
/// the only copy and the register *describes* it (Decision 3), so the file
/// is written first and the claim says what was written. A crash between the
/// two leaves a file whose hash the catalog does not match — which the next
/// scan reads as an external change and records, arriving at the same claim.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../engram_store.dart';
import '../note_writer.dart';
import 'blob_document_io.dart';
import 'catalog.dart';
import 'drift.dart';
import 'identity_authorship_io.dart';
import 'materializer_io.dart';
import 'metadata_db_io.dart';
import 'note_document_io.dart';
import 'note_document_lock.dart';

/// Saves a plain-file note: the bytes to disk, then one claim to the op-log.
///
/// Exactly as typed: a blob's bytes are never normalized (Decision 10 is
/// scoped to `fugueText`), so a buffer holding `\r\n` is written holding
/// `\r\n`. The editor has no reason to know the difference, and the file is
/// the user's to keep as they like.
class BlobNoteWriter implements NoteWriter {
  const BlobNoteWriter({
    required this.database,
    required this.engram,
    required this.lock,
    this.identity,
  });

  /// The engram's catalog and op-log.
  final MetadataDatabase database;

  /// Where the file is written.
  final EngramStore engram;

  /// Shared with the scan and the text writer, so a save and a
  /// reconciliation never hold the same note's document at once.
  final NoteDocumentLock lock;

  /// Where a mint is announced to other devices, or null when the engram has
  /// no shared map.
  final AuthoredIdentity? identity;

  @override
  Future<void> write(String path, String text) =>
      lock.run(() => writeHoldingLock(path, text));

  /// [write], for a caller that already holds [lock] — [CrdtNoteWriter],
  /// which decides under the lock which shape a note is and hands a blob
  /// here. The lock is not reentrant, so it cannot be taken twice.
  ///
  /// Throws [ArgumentError] if the catalog says the note is a text note:
  /// one shape per policy, and the wrong writer fails at once rather than
  /// writing a file the CRDT would then overwrite.
  Future<void> writeHoldingLock(String path, String text) async {
    final bytes = Uint8List.fromList(utf8.encode(text));
    final row = database.catalog.byPath(path);
    if (row != null && row.mergePolicy != MergePolicy.blobLww) {
      throw ArgumentError.value(
        path,
        'path',
        'a ${row.mergePolicy.name} note is saved through CrdtNoteWriter',
      );
    }

    // The file first, whole and atomic; everything after describes it.
    await engram.writeBytes(path, bytes);
    final digest = ContentDigest.of(bytes);

    if (row == null) {
      // A path the catalog has never seen, with a blob's extension: the
      // editor is creating it, so mint it as CrdtNoteWriter mints a text
      // note — from the buffer, which is what the user means — and announce
      // it, or a second device will mint it again under another ULID.
      final blob = BlobDocument.mint(
        store: database,
        path: path,
        digest: digest,
      );
      try {
        final minted = database.catalog.byUlid(blob.ulid);
        if (minted == null) throw UnknownNoteException(blob.ulid);
        final committed = await recordFileState(
          store: database,
          engram: engram,
          row: minted,
          digest: digest,
        );
        identity?.record(committed, deleted: false);
      } finally {
        blob.dispose();
      }
      return;
    }

    final BlobDocument blob;
    try {
      blob = BlobDocument.open(store: database, ulid: row.ulid);
    } on NoteHistoryPendingException {
      // Decision 4's bounded exception, as for a text note: the ULID was
      // adopted from another device's map and its claims have not arrived,
      // so there is no register to write to. The file is already saved —
      // that is the point of writing it first — and the log, when it lands,
      // is reconciled against it as an external change. Recorded as
      // observed, so the next scan knows these bytes are this device's own.
      await recordFileState(
        store: database,
        engram: engram,
        row: row,
        digest: digest,
      );
      return;
    }
    try {
      blob.record(digest);
    } finally {
      blob.dispose();
    }
    await recordFileState(
      store: database,
      engram: engram,
      row: row,
      digest: digest,
    );
  }
}
