/// The scan: external edits become operations (Decision 6), end to end.
///
/// `dart:io`-only by way of [NoteDocument] and the materializer, and handed up
/// to the UI as a [NoteReconciler] so nothing above the session imports this.
///
/// This is the half of "locally arriving CRDTs work" that the editor rewiring
/// (step 9) could not test: a file changed by something that is not this app —
/// another editor, a sync client, a second BrainFrame over the same folder —
/// and its edit turned into history rather than overwritten by the next save.
/// The per-note procedure is the design's, in order: flush the editor (the
/// caller's job), materialize, diff, apply in one transaction, re-materialize,
/// write back if it differs, commit the new hash.
///
/// **What this scan does not do** is everything Decision 7 covers: a path the
/// catalog has never seen, a file that is gone, a rename. Those are step 11,
/// and this scan leaves each of them exactly as it found it — a missing file is
/// neither tombstoned nor reported, and an unknown file is not minted. Absence
/// is not deletion, and a scan that is not yet known-complete must not act as
/// if it were.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import '../engram_store.dart';
import '../note_reconciler.dart';
import 'catalog.dart';
import 'drift.dart';
import 'materializer_io.dart';
import 'metadata_db_io.dart';
import 'note_document_lock.dart';
import 'note_document_io.dart';

/// Logger name for scan diagnostics (see `dart:developer`).
const String driftScanLogName = 'brainframe.engram.drift';

/// Reconciles drifted files into their notes' op-logs, one note at a time.
class DriftReconciler implements NoteReconciler {
  DriftReconciler({
    required this.database,
    required this.engram,
    required this.lock,
  });

  /// The engram's catalog and op-log.
  final MetadataDatabase database;

  /// Where the files are.
  final EngramStore engram;

  /// Shared with the editor's writer, so a reconciliation and a save never
  /// hold the same note's document at once.
  final NoteDocumentLock lock;

  final StreamController<String> _reconciled =
      StreamController<String>.broadcast();

  /// The scan in progress, so a second trigger joins it instead of starting a
  /// concurrent one. A resume that lands while the start-up scan is still
  /// running is the ordinary way this happens.
  Future<DriftScanReport>? _running;

  @override
  Stream<String> get reconciled => _reconciled.stream;

  @override
  Future<DriftScanReport> scan() =>
      _running ??= _scan().whenComplete(() => _running = null);

  Future<DriftScanReport> _scan() async {
    final reconciled = <String>[];
    final failed = <String, Object>{};
    for (final row in database.catalog.live()) {
      try {
        if (await _reconcileRow(row)) reconciled.add(row.path);
      } on Object catch (error, stack) {
        // Collected, not rethrown: the rest of the engram still gets its scan,
        // and this note stays drifted for the next one. Logged so the failure
        // is visible somewhere until step 13 gives it a surface.
        failed[row.path] = error;
        developer.log(
          'drift reconciliation failed for ${row.path}',
          name: driftScanLogName,
          error: error,
          stackTrace: stack,
        );
      }
    }
    return DriftScanReport(reconciled: reconciled, failed: failed);
  }

  @override
  Future<bool> reconcile(String path) async {
    final row = database.catalog.byPath(path);
    if (row == null) return false;
    return _reconcileRow(row);
  }

  /// Decision 6, steps 2–6, for one note; step 1 is the caller's.
  ///
  /// The lock is taken per note and released before the next, so a save
  /// waiting on it waits for one reconciliation, not a whole scan.
  Future<bool> _reconcileRow(CatalogRow row) async {
    // Only a live text note has both halves to reconcile — a file and a
    // document. `live()` already filters the state; the policy is filtered
    // here so `reconcile(path)` on a blob is a quiet no, not an exception.
    if (row.state != NoteState.live) return false;
    if (row.mergePolicy != MergePolicy.fugueText) return false;

    return lock.run(() async {
      // Re-read under the lock: a save that was ahead of us in the queue has
      // just committed a new hash, and the row we were handed describes the
      // file before it.
      final current = database.catalog.byUlid(row.ulid);
      if (current == null || current.state != NoteState.live) return false;

      // Decision 5's two-stage test, with the file's bytes kept: the hash the
      // pre-filter could not rule out is the same one the materializer uses
      // to decide whether the write-back is needed.
      final stat = await engram.statFile(current.path);
      if (stat == null) return false; // gone: step 11's question
      if (!mayHaveDrifted(current, stat)) return false;
      final bytes = await engram.readBytes(current.path);
      final onDiskHash = contentHash(bytes);
      if (!hasDrifted(current, onDiskHash)) return false;

      final NoteDocument note;
      try {
        note = NoteDocument.open(store: database, ulid: current.ulid);
      } on NoteHistoryPendingException {
        // A live row whose log has not arrived: nothing to diff into. The
        // file stays as the user left it, which is what Decision 4's bounded
        // exception promises, and the eventual log reconciles it then.
        return false;
      }
      try {
        // Steps 3 and 4: a minimal script — never replace-all — applied in
        // one transaction. Terminators are normalized on the way in, so a
        // CRLF round-trip arrives here as zero operations and still reaches
        // the materializer below, which is the whole reason step 5 is not
        // gated on "did this produce anything?".
        note.applyExternalText(utf8.decode(bytes));
        // Steps 5 and 6, unconditional. The write is skipped only when the
        // materialized bytes are exactly what is on disk; the hash is
        // committed either way.
        await materializeNote(
          store: database,
          engram: engram,
          note: note,
          onDiskHash: onDiskHash,
        );
      } finally {
        note.dispose();
      }
      _reconciled.add(current.path);
      return true;
    });
  }

  /// Closes the event stream. The session calls this on the way out; nothing
  /// else needs to.
  Future<void> close() => _reconciled.close();
}
