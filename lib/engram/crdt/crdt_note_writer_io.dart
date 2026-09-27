/// The editor's buffer, arriving as CRDT operations instead of a file write.
///
/// `dart:io`-only by way of [NoteDocument] and the materializer. Nothing in the
/// UI imports this file: it is handed up as a [NoteWriter], which is pure, so
/// the editor never learns whether an op-log is behind it.
library;

import 'dart:convert';

import '../engram_store.dart';
import '../metadata.dart';
import '../note_writer.dart';
import '../text_merge.dart';
import 'blob_note_writer_io.dart';
import 'catalog.dart';
import 'drift.dart';
import 'identity_authorship_io.dart';
import 'line_terminators.dart';
import 'materializer_io.dart';
import 'metadata_db_io.dart';
import 'note_document_io.dart';
import 'note_document_lock.dart';
import 'pre_save_check.dart';

/// Turns a saved buffer into operations on a note's document, then rewrites the
/// file from the result.
///
/// This is the inversion Decision 4 describes. Before it, the buffer was the
/// authority and the file was where it landed; now the CRDT is the authority
/// and the file is a projection of it. The user sees no difference — the same
/// bytes reach the same path — and everything that made the old path safe is
/// still here, one layer down: the write is still atomic, and it is still
/// ordered so a crash leaves a redundant diff rather than lost content.
///
/// **It looks before it writes** (the filesystem watcher design, Decision 5):
/// a file changed underneath the note is taken into history first, through
/// [check], and a save with a base merges with it rather than writing over it.
class CrdtNoteWriter implements NoteWriter {
  const CrdtNoteWriter({
    required this.database,
    required this.engram,
    required this.lock,
    this.identity,
    this.check,
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

  /// What a save asks before it writes: the session's reconciler, so the
  /// question is answered exactly as the scan would answer it.
  ///
  /// Null only where nothing else can change the file — a test, a tool over
  /// a folder it owns — and then the save writes without looking, as every
  /// save did before. The session always wires it.
  final PreSaveCheck? check;

  /// The ceiling a file is read whole under, and a merge is held to.
  int get _ceilingBytes =>
      check?.noteSizeCeilingBytes ?? defaultNoteSizeCeilingBytes;

  @override
  Future<String> write(String path, String text, {String? base}) =>
      lock.run(() => _write(path, text, base));

  /// The other shape, for a note whose policy is `blobLww` — one the ceiling
  /// converted or that arrived too large for a history, or a new file with a
  /// blob's extension. Same store, same lock, same map: only the save differs.
  BlobNoteWriter get _blob => BlobNoteWriter(
    database: database,
    engram: engram,
    lock: lock,
    identity: identity,
    check: check,
  );

  Future<String> _write(String path, String text, String? base) async {
    final row = database.catalog.byPath(path);

    // One shape per policy, decided here under the lock where the row is
    // known — the editor asks for "the writer" and never learns which. A
    // known row says what it is; an unknown path is what its extension
    // says it will be minted as.
    final policy = row?.mergePolicy ?? mergePolicyForPath(path);
    if (policy != MergePolicy.fugueText) {
      return _blob.writeHoldingLock(path, text);
    }
    // A note grown past the ceiling outside the app is read-only until the
    // user decides what to do with it (the note size ceiling design,
    // Decision 4). The editor does not offer a save; this is the seam
    // refusing one anyway, since applying a buffer that size is the thing
    // the ceiling exists to prevent.
    if (row?.state == NoteState.oversized) {
      throw StateError('$path is awaiting a decision and cannot be saved');
    }

    // A path the catalog has never seen is a note nobody has minted. Since
    // step 11 the scan and the before-open reconciliation bring a file in
    // before the editor can save it, so this is reached only when neither ran
    // — a path that did not exist to be reconciled. Seeding with the buffer
    // rather than with the file's old content is deliberate: the buffer is
    // what the user means, and seeding with anything else would make the
    // user's first keystroke an edit against a document they never saw.
    //
    // A file is there all the same when something wrote it in the moment
    // since — which a base lets the mint merge with rather than replace.
    if (row == null) {
      final content = await _mergeWithUntracked(path, text, base);
      final note = NoteDocument.mint(
        store: database,
        path: path,
        content: content,
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
      return content;
    }

    // Decision 5 of the watcher design: whatever changed underneath is taken
    // in before anything is written, so the save cannot put the old text back
    // over it. Asked before the document is opened, so the document opened
    // below is the one with the external edit in it.
    await check?.reconcileBeforeSave(row);

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
      //
      // The direct writer does its own looking: with no history here, the
      // file is compared with the base and merged if it moved. Not a file
      // over the ceiling, though, which is never read whole — that one is
      // written over, as the file-is-authority rule of this state has it.
      final stat = await engram.statFile(path);
      final readable = stat == null || stat.size <= _ceilingBytes;
      final written = await DirectNoteWriter(
        engram,
      ).write(path, text, base: readable ? base : null);
      // Recorded as observed, so the next scan does not take this device's
      // own write for a change made underneath the editor and reload it
      // over whatever was typed since.
      await recordFileState(
        store: database,
        engram: engram,
        row: row,
        digest: ContentDigest.of(utf8.encode(written)),
        text: written,
      );
      return written;
    }

    try {
      // With a base, the buffer is merged with whatever the note holds that
      // the buffer did not grow from (Decision 6) — not only a change this
      // save's check just took in, but one a scan took in while the buffer
      // was being typed, which the check cannot see: the file matches the
      // history by then. Comparing with the history catches both, and will
      // catch operations arriving from sync (#67) the same way. A merge the
      // ceiling cannot hold is refused whole, before an operation is made:
      // the change is already history, and the editor holds the merge.
      var result = text;
      final current = note.value;
      if (base != null && normalizeTerminators(base) != current) {
        result = threeWayMerge(base: base, mine: text, theirs: current);
        if (noteSizeInBytes(result) > _ceilingBytes) {
          throw NoteMergeOverLimitException(
            path: path,
            merged: result,
            onDisk: current,
          );
        }
      }
      // Minimal, never replace-all: a delete-everything-then-insert converges
      // and discards every concurrent remote insertion.
      note.applyExternalText(result);
      // Unconditional, even when the diff produced nothing. A buffer that
      // matches the CRDT can still differ from the *file* — non-canonical
      // terminators are the ordinary case — and skipping the write on "no
      // operations" is exactly the trap that leaves the hash stale and reports
      // drift on this note on every scan thereafter.
      await materializeNote(store: database, engram: engram, note: note);
      return result;
    } finally {
      note.dispose();
    }
  }

  /// [text], merged with the file at [path] if one is there that the catalog
  /// has not met and that differs from [base] — or [text] as it is, with no
  /// base or no such file. A file over the ceiling is not read whole to find
  /// out, and is refused rather than written over unseen.
  Future<String> _mergeWithUntracked(
    String path,
    String text,
    String? base,
  ) async {
    if (base == null) return text;
    final stat = await engram.statFile(path);
    if (stat == null) return text;
    if (stat.size > _ceilingBytes) {
      throw StateError(
        '$path is over the note size ceiling on disk and was not saved over',
      );
    }
    final onDisk = await engram.readString(path);
    if (normalizeTerminators(onDisk) == normalizeTerminators(base)) {
      return text;
    }
    return threeWayMerge(base: base, mine: text, theirs: onDisk);
  }
}
