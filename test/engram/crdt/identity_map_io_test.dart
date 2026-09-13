import 'dart:io';

import 'package:brainframe/engram/crdt/catalog.dart';
import 'package:brainframe/engram/crdt/identity_map.dart';
import 'package:brainframe/engram/crdt/identity_map_io.dart';
import 'package:brainframe/engram/crdt/metadata_db_io.dart';
import 'package:brainframe/engram/fs/fs_store_io.dart';
import 'package:brainframe/engram/id.dart';
import 'package:crdt_lf/crdt_lf.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hlc_dart/hlc_dart.dart';
import 'package:sqlite3/sqlite3.dart' as sq;

import '../../crdt/support/peer_ids.dart';

/// The identity map: one file per device inside the engram, written whole and
/// read as a union.
void main() {
  late Directory engram;
  late IdentityMap map;

  setUp(() {
    engram = Directory.systemTemp.createTempSync('brainframe_identity_map');
    map = IdentityMap(engramRoot: engram.path, peerId: peerA);
  });

  tearDown(() {
    if (engram.existsSync()) engram.deleteSync(recursive: true);
  });

  OperationId stamp(PeerId peer, int millis) =>
      OperationId(peer, HybridLogicalClock(l: millis, c: 0));

  IdentityRow row({
    String? ulid,
    String path = 'inbox/today.md',
    MergePolicy mergePolicy = MergePolicy.fugueText,
    OperationId? recordedAt,
    bool deleted = false,
    OperationId? seedClaim,
  }) => IdentityRow(
    ulid: ulid ?? newUlid(),
    path: path,
    mergePolicy: mergePolicy,
    recordedAt: recordedAt ?? stamp(peerA, 100),
    deleted: deleted,
    seedClaim: seedClaim,
  );

  /// Column names of the map table in [path], in declaration order.
  List<String> columnsOf(String path) {
    final database = sq.sqlite3.open(path, mode: sq.OpenMode.readOnly);
    try {
      return database
          .select(
            "SELECT name FROM pragma_table_info('bf_identity_map') "
            'ORDER BY cid',
          )
          .map((row) => row['name'] as String)
          .toList();
    } finally {
      database.close();
    }
  }

  /// Every file anywhere under the engram's marker directory.
  List<File> markerFiles() => Directory(
    '${engram.path}/$markerDirectoryName',
  ).listSync(recursive: true, followLinks: false).whereType<File>().toList();

  group('where the file goes', () {
    test('one file per device, named by its peerID', () async {
      await map.write([row()]);

      expect(
        File(
          '${engram.path}/$markerDirectoryName/shared/$peerA.db',
        ).existsSync(),
        isTrue,
      );
    });

    test('the directory is created if it is not there yet', () async {
      expect(Directory(map.directoryPath).existsSync(), isFalse);

      await map.write([row()]);

      expect(Directory(map.directoryPath).existsSync(), isTrue);
    });

    test('a second device adds a file rather than replacing one', () async {
      // A directory holding three files means three devices have written here.
      await map.write([row(path: 'a.md')]);
      await IdentityMap(
        engramRoot: engram.path,
        peerId: peerB,
      ).write([row(path: 'b.md', recordedAt: stamp(peerB, 100))]);

      expect(
        Directory(map.directoryPath)
            .listSync()
            .whereType<File>()
            .map((file) => file.uri.pathSegments.last)
            .toSet(),
        {'$peerA.db', '$peerB.db'},
      );
    });
  });

  group('the write is safe to observe', () {
    test('no -wal or -shm sidecars are left beside the map', () async {
      // VACUUM INTO produces a self-contained file; a plain copy of a live
      // database would leave journal sidecars a sync service ships separately
      // and may deliver out of order.
      await map.write([row()]);

      expect(
        markerFiles().map((file) => file.path),
        everyElement(endsWith('.db')),
      );
    });

    test('the map is the only thing left behind', () async {
      await map.write([row()]);

      // The staging directory is watched by a sync service like everything
      // else here, so leaving one behind per write would ship a folder of
      // abandoned workspaces.
      expect(Directory(map.directoryPath).listSync().map((e) => e.path), [
        map.filePath,
      ]);
    });

    test('a leftover workspace cannot block future writes', () async {
      // VACUUM INTO refuses a destination that exists, so a crashed write
      // must not be able to poison every later one by leaving debris under a
      // name the next write would reuse.
      await Directory(map.directoryPath).create(recursive: true);
      final stale = await Directory(map.directoryPath).createTemp('.write-');
      File('${stale.path}/map.db').writeAsStringSync('debris');

      await expectLater(map.write([row()]), completes);
      expect((await map.readEveryDevicesRows()).length, 1);
    });

    test('the staging directory is not mistaken for a peer', () async {
      // It sits in the same directory the reader unions over, holding a file
      // called map.db. A reader listing recursively, or not filtering to
      // files, would union a half-written map as though it were a device.
      await map.write([row(path: 'ours.md')]);
      final stale = await Directory(map.directoryPath).createTemp('.write-');
      addTearDown(() => stale.deleteSync(recursive: true));
      File('${stale.path}/map.db').writeAsStringSync('debris');

      expect((await map.readEveryDevicesRows()).map((r) => r.path), [
        'ours.md',
      ]);
    });

    test('rewriting replaces the previous contents wholly', () async {
      final first = row(path: 'first.md');
      await map.write([first]);
      final second = row(path: 'second.md');
      await map.write([second]);

      final rows = await map.readEveryDevicesRows();
      expect(rows.map((r) => r.path), ['second.md']);
      expect(rows.map((r) => r.ulid), isNot(contains(first.ulid)));
    });
  });

  group('rows round-trip', () {
    test('every field survives a write and a read', () async {
      final written = row(
        path: 'refs/diagram.png',
        mergePolicy: MergePolicy.blobLww,
        recordedAt: stamp(peerB, 4242),
        deleted: true,
        seedClaim: stamp(peerC, 7),
      );

      await map.write([written]);

      expect(await map.readEveryDevicesRows(), [written]);
    });

    test('an unclaimed seed reads back as no claim', () async {
      final written = row();
      await map.write([written]);

      expect((await map.readEveryDevicesRows()).single.seedClaim, isNull);
      expect((await map.readEveryDevicesRows()).single.seededBy, isNull);
    });

    test('a live row is not deleted', () async {
      await map.write([row()]);

      expect((await map.readEveryDevicesRows()).single.deleted, isFalse);
    });

    test('many rows survive one write', () async {
      final rows = [for (var i = 0; i < 25; i++) row(path: 'note-$i.md')];

      await map.write(rows);

      expect((await map.readEveryDevicesRows()).toSet(), rows.toSet());
    });

    test('writing no rows produces an empty map, not a missing one', () async {
      await map.write([]);

      expect(File(map.filePath).existsSync(), isTrue);
      expect(await map.readEveryDevicesRows(), isEmpty);
    });
  });

  group('reading is a union over every device', () {
    test('rows from both files come back', () async {
      final ours = row(path: 'ours.md');
      final theirs = row(path: 'theirs.md', recordedAt: stamp(peerB, 200));
      await map.write([ours]);
      await IdentityMap(engramRoot: engram.path, peerId: peerB).write([theirs]);

      expect((await map.readEveryDevicesRows()).toSet(), {ours, theirs});
    });

    test('contradictions are returned, not resolved', () async {
      // Two files each carrying a row for one ULID is exactly the case the
      // merge rules exist for. The reader must not quietly pick a winner —
      // that decision belongs to step 6 and has to be visible to it.
      final ulid = newUlid();
      await map.write([
        row(ulid: ulid, path: 'old/path.md', recordedAt: stamp(peerA, 100)),
      ]);
      await IdentityMap(engramRoot: engram.path, peerId: peerB).write([
        row(ulid: ulid, path: 'new/path.md', recordedAt: stamp(peerB, 200)),
      ]);

      final rows = await map.readEveryDevicesRows();

      expect(rows.length, 2);
      expect(rows.map((r) => r.path).toSet(), {'old/path.md', 'new/path.md'});
    });

    test('our own rows are included, not excluded', () async {
      await map.write([row(path: 'ours.md')]);

      expect((await map.readEveryDevicesRows()).map((r) => r.path), [
        'ours.md',
      ]);
    });

    test('readOurs sees only this device\'s file', () async {
      await map.write([row(path: 'ours.md')]);
      await IdentityMap(
        engramRoot: engram.path,
        peerId: peerB,
      ).write([row(path: 'theirs.md', recordedAt: stamp(peerB, 200))]);

      expect((await map.readOurs()).map((r) => r.path), ['ours.md']);
    });

    test('an engram nobody has written to reads empty', () async {
      expect(await map.readEveryDevicesRows(), isEmpty);
      expect(await map.readOurs(), isEmpty);
    });

    test('non-database files in the directory are ignored', () async {
      await map.write([row()]);
      File('${map.directoryPath}/.DS_Store').writeAsStringSync('junk');

      expect((await map.readEveryDevicesRows()).length, 1);
    });

    test('a half-arrived peer file is skipped, not fatal', () async {
      // These files come through a sync service, which may be part-way
      // through writing one. Refusing to open the engram over that would be
      // the wrong trade; the unseen row can at worst produce a second ULID
      // for a path, which the lowest-ULID election resolves.
      await map.write([row(path: 'ours.md')]);
      File('${map.directoryPath}/$peerB.db').writeAsStringSync('not sqlite');

      expect((await map.readEveryDevicesRows()).map((r) => r.path), [
        'ours.md',
      ]);
    });

    test('a readable file with an unreadable row is surfaced', () async {
      // Not a sync artefact: the file opened fine and its contents are wrong,
      // which is the case the store refuses rather than guesses at.
      await map.write([row()]);
      final database = sq.sqlite3.open(map.filePath);
      database
        ..execute("UPDATE bf_identity_map SET merge_policy = 'vectorInk'")
        ..close();

      await expectLater(
        map.readEveryDevicesRows(),
        throwsA(isA<MetadataDatabaseException>()),
      );
    });
  });

  group('the content hash never leaves the device', () {
    test('the map schema has no hash, size, or mtime column', () async {
      await map.write([row()]);

      expect(columnsOf(map.filePath), [
        'ulid',
        'path',
        'merge_policy',
        'deleted',
        'seeded_by',
        'seed_hlc',
        'peer',
        'hlc',
      ]);
    });

    test('no file under .brainframe/ contains device-local state', () async {
      // The one-line test guarding a failure that is invisible until a second
      // device holds unmerged operations: a shared hash makes that device
      // conclude there is no drift, skip the reconcile, and overwrite the
      // other's edit. Decision 5 walks the sequence.
      const hash = 'sha256:DEVICE-LOCAL-HASH-SENTINEL';
      const mtime = 'MTIME-SENTINEL';

      final store = MetadataDatabase.openInMemory();
      addTearDown(store.close);
      final note = row();
      store.catalog.upsert(
        CatalogRow(
          ulid: note.ulid,
          path: note.path,
          mergePolicy: note.mergePolicy,
          state: NoteState.live,
          materializedHash: hash,
          size: 4096,
          mtimeUtc: DateTime.utc(2026, 9, 5),
        ),
      );

      // The map is written from the same note, carrying only shared fields.
      await map.write([note]);

      for (final file in markerFiles()) {
        final bytes = String.fromCharCodes(file.readAsBytesSync());
        expect(
          bytes,
          isNot(contains(hash)),
          reason: '${file.path} carries the materialized hash',
        );
        expect(bytes, isNot(contains(mtime)), reason: file.path);
      }
    });
  });

  group('DebouncedIdentityMapWriter', () {
    // The timer discipline is tested against a recording callback rather than
    // the real map: fakeAsync drives timers, never real file I/O, so a test
    // that waited on a write to disk inside it would hang rather than fail.
    late List<List<IdentityRow>> writes;
    late DebouncedIdentityMapWriter writer;

    setUp(() {
      writes = [];
      writer = DebouncedIdentityMapWriter((rows) async => writes.add(rows));
    });

    tearDown(() => writer.dispose());

    test('an idle burst costs one write', () {
      fakeAsync((async) {
        writer.schedule([row(path: 'a.md')]);
        async.elapse(const Duration(seconds: 2));
        writer.schedule([row(path: 'b.md')]);
        async.elapse(const Duration(seconds: 2));
        writer.schedule([row(path: 'c.md')]);

        // Nothing yet: each edit reset the idle timer.
        expect(writes, isEmpty);

        async
          ..elapse(const Duration(seconds: 5))
          ..flushMicrotasks();

        // The folder is watched by a sync service, so every write is a file it
        // has to ship. A burst of renames must cost one.
        expect(writes.length, 1);
        expect(writes.single.map((r) => r.path), ['c.md']);
      });
    });

    test('the max-wait cap fires during an uninterrupted burst', () {
      fakeAsync((async) {
        // Never idle long enough for the debounce, for longer than the cap.
        for (var i = 0; i < 20; i++) {
          writer.schedule([row(path: 'note-$i.md')]);
          async.elapse(const Duration(seconds: 2));
        }
        async.flushMicrotasks();

        expect(
          writes,
          isNotEmpty,
          reason: 'an uninterrupted burst must still reach disk',
        );
      });
    });

    test('the cap does not re-arm mid-burst', () {
      fakeAsync((async) {
        for (var i = 0; i < 20; i++) {
          writer.schedule([row(path: 'note-$i.md')]);
          async.elapse(const Duration(seconds: 2));
        }
        async.flushMicrotasks();

        // 40 seconds of continuous editing crosses the 30s cap once. A cap
        // re-armed on every edit would never fire; one re-armed only after a
        // flush is the shape the editor already uses.
        expect(writes.length, 1);
      });
    });

    test('an idle writer schedules nothing', () {
      fakeAsync((async) {
        async
          ..elapse(const Duration(minutes: 5))
          ..flushMicrotasks();

        expect(writes, isEmpty);
      });
    });

    test('flush writes immediately and clears the debt', () async {
      writer.schedule([row()]);
      expect(writer.isDirty, isTrue);

      await writer.flush();

      expect(writer.isDirty, isFalse);
      expect(writes.length, 1);
    });

    test('flushing with nothing owed writes nothing', () async {
      await writer.flush();

      expect(writes, isEmpty);
    });

    test('a later schedule supersedes an unwritten one', () async {
      writer
        ..schedule([row(path: 'superseded.md')])
        ..schedule([row(path: 'final.md')]);

      await writer.flush();

      // The map is always written whole, so an intermediate state has no
      // value and only the latest set matters.
      expect(writes.single.map((r) => r.path), ['final.md']);
    });

    test('dispose drops the pending write and stops the timers', () {
      fakeAsync((async) {
        writer.schedule([row()]);

        writer.dispose();
        async
          ..elapse(const Duration(minutes: 1))
          ..flushMicrotasks();

        // A lost rename, not a corrupted map; the next scan recovers it.
        expect(writer.isDirty, isFalse);
        expect(writes, isEmpty);
      });
    });
  });

  group('the debounced writer over the real map', () {
    test('a flush lands the rows on disk', () async {
      final writer = DebouncedIdentityMapWriter(map.write);
      addTearDown(writer.dispose);

      writer.schedule([row(path: 'landed.md')]);
      await writer.flush();

      expect((await map.readEveryDevicesRows()).map((r) => r.path), [
        'landed.md',
      ]);
    });
  });

  group('peersSeen', () {
    test('no shared directory means no peers', () async {
      final map = IdentityMap(engramRoot: engram.path, peerId: peerA);
      expect(await map.peersSeen(), isEmpty);
    });

    test('one peer per map file, ours included once written', () async {
      final ours = IdentityMap(engramRoot: engram.path, peerId: peerA);
      final theirs = IdentityMap(engramRoot: engram.path, peerId: peerB);
      await theirs.write(const []);
      expect(await ours.peersSeen(), [peerB], reason: 'an empty file counts');

      await ours.write(const []);
      expect(await ours.peersSeen(), unorderedEquals([peerA, peerB]));
    });

    test('a file that is not named for a peer is not a device', () async {
      final map = IdentityMap(engramRoot: engram.path, peerId: peerA);
      await map.write(const []);
      File('${map.directoryPath}/stray.db').writeAsStringSync('');
      File('${map.directoryPath}/notes.txt').writeAsStringSync('');

      expect(await map.peersSeen(), [peerA]);
    });
  });
}
