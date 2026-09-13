/// The catalog table and its queries, over a connection someone else owns.
///
/// `dart:io`-only because SQLite is. The row types it reads and writes are
/// platform-neutral and live in [catalog.dart](catalog.dart); this file is
/// only the storage.
library;

import 'dart:typed_data';

import 'package:crdt_lf/crdt_lf.dart';
import 'package:sqlite3/sqlite3.dart' as sq;

import 'catalog.dart';
import 'store_exceptions.dart';

/// One row per note, keyed by ULID: the catalog.
///
/// **The diagnostic surface for this whole design.** Deleting `metadata.db`
/// costs history, never content and never identity, and recovery starts in a
/// plain SQLite browser with no application code — so `select path, ulid from
/// bf_catalog` has to answer "which note is this?" on its own. That is why the
/// human-relevant fields are plain columns rather than a serialized blob, and
/// why the enums are stored as their names rather than as ordinals: an ordinal
/// re-numbers itself the moment a third [MergePolicy] is added, silently
/// reinterpreting every row already on disk.
///
/// Does not own the connection. [MetadataDatabase] opens it, injects the
/// op-log's schema into it, and closes it; this reads and writes one table on
/// it, so a catalog write and an op-log write share one transaction boundary.
class NoteCatalog {
  const NoteCatalog(this.database);

  /// The table, `bf_`-prefixed like every table BrainFrame creates.
  ///
  /// Every column beyond the identity quartet is nullable, and each null means
  /// something specific rather than "missing": no [CatalogRow.materializedHash]
  /// is a note this device has never written, and no seed claim is a note whose
  /// first history nobody has created yet.
  static const String createSchemaSql = '''
CREATE TABLE IF NOT EXISTS bf_catalog (
  ulid              TEXT PRIMARY KEY,
  path              TEXT NOT NULL,
  merge_policy      TEXT NOT NULL,
  state             TEXT NOT NULL,
  materialized_hash TEXT,
  size              INTEGER,
  mtime_utc         INTEGER,
  sketch            BLOB,
  seeded_by         TEXT,
  seed_hlc          TEXT
);
''';

  /// At most one *findable* note per path, enforced by the database.
  ///
  /// Partial rather than a plain `UNIQUE` on the column, because a tombstoned
  /// row keeps the path it died at: deleting `inbox/today.md` and later
  /// creating a new note at that same path is ordinary use, and a total
  /// uniqueness constraint would reject the second note outright. Restricting
  /// the index to non-tombstoned rows says what is actually true — a live,
  /// history-pending, or unavailable note owns its path exclusively — and is
  /// what makes [byPath] able to return a single row rather than a list.
  ///
  /// Built from the enum's own [NoteState.tombstoned] name so the predicate
  /// cannot drift away from the values the rows are written with.
  static final String createIndexSql =
      '''
CREATE UNIQUE INDEX IF NOT EXISTS bf_catalog_findable_path
  ON bf_catalog (path) WHERE state <> '${NoteState.tombstoned.name}';
''';

  /// The connection this catalog reads and writes. Owned by [MetadataDatabase].
  final sq.Database database;

  /// Creates the table and its index if they are not already there. Idempotent,
  /// so it is safe to re-run on every open.
  static void createSchema(sq.Database database) {
    database
      ..execute(createSchemaSql)
      ..execute(createIndexSql);
  }

  /// The note at [path], or `null` if no findable note holds it.
  ///
  /// Tombstoned rows are excluded: a path a dead note used to occupy is a free
  /// path, and returning the tombstone would make the next scan resurrect its
  /// history under unrelated content.
  CatalogRow? byPath(String path) => _one(
    'SELECT * FROM bf_catalog WHERE path = ? AND state <> ?',
    [path, NoteState.tombstoned.name],
  );

  /// The note identified by [ulid], whatever its state, or `null` if this
  /// device has no row for it.
  ///
  /// Unlike [byPath] this does find tombstones, and must: a note's identity
  /// outlives its file, and a peer's operations arrive keyed by ULID long after
  /// the local scan concluded the file was gone.
  CatalogRow? byUlid(String ulid) =>
      _one('SELECT * FROM bf_catalog WHERE ulid = ?', [ulid]);

  /// Every note in [NoteState.live], ordered by path.
  ///
  /// The scan's input (Decision 6): the notes that have a file this device
  /// expects to find and an op-log it can reconcile that file against. The
  /// other states are each somebody else's question — a history-pending note
  /// has no document to diff into, a tombstone has no file, and an unavailable
  /// one has a file that cannot be read right now — so they are excluded here
  /// rather than skipped one by one inside the scan.
  ///
  /// Ordered so two scans of one engram visit notes in the same order, which
  /// makes a scan report comparable between runs and a failure reproducible.
  List<CatalogRow> live() => database
      .select('SELECT * FROM bf_catalog WHERE state = ? ORDER BY path', [
        NoteState.live.name,
      ])
      .map(_rowFrom)
      .toList();

