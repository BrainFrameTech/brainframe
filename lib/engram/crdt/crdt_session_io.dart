import '../engram.dart';
import '../fs/fs_store_io.dart';
import '../note_reconciler.dart';
import '../note_writer.dart';
import 'app_data_resolver.dart';
import 'crdt_note_writer_io.dart';
import 'drift_reconciler_io.dart';
import 'identity_authorship_io.dart';
import 'identity_map_io.dart';
import 'metadata_db_io.dart';
import 'note_document_lock.dart';

/// One engram's open op-log, for as long as that engram is the active one.
///
/// The database is a process-wide resource with a lifetime, which nothing in
/// the app owned before this: steps 0–8 built every piece of the CRDT layer and
/// left it unreachable, because opening it is only worth doing once something
/// writes through it. That is step 9.
///
/// **One session per engram, closed on the way out.** SQLite connections are
/// not free and two connections to one `metadata.db` would defeat the single
/// transaction boundary the schema depends on, so switching engrams closes the
/// outgoing session before the incoming one opens.
class CrdtSession {
  CrdtSession._(
    this._database,
    this.writer,
    this._reconciler,
    this._identity,
  );

  final MetadataDatabase _database;
  final AuthoredIdentity? _identity;

  /// How the editor should save into this engram.
  final NoteWriter writer;

  final DriftReconciler _reconciler;

  /// How the app brings files that changed outside it back into history.
  NoteReconciler get reconciler => _reconciler;

  /// Opens the op-log for [engram], or returns null if it should not have one.
  ///
  /// Null for a read-only engram: the built-ins ship as assets, cannot be
  /// edited, and nothing is ever written into their `.brainframe/`. A null
  /// session is the normal answer for them rather than a failure, and the
  /// editor writes directly — which for a read-only engram means it never
  /// writes at all.
  ///
  /// [resolveRoot] overrides where `metadata.db` is looked for, so a test can
  /// point at a temporary directory instead of the real app-data one.
  static Future<CrdtSession?> openFor(
    Engram engram, {
    AppDataRootResolver? resolveRoot,
  }) async {
    if (engram.readOnly) return null;
    final database = await MetadataDatabase.open(
      engram.id,
      resolveRoot: resolveRoot,
    );
    // Old scan records go on open, before anything reads them: a year of
    // ordinary scans, never the ones that lost history or failed.
    database.scans.prune();
    // The shared identity map lives inside the engram folder, so it exists
    // only for an engram that has one. Every writable engram today is a
    // filesystem engram; the seam allows otherwise, and such an engram would
    // get drift reconciliation and nothing that needs a listing.
    final store = engram.store;
    final identity = store is FileSystemEngramStore
        ? await AuthoredIdentity.load(
            IdentityMap(
              engramRoot: store.location.path,
              peerId: database.peerId,
            ),
          )
        : null;
    // One lock between the two: a save and a reconciliation of the same note
    // must never overlap, and nothing above the session sequences them.
    final lock = NoteDocumentLock();
    return CrdtSession._(
      database,
      CrdtNoteWriter(
        database: database,
        engram: store,
        lock: lock,
        identity: identity,
      ),
      DriftReconciler(
        database: database,
        engram: store,
        lock: lock,
        identity: identity,
      ),
      identity,
    );
  }

  /// Writes any identity-map rows still in the timers, closes the
  /// reconciler's event stream, and closes the database. Safe to call twice.
  ///
  /// The map is flushed *before* the database closes, and awaited: a rename
  /// recorded seconds before the engram was switched away from must reach
  /// the folder, or every other device keeps the old path.
  Future<void> close() async {
    await _identity?.flush();
    await _reconciler.close();
    _database.close();
  }
}
