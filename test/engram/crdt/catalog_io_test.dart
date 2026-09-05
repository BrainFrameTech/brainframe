import 'dart:typed_data';

import 'package:brainframe/engram/crdt/catalog.dart';
// NoteCatalog and MetadataDatabaseException both arrive through here:
// metadata_db_io.dart re-exports catalog_io.dart, so importing that directly
// as well would be redundant.
import 'package:brainframe/engram/crdt/metadata_db_io.dart';
import 'package:brainframe/engram/id.dart';
import 'package:crdt_lf/crdt_lf.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hlc_dart/hlc_dart.dart';
import 'package:sqlite3/sqlite3.dart' as sq;

import '../../crdt/support/peer_ids.dart';

/// The catalog table: what it stores, what it refuses, and how it is queried.
///
/// Runs against an in-memory store rather than a temporary directory — the
/// table is the subject here, and where the file lives is
/// metadata_db_io_test.dart's business.
void main() {
  late MetadataDatabase store;
  late NoteCatalog catalog;

  setUp(() {
    store = MetadataDatabase.openInMemory();
    catalog = store.catalog;
  });

  tearDown(() => store.close());

  OperationId claim(PeerId peer, int millis) =>
      OperationId(peer, HybridLogicalClock(l: millis, c: 0));

  CatalogRow row({
    String? ulid,
    String path = 'inbox/today.md',
    MergePolicy mergePolicy = MergePolicy.fugueText,
    NoteState state = NoteState.live,
    String? materializedHash,
    int? size,
    DateTime? mtimeUtc,
    Uint8List? sketch,
    OperationId? seedClaim,
  }) => CatalogRow(
    ulid: ulid ?? newUlid(),
    path: path,
    mergePolicy: mergePolicy,
    state: state,
    materializedHash: materializedHash,
    size: size,
    mtimeUtc: mtimeUtc,
    sketch: sketch,
    seedClaim: seedClaim,
  );

  /// Column names of [table], in declaration order.
  List<String> columnsOf(String table) => store.database
      .select('SELECT name FROM pragma_table_info(?) ORDER BY cid', [table])
      .map((row) => row['name'] as String)
      .toList();

  group('schema', () {
    test('the catalog holds every column the design names', () {
      expect(columnsOf('bf_catalog'), [
        'ulid',
        'path',
        'merge_policy',
        'state',
        'materialized_hash',
        'size',
        'mtime_utc',
        'sketch',
        'seeded_by',
        'seed_hlc',
      ]);
    });

    test('creating the schema twice is a no-op', () {
      // Every open re-runs the DDL; the app cannot know whether this engram
      // has been opened before, so re-creation must never reset anything.
      catalog.upsert(row(path: 'kept.md'));
      NoteCatalog.createSchema(store.database);

      expect(catalog.byPath('kept.md'), isNotNull);
    });
  });

  group('the human-readable claim', () {
    test('select path, ulid from bf_catalog answers on its own', () {
      // The whole diagnostic tree for this design: recovery from a damaged
      // store starts in a plain SQLite browser with no application code, so
      // the human-relevant fields must be plain columns rather than a blob.
      final ulid = newUlid();
      catalog.upsert(row(ulid: ulid, path: 'refs/crdt.md'));

      final rows = store.database.select(
        'SELECT path, ulid FROM bf_catalog ORDER BY path',
      );

      expect(rows.single['path'], 'refs/crdt.md');
      expect(rows.single['ulid'], ulid);
    });

    test('the enums are stored as their names, not as ordinals', () {
      // An ordinal re-numbers itself the moment a third MergePolicy is added,
      // silently reinterpreting every row already on disk.
      catalog.upsert(
        row(mergePolicy: MergePolicy.blobLww, state: NoteState.historyPending),
      );

      final stored = store.database
          .select('SELECT merge_policy, state FROM bf_catalog')
          .single;

      expect(stored['merge_policy'], 'blobLww');
      expect(stored['state'], 'historyPending');
    });
  });

  group('queries', () {
    test('a path with no note returns null', () {
      expect(catalog.byPath('nothing/here.md'), isNull);
    });

    test('a ULID with no note returns null', () {
      expect(catalog.byUlid(newUlid()), isNull);
    });

    test('byPath and byUlid find the same row', () {
      final written = row();
      catalog.upsert(written);

      expect(catalog.byPath(written.path), written);
      expect(catalog.byUlid(written.ulid), written);
    });

    test('every column round-trips through the database', () {
      final written = row(
        mergePolicy: MergePolicy.blobLww,
        state: NoteState.unavailable,
        materializedHash: 'sha256:abc',
        size: 4096,
        mtimeUtc: DateTime.utc(2026, 9, 5, 14, 49, 32),
        sketch: Uint8List.fromList([0, 1, 2, 253, 254, 255]),
        seedClaim: claim(peerB, 1234),
      );

      catalog.upsert(written);

      expect(catalog.byUlid(written.ulid), written);
    });

    test('an mtime read back is still UTC', () {
      // Stored as epoch milliseconds, which carry no zone; reconstructing in
      // local time would shift every timestamp by the reader's offset.
      final written = row(mtimeUtc: DateTime.utc(2026, 9, 5, 14, 49, 32));
      catalog.upsert(written);

      final read = catalog.byUlid(written.ulid)!;

      expect(read.mtimeUtc!.isUtc, isTrue);
      expect(read.mtimeUtc, written.mtimeUtc);
    });

    test('a local mtime is normalised to UTC on the way in', () {
      final local = DateTime(2026, 9, 5, 14, 49, 32);
      final written = row(mtimeUtc: local);
      catalog.upsert(written);

      expect(catalog.byUlid(written.ulid)!.mtimeUtc, local.toUtc());
    });

    test('an unclaimed seed reads back as no claim', () {
      final written = row();
      catalog.upsert(written);

      expect(catalog.byUlid(written.ulid)!.seedClaim, isNull);
    });
  });

  group('upsert', () {
    test('a second write to one ULID replaces the row', () {
      final ulid = newUlid();
      catalog.upsert(row(ulid: ulid, path: 'inbox/today.md'));
      catalog.upsert(row(ulid: ulid, path: 'journal/today.md'));

      expect(catalog.byUlid(ulid)!.path, 'journal/today.md');
      expect(catalog.byPath('inbox/today.md'), isNull);
    });

    test('a rename keeps the identity and the history it points at', () {
      // Exactly how the scan records a move: keep the id, update the path.
      final written = row(seedClaim: claim(peerA, 10));
      catalog.upsert(written);
      catalog.upsert(
        row(
          ulid: written.ulid,
          path: 'journal/today.md',
          seedClaim: written.seedClaim,
        ),
      );

      final moved = catalog.byUlid(written.ulid)!;

      expect(moved.path, 'journal/today.md');
      expect(moved.seedClaim, written.seedClaim);
    });

    test('a whole-row write clears a field the caller dropped', () {
      // The write is whole-row, never a delta, so this is the documented
      // behaviour rather than a bug: a caller that changed one field must
      // carry the rest forward.
      final ulid = newUlid();
      catalog.upsert(row(ulid: ulid, materializedHash: 'sha256:abc'));
      catalog.upsert(row(ulid: ulid));

      expect(catalog.byUlid(ulid)!.materializedHash, isNull);
    });
  });

  group('one findable note per path', () {
    test('two findable notes cannot claim one path', () {
      catalog.upsert(row(path: 'inbox/today.md'));

      expect(
        () => catalog.upsert(row(path: 'inbox/today.md')),
        throwsA(isA<sq.SqliteException>()),
      );
    });

    test('a history-pending note still owns its path exclusively', () {
      // It is unwritten, not absent — the file is on disk and readable.
      catalog.upsert(row(path: 'inbox/today.md', state: NoteState.live));

      expect(
        () => catalog.upsert(
          row(path: 'inbox/today.md', state: NoteState.historyPending),
        ),
        throwsA(isA<sq.SqliteException>()),
      );
    });

    test('an unavailable note still owns its path exclusively', () {
      // An unmounted drive must not let a second note take the path, or
      // remounting would produce two notes for one file.
      catalog.upsert(row(path: 'inbox/today.md', state: NoteState.unavailable));

      expect(
        () => catalog.upsert(row(path: 'inbox/today.md')),
        throwsA(isA<sq.SqliteException>()),
      );
    });

    test('a tombstone frees its path for a new note', () {
      // Deleting a file and later creating another at the same path is
      // ordinary use; a total UNIQUE on path would reject the second note.
      final dead = row(path: 'inbox/today.md', state: NoteState.tombstoned);
      catalog.upsert(dead);

      final reborn = row(path: 'inbox/today.md');
      catalog.upsert(reborn);

      expect(catalog.byPath('inbox/today.md')!.ulid, reborn.ulid);
      expect(catalog.byUlid(dead.ulid)!.state, NoteState.tombstoned);
    });

    test('any number of tombstones may share one path', () {
      // A path repeatedly created and deleted accumulates them, and none of
      // that history may block the next note.
      for (var i = 0; i < 3; i++) {
        catalog.upsert(
          row(path: 'inbox/today.md', state: NoteState.tombstoned),
        );
      }

      expect(catalog.byPath('inbox/today.md'), isNull);
    });

    test('byPath ignores tombstones; byUlid does not', () {
      // Identity outlives the file: a peer's operations arrive keyed by ULID
      // long after the local scan concluded the file was gone.
      final dead = row(state: NoteState.tombstoned);
      catalog.upsert(dead);

      expect(catalog.byPath(dead.path), isNull);
      expect(catalog.byUlid(dead.ulid), dead);
    });
  });

  group('a row it cannot read is refused, not half-read', () {
    /// Writes [value] straight into a column, standing in for a row another
    /// build — or a person with a SQLite browser — left behind.
    String forceColumn(String column, Object? value) {
      final written = row();
      catalog.upsert(written);
      store.database.execute(
        'UPDATE bf_catalog SET $column = ? WHERE ulid = ?',
        [value, written.ulid],
      );
      return written.ulid;
    }

    test('an unknown merge policy', () {
      final ulid = forceColumn('merge_policy', 'vectorInk');

      expect(
        () => catalog.byUlid(ulid),
        throwsA(
          isA<MetadataDatabaseException>().having(
            (e) => e.toString(),
            'toString',
            allOf(contains('merge_policy'), contains(ulid)),
          ),
        ),
      );
    });

    test('an unknown state', () {
      final ulid = forceColumn('state', 'archived');

      expect(
        () => catalog.byUlid(ulid),
        throwsA(isA<MetadataDatabaseException>()),
      );
    });

    test('a corrupt seed claim', () {
      final written = row(seedClaim: claim(peerA, 10));
      catalog.upsert(written);
      store.database.execute(
        "UPDATE bf_catalog SET seeded_by = 'not-a-uuid' WHERE ulid = ?",
        [written.ulid],
      );

      expect(
        () => catalog.byUlid(written.ulid),
        throwsA(isA<MetadataDatabaseException>()),
      );
    });

    test('half a seed claim is corruption, not an unclaimed seed', () {
      // Reading it as "nobody has seeded this" would invite a second device to
      // seed a document that already has a history — the one thing Decision 7
      // says must never happen.
      final ulid = forceColumn('seed_hlc', '10.0');

      expect(
        () => catalog.byUlid(ulid),
        throwsA(
          isA<MetadataDatabaseException>().having(
            (e) => e.toString(),
            'toString',
            contains('half a seed claim'),
          ),
        ),
      );
    });

    test('a seeder with no clock is refused too', () {
      final ulid = forceColumn('seeded_by', peerA.toString());

      expect(
        () => catalog.byUlid(ulid),
        throwsA(isA<MetadataDatabaseException>()),
      );
    });

    test('the failure names the row, so a person can go look at it', () {
      final ulid = forceColumn('state', 'archived');

      expect(
        () => catalog.byUlid(ulid),
        throwsA(
          isA<MetadataDatabaseException>().having(
            (e) => e.toString(),
            'toString',
            allOf(contains(ulid), contains('state')),
          ),
        ),
      );
    });
  });
}