  /// The tombstone most recently written at [path], or null if none.
  ///
  /// The counterpart of [byPath] for a note that is gone: the scan history
  /// records which note a deletion was, and a path may have died more than
  /// once, so the newest tombstone — by insertion order — is the one meant.
  CatalogRow? lastTombstoneAt(String path) => _one(
    'SELECT * FROM bf_catalog WHERE path = ? AND state = ? '
    'ORDER BY rowid DESC LIMIT 1',
    [path, NoteState.tombstoned.name],
  );

  /// How many notes this device remembers as deleted.
  int countTombstoned() =>
      database.select('SELECT COUNT(*) AS n FROM bf_catalog WHERE state = ?', [
        NoteState.tombstoned.name,
      ]).first['n'] as int;

  /// Every note that is not tombstoned, ordered by path: the notes whose file
  /// this device expects to find in the folder.
  ///
  /// The scan's other input (Decision 7): a findable note whose path is
  /// absent has gone somewhere, and which of the three answers — moved,
  /// deleted, or merely unavailable — is the scan's to work out. Tombstones
  /// are excluded because their absence is the expected state.
  List<CatalogRow> findable() => database
      .select('SELECT * FROM bf_catalog WHERE state <> ? ORDER BY path', [
        NoteState.tombstoned.name,
      ])
      .map(_rowFrom)
      .toList();

  /// Writes [row], replacing any existing row with the same ULID.
  ///
  /// Whole-row, never a delta — the same discipline the shared identity map
  /// requires — so a caller that changed one field must carry the rest forward.
  /// A partial write would silently blank whatever its author did not know
  /// about.
  void upsert(CatalogRow row) {
    database.execute(
      'INSERT INTO bf_catalog '
      '(ulid, path, merge_policy, state, materialized_hash, size, mtime_utc, '
      'sketch, seeded_by, seed_hlc) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) '
      'ON CONFLICT(ulid) DO UPDATE SET '
      'path = excluded.path, '
      'merge_policy = excluded.merge_policy, '
      'state = excluded.state, '
      'materialized_hash = excluded.materialized_hash, '
      'size = excluded.size, '
      'mtime_utc = excluded.mtime_utc, '
      'sketch = excluded.sketch, '
      'seeded_by = excluded.seeded_by, '
      'seed_hlc = excluded.seed_hlc',
      [
        row.ulid,
        row.path,
        row.mergePolicy.name,
        row.state.name,
        row.materializedHash,
        row.size,
        row.mtimeUtc?.toUtc().millisecondsSinceEpoch,
        row.sketch,
        row.seedClaim?.peerId.toString(),
        row.seedClaim?.hlc.toString(),
      ],
    );
  }

  CatalogRow? _one(String sql, List<Object?> parameters) {
    final rows = database.select(sql, parameters);
    return rows.isEmpty ? null : _rowFrom(rows.first);
  }

  /// Rebuilds a [CatalogRow] from one database row.
  ///
  /// Every parse failure becomes a [MetadataDatabaseException] naming the
  /// column and the value, matching how the store treats a schema version or a
  /// peer identity it cannot read: a row we cannot interpret is surfaced, never
  /// half-read into a default that would then be written back as truth.
  CatalogRow _rowFrom(sq.Row row) {
    final ulid = row['ulid'] as String;
    final seededBy = row['seeded_by'] as String?;
    final seedHlc = row['seed_hlc'] as String?;
    final mtime = row['mtime_utc'] as int?;
    return CatalogRow(
      ulid: ulid,
      path: row['path'] as String,
      mergePolicy: _parse(
        () => MergePolicy.parse(row['merge_policy'] as String),
        'merge_policy',
        ulid,
      ),
      state: _parse(
        () => NoteState.parse(row['state'] as String),
        'state',
        ulid,
      ),
      materializedHash: row['materialized_hash'] as String?,
      size: row['size'] as int?,
      mtimeUtc: mtime == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(mtime, isUtc: true),
      sketch: row['sketch'] as Uint8List?,
      seedClaim: _seedClaim(seededBy, seedHlc, ulid),
    );
  }

  /// The seed claim, or `null` when unclaimed.
  ///
  /// Half a claim is not an unclaimed seed, it is a corrupt row: the pair is
  /// written together and means nothing apart, so a lone peer or a lone clock
  /// is refused rather than quietly read as "nobody has seeded this", which
  /// would invite a second device to seed a document that already has a
  /// history.
  OperationId? _seedClaim(String? peer, String? hlc, String ulid) {
    if (peer == null && hlc == null) return null;
    if (peer == null || hlc == null) {
      throw MetadataDatabaseException(
        'catalog row "$ulid" has half a seed claim '
        '(seeded_by: ${peer ?? 'null'}, seed_hlc: ${hlc ?? 'null'})',
      );
    }
    return _parse(
      () => OperationId.parse('$peer@$hlc'),
      'seeded_by/seed_hlc',
      ulid,
    );
  }

  T _parse<T>(T Function() parse, String column, String ulid) {
    try {
      return parse();
    } on FormatException catch (error) {
      throw MetadataDatabaseException(
        'catalog row "$ulid" has an unreadable $column: ${error.message}',
      );
    }
  }
}
