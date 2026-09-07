import '../engram.dart';
import '../note_writer.dart';
import 'app_data_resolver.dart';
import 'crdt_note_writer_io.dart';
import 'metadata_db_io.dart';

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
  CrdtSession._(this._database, this.writer);

  final MetadataDatabase _database;

  /// How the editor should save into this engram.
  final NoteWriter writer;

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
    return CrdtSession._(
      database,
      CrdtNoteWriter(database: database, engram: engram.store),
    );
  }

  /// Closes the database. Safe to call twice.
  Future<void> close() async => _database.close();
}
