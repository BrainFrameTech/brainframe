import 'dart:io';

import 'package:brainframe/engram/crdt/app_data_resolver_io.dart';
import 'package:brainframe/engram/crdt/metadata_db_io.dart';
import 'package:brainframe/engram/crdt/schema.dart';
import 'package:brainframe/engram/id.dart';
import 'package:crdt_lf/crdt_lf.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sq;

import '../../crdt/support/peer_ids.dart';
import '../../crdt/support/replica.dart';

/// The device-local store: opening it, what it stamps, and moving it.
void main() {
  late Directory root;
  late AppDataRootResolver resolveRoot;

  setUp(() {
    root = Directory.systemTemp.createTempSync('brainframe_metadata_db');
    resolveRoot = appDataRootResolver(overridePath: root.path);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// Every table name in [db], excluding SQLite's own bookkeeping.
  Set<String> tableNames(sq.Database db) {
    final rows = db.select(
      "SELECT name FROM sqlite_master WHERE type = 'table' "
      "AND name NOT LIKE 'sqlite_%' ORDER BY name",
    );
    return {for (final row in rows) row['name'] as String};
  }

  group('open', () {
    test('creates the store under the engram ULID', () async {
      final id = newUlid();
      final store = await MetadataDatabase.open(id, resolveRoot: resolveRoot);
      addTearDown(store.close);

      expect(
        File('${root.path}/engrams/$id/metadata.db').existsSync(),
        isTrue,
      );
    });

    test('holds our tables and the op-log in one file', () async {
      final store = await MetadataDatabase.open(
        newUlid(),
        resolveRoot: resolveRoot,
      );
      addTearDown(store.close);

      expect(tableNames(store.database), {'bf_meta', 'changes', 'snapshots'});
    });

    test('stamps the current schema version', () async {
      final store = await MetadataDatabase.open(
        newUlid(),
        resolveRoot: resolveRoot,
      );
      addTearDown(store.close);

      expect(store.schemaVersion, MetadataDatabase.currentSchemaVersion);
    });

    test('mints a peer identity on first open', () async {
      final store = await MetadataDatabase.open(
        newUlid(),
        resolveRoot: resolveRoot,
      );
      addTearDown(store.close);

      expect(store.peerId.id, isNotEmpty);
      // Parsing its own rendering proves it is a well-formed PeerId, which is
      // what the op-log will stamp every operation with.
      expect(PeerId.parse(store.peerId.toString()), store.peerId);
    });

    test('keeps one peer identity across reopen', () async {
      final id = newUlid();
      final first = await MetadataDatabase.open(id, resolveRoot: resolveRoot);
      final minted = first.peerId;
      first.close();

      final second = await MetadataDatabase.open(id, resolveRoot: resolveRoot);
      addTearDown(second.close);

      expect(
        second.peerId,
        minted,
        reason: 'a re-mint on every open would make this device many peers',
      );
    });

    test('mints a distinct peer identity per engram', () async {
      final a = await MetadataDatabase.open(
        newUlid(),
        resolveRoot: resolveRoot,
      );
      addTearDown(a.close);
      final b = await MetadataDatabase.open(
        newUlid(),
        resolveRoot: resolveRoot,
      );
      addTearDown(b.close);

      expect(
        a.peerId,
        isNot(b.peerId),
        reason: 'scoping per engram avoids a correlatable device identifier',
      );
    });

    test('re-injecting the CRDT schema preserves our data', () async {
      final id = newUlid();
      final first = await MetadataDatabase.open(id, resolveRoot: resolveRoot);
      final peer = first.peerId;
      first.close();

      // Every open re-runs both DDLs; the app cannot know whether this engram
      // has been opened before, so re-injection must never reset anything.
      final second = await MetadataDatabase.open(id, resolveRoot: resolveRoot);
      addTearDown(second.close);

      expect(second.peerId, peer);
      expect(second.schemaVersion, MetadataDatabase.currentSchemaVersion);
    });
  });

  group('the bf_ table-name convention', () {
    test('every table is either ours or the library\'s', () async {
      final store = await MetadataDatabase.open(
        newUlid(),
        resolveRoot: resolveRoot,
      );
      addTearDown(store.close);

      // The enforcement point for the rule in schema.dart. A future table
      // added without the prefix fails here rather than colliding silently
      // with an upstream name in a user's engram.
      for (final name in tableNames(store.database)) {
        expect(
          isPermittedTableName(name),
          isTrue,
          reason: '"$name" is neither bf_-prefixed nor a crdt_lf_sqlite table',
        );
      }
    });

    test('we actually own at least one table', () async {
      final store = await MetadataDatabase.open(
        newUlid(),
        resolveRoot: resolveRoot,
      );
      addTearDown(store.close);

      // Guards the test above from passing vacuously if our schema were ever
      // reduced to nothing.
      expect(
        tableNames(store.database).where(
          (name) => name.startsWith(brainframeTablePrefix),
        ),
        isNotEmpty,
      );
    });

    test('the names the library claims are the ones we avoid', () {
      // If crdt_lf_sqlite renames or adds a table, this fails and the constant
      // in schema.dart is updated deliberately rather than drifting.
      final store = MetadataDatabase.openInMemory();
      addTearDown(store.close);

      expect(
        tableNames(store.database).difference({'bf_meta'}),
        crdtTableNames,
      );
    });
  });

  group('schema version', () {
    /// Writes [value] straight into an existing store's meta table, standing
    /// in for a database another build left behind.
    Future<void> forceMeta(String id, String key, String value) async {
      final store = await MetadataDatabase.open(id, resolveRoot: resolveRoot);
      store.database.execute(
        'INSERT INTO bf_meta (key, value) VALUES (?, ?) '
        'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
        [key, value],
      );
      store.close();
    }

    test('a newer build\'s database is refused, not half-read', () async {
      final id = newUlid();
      await forceMeta(id, 'schema_version', '2');

      await expectLater(
        MetadataDatabase.open(id, resolveRoot: resolveRoot),
        throwsA(isA<MetadataDatabaseException>()),
      );
    });

    test('an unparseable version is refused', () async {
      final id = newUlid();
      await forceMeta(id, 'schema_version', 'banana');

      await expectLater(
        MetadataDatabase.open(id, resolveRoot: resolveRoot),
        throwsA(isA<MetadataDatabaseException>()),
      );
    });

    test('a nonsensical version is refused', () async {
      final id = newUlid();
      await forceMeta(id, 'schema_version', '0');

      await expectLater(
        MetadataDatabase.open(id, resolveRoot: resolveRoot),
        throwsA(isA<MetadataDatabaseException>()),
      );
    });

    test('a corrupt peer identity is refused', () async {
      final id = newUlid();
      await forceMeta(id, 'peer_id', 'not-a-uuid');

      await expectLater(
        MetadataDatabase.open(id, resolveRoot: resolveRoot),
        throwsA(isA<MetadataDatabaseException>()),
      );
    });
  });

  group('exceptions say what went wrong', () {
    // Both are surfaced to a person eventually — a refused open and a store
    // collision are both "look at this yourself" states — so the message has
    // to carry the detail rather than just the type.
    test('a refused open names the problem', () async {
      final id = newUlid();
      final store = await MetadataDatabase.open(id, resolveRoot: resolveRoot);
      store.database.execute(
        "UPDATE bf_meta SET value = '99' WHERE key = 'schema_version'",
      );
      store.close();

      expect(
        MetadataDatabase.open(id, resolveRoot: resolveRoot),
        throwsA(
          isA<MetadataDatabaseException>().having(
            (e) => e.toString(),
            'toString',
            allOf(contains('99'), contains('newer build')),
          ),
        ),
      );
    });

    test('a collision names the occupied store', () async {
      final from = newUlid();
      final to = newUlid();
      (await MetadataDatabase.open(from, resolveRoot: resolveRoot)).close();
      (await MetadataDatabase.open(to, resolveRoot: resolveRoot)).close();

      await expectLater(
        relocateEngramStore(
          fromEngramId: from,
          toEngramId: to,
          resolveRoot: resolveRoot,
        ),
        throwsA(
          isA<EngramStoreCollisionException>().having(
            (e) => e.toString(),
            'toString',
            contains(to),
          ),
        ),
      );
    });
  });

  group('relocateEngramStore', () {
    test('a changed engram ULID moves the store intact', () async {
      final from = newUlid();
      final to = newUlid();

      // Populate the store with everything that must survive: the peer
      // identity, the schema stamp, and a real op-log entry.
      final before = await MetadataDatabase.open(from, resolveRoot: resolveRoot);
      final peer = before.peerId;
      final author = Replica.named(peerA, label: 'author');
      author.note.insert(0, 'history that must survive a rename');
      before.crdt
          .changeStorageForDocument(kDocumentId)
          .saveChanges(author.exportChanges());
      before.close();

      await relocateEngramStore(
        fromEngramId: from,
        toEngramId: to,
        resolveRoot: resolveRoot,
      );

      expect(Directory('${root.path}/engrams/$from').existsSync(), isFalse);

      final after = await MetadataDatabase.open(to, resolveRoot: resolveRoot);
      addTearDown(after.close);

      expect(after.peerId, peer, reason: 'the device identity is unchanged');
      expect(after.schemaVersion, MetadataDatabase.currentSchemaVersion);

      final restored = Replica.named(peerB, label: 'restored');
      restored.importChanges(
        after.crdt.changeStorageForDocument(kDocumentId).getChanges(),
      );
      expect(
        restored.text,
        'history that must survive a rename',
        reason: 'the engram ULID names the directory, nothing inside the file',
      );
    });

    test('an occupied destination is surfaced, never merged', () async {
      final from = newUlid();
      final to = newUlid();
      (await MetadataDatabase.open(from, resolveRoot: resolveRoot)).close();
      (await MetadataDatabase.open(to, resolveRoot: resolveRoot)).close();

      await expectLater(
        relocateEngramStore(
          fromEngramId: from,
          toEngramId: to,
          resolveRoot: resolveRoot,
        ),
        throwsA(isA<EngramStoreCollisionException>()),
      );

      expect(
        Directory('${root.path}/engrams/$from').existsSync(),
        isTrue,
        reason: 'a refused relocation leaves both stores where they were',
      );
    });

    test('a missing source is a no-op', () async {
      // An engram that has never been opened has no store; it simply gets one
      // under the new id on its next open.
      await expectLater(
        relocateEngramStore(
          fromEngramId: newUlid(),
          toEngramId: newUlid(),
          resolveRoot: resolveRoot,
        ),
        completes,
      );
    });

    test('relocating onto itself is a no-op', () async {
      final id = newUlid();
      (await MetadataDatabase.open(id, resolveRoot: resolveRoot)).close();

      await relocateEngramStore(
        fromEngramId: id,
        toEngramId: id,
        resolveRoot: resolveRoot,
      );

      expect(Directory('${root.path}/engrams/$id').existsSync(), isTrue);
    });
  });
}
