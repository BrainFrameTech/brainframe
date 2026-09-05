import 'dart:io';

import 'package:crdt_lf/crdt_lf.dart';
import 'package:crdt_lf_sqlite/crdt_lf_sqlite.dart';
import 'package:sqlite3/sqlite3.dart' as sq;

import 'app_data_resolver.dart';
import 'catalog_io.dart';
import 'store_exceptions.dart';

// The failure types moved to store_exceptions.dart so catalog_io.dart can
// raise them without importing this file, which imports it. Re-exported here
// so every existing `import 'metadata_db_io.dart'` still sees them.
export 'catalog_io.dart';
export 'store_exceptions.dart';

/// The device-local database for one engram: the CRDT op-log, and
/// BrainFrame's own tables, sharing one connection and one transaction
/// boundary.
///
/// BrainFrame opens the connection and owns its lifetime; `crdt_lf_sqlite`'s
/// schema is injected into it via `CRDTSqlite.fromDatabase`, whose DDL is
/// `CREATE TABLE IF NOT EXISTS` and so is safe to re-run on every open. That
/// arrangement is pinned independently by
/// [sqlite_shared_database_test.dart](../../../test/crdt/sqlite_shared_database_test.dart).
///
/// **Everything in here is device-local and none of it is shared.** The
/// op-log, the peer identity, and the catalog's content hashes all describe
/// *this install*, not the note. Nothing here may be copied into
/// the engram folder; a live database in a synced folder is corrupted rather
/// than merely stale, and a shared content hash converts drift detection into
/// silent data loss.
class MetadataDatabase {
  MetadataDatabase._(
    this.database,
    this.crdt,
    this.catalog,
    this.peerId,
    this.schemaVersion,
  );

  /// The schema version this build writes and is the newest it can read.
  static const int currentSchemaVersion = 1;

  /// The store's own key/value table, `bf_`-prefixed like every table
  /// BrainFrame creates (see [brainframeTablePrefix]).
  ///
  /// It stays readable in any SQLite browser — `select * from bf_meta` answers
  /// "what version, and which peer is this?" — which matters because this and
  /// `bf_catalog` are the whole diagnostic surface for a store whose contents
  /// are otherwise opaque operation payloads. The catalog's own DDL lives with
  /// the catalog, in [NoteCatalog.createSchemaSql].
  static const String createSchemaSql = '''
CREATE TABLE IF NOT EXISTS bf_meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
''';

  static const String _schemaVersionKey = 'schema_version';
  static const String _peerIdKey = 'peer_id';

  /// The open connection. BrainFrame owns it; [close] is the only place it is
  /// closed, so `CRDTSqlite.close()` is deliberately never called (it would
  /// close this same connection a second time).
  final sq.Database database;

  /// The op-log's storage, over the same connection.
  final CRDTSqlite crdt;

  /// One row per note, over the same connection — so a catalog write and the
  /// op-log write it accompanies commit together or not at all.
  final NoteCatalog catalog;

  /// This install's identity for this engram, minted on first open.
  ///
  /// Scoped per engram rather than one per device, which keeps engrams
  /// independent and avoids leaking a correlatable device identifier across
  /// unrelated ones. The property that must hold is narrow: two live writers
  /// must never share a peerID, since that makes genuinely concurrent
  /// operations indistinguishable rather than merely tied.
  final PeerId peerId;

  /// The schema version found in (or stamped into) the database.
  final int schemaVersion;

  /// Opens — creating if necessary — the store for the engram [engramId].
  ///
  /// The directory `<app data root>/engrams/<engramId>/` is created as needed.
  /// A fresh database is stamped with [currentSchemaVersion] and a newly
  /// generated [PeerId]; an existing one is validated and read back.
  ///
  /// Throws [MetadataDatabaseException] if the database was written by a newer
  /// build, or if its recorded version or peer identity cannot be parsed.
  static Future<MetadataDatabase> open(
    String engramId, {
    AppDataRootResolver? resolveRoot,
  }) async {
    final directory = await engramStorePath(engramId, resolveRoot: resolveRoot);
    await Directory(directory).create(recursive: true);

    final database = sq.sqlite3.open('$directory/$metadataDatabaseFileName');
    try {
      return _initialize(database);
    } on Object {
      database.close();
      rethrow;
    }
  }

  /// Opens an in-memory store, for tests that need a database but no file.
  ///
  /// No rescue around [_initialize] here, unlike [open]: a database that did
  /// not exist a moment ago holds no version or peer identity to reject, so
  /// there is no failure to clean up after.
  static MetadataDatabase openInMemory() =>
      _initialize(sq.sqlite3.openInMemory());

  static MetadataDatabase _initialize(sq.Database database) {
    database.execute(createSchemaSql);
    NoteCatalog.createSchema(database);
    // Injected into the connection BrainFrame already owns, so the catalog and
    // the op-log commit together. Re-run on every open, which its
    // IF NOT EXISTS DDL makes idempotent.
    final crdt = CRDTSqlite.fromDatabase(database);

    final version = _readVersion(database);
    final peerId = _readOrMintPeerId(database);
    return MetadataDatabase._(
      database,
      crdt,
      NoteCatalog(database),
      peerId,
      version,
    );
  }

  static int _readVersion(sq.Database database) {
    final stored = _readMeta(database, _schemaVersionKey);
    if (stored == null) {
      _writeMeta(database, _schemaVersionKey, '$currentSchemaVersion');
      return currentSchemaVersion;
    }
    final version = int.tryParse(stored);
    if (version == null || version < 1) {
      throw MetadataDatabaseException(
        'schema_version is not a positive integer: "$stored"',
      );
    }
    if (version > currentSchemaVersion) {
      throw MetadataDatabaseException(
        'metadata.db was written by a newer build (schema version $version; '
        'this build understands up to $currentSchemaVersion)',
      );
    }
    return version;
  }

  static PeerId _readOrMintPeerId(sq.Database database) {
    final stored = _readMeta(database, _peerIdKey);
    if (stored == null) {
      final minted = PeerId.generate();
      _writeMeta(database, _peerIdKey, minted.toString());
      return minted;
    }
    try {
      return PeerId.parse(stored);
    } on FormatException {
      throw MetadataDatabaseException(
        'peer_id is not a valid PeerId: "$stored"',
      );
    }
  }

  static String? _readMeta(sq.Database database, String key) {
    final rows = database.select('SELECT value FROM bf_meta WHERE key = ?', [
      key,
    ]);
    return rows.isEmpty ? null : rows.first['value'] as String;
  }

  static void _writeMeta(sq.Database database, String key, String value) {
    database.execute(
      'INSERT INTO bf_meta (key, value) VALUES (?, ?) '
      'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
      [key, value],
    );
  }

  /// Closes the connection. Safe to call once; the database is unusable after.
  void close() => database.close();
}

/// Moves the store for [fromEngramId] to the one for [toEngramId].
///
/// The engram ULID names the store's directory and appears nowhere inside the
/// database, so a changed ULID is a directory rename and nothing more — every
/// byte inside is already correct. That is what this function relies on, and
/// it is why nothing may later key a table on the engram ULID.
///
/// A changed engram ULID is not hypothetical: two devices that adopt one
/// folder before syncing each mint their own, and reconciling that is a sync
/// election, one level up from a note's. Nothing local can detect it — a
/// disconnected device cannot know a competing claim exists — so this takes
/// both ids from a caller that already knows, rather than trying to discover
/// which directory used to belong to this engram. It could not: that is the
/// same property that makes the rename safe.
///
/// A missing source is a no-op: an engram with no store yet simply gets one on
/// its next open. An occupied destination throws
/// [EngramStoreCollisionException].
Future<void> relocateEngramStore({
  required String fromEngramId,
  required String toEngramId,
  AppDataRootResolver? resolveRoot,
}) async {
  final from = await engramStorePath(fromEngramId, resolveRoot: resolveRoot);
  final to = await engramStorePath(toEngramId, resolveRoot: resolveRoot);
  if (from == to) return;

  final source = Directory(from);
  if (!await source.exists()) return;
  if (await Directory(to).exists()) {
    throw EngramStoreCollisionException(to);
  }

  await Directory(to).parent.create(recursive: true);
  await source.rename(to);
}
