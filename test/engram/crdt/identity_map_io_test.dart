import 'dart:io';
import 'dart:typed_data';

import 'package:brainframe/engram/crdt/catalog.dart';
import 'package:brainframe/engram/device_name.dart';
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

  group('what a device calls itself (bf_peer)', () {
    PeerName named(PeerId peer, String name, {int millis = 500}) => PeerName(
      peer: peer,
      name: name,
      platform: 'linux',
      setAt: HybridLogicalClock(l: millis, c: 0),
    );

    test('written beside the rows, and read back by everyone', () async {
      final ours = IdentityMap(engramRoot: engram.path, peerId: peerA);
      final theirs = IdentityMap(engramRoot: engram.path, peerId: peerB);
      await ours.write([row()], self: named(peerA, 'jdoe-desktop'));
      await theirs.write(const [], self: named(peerB, 'jdoe\'s Pixel'));

      expect(ours.readOurName(), named(peerA, 'jdoe-desktop'));
      expect(await theirs.readEveryDevicesNames(), {
        peerA: named(peerA, 'jdoe-desktop'),
        peerB: named(peerB, 'jdoe\'s Pixel'),
      });
      expect(await ours.readEveryDevicesRows(), hasLength(1));
    });

    test('rewritten whole: a write without a name drops it', () async {
      await map.write(const [], self: named(peerA, 'jdoe-desktop'));
      await map.write(const []);
      expect(map.readOurName(), isNull);
    });

    test('no device may name another', () async {
      expect(
        () => map.write(const [], self: named(peerB, 'not mine')),
        throwsArgumentError,
      );
    });

    test('a row about another device, in someone\'s file, is ignored', () async {
      // A file claiming to name a device other than its writer: only the
      // writer's own row counts, and this file has none.
      final theirs = IdentityMap(engramRoot: engram.path, peerId: peerB);
      await theirs.write(const []);
      final database = sq.sqlite3.open(theirs.filePath);
      try {
        database
          ..execute(IdentityMap.createPeerSchemaSql)
          ..execute(
            'INSERT INTO bf_peer (peer, name, platform, hlc) VALUES (?, ?, ?, ?)',
            [peerA.toString(), 'impostor', 'linux', '500.0'],
          );
      } finally {
        database.close();
      }
      expect(await map.readEveryDevicesNames(), isEmpty);
    });

    test('an older build\'s file, with no bf_peer, names no one', () async {
      // An older build writes the map table alone. Its device has no name,
      // and its rows read exactly as before.
      final older = IdentityMap(engramRoot: engram.path, peerId: peerB);
      await older.write([row(recordedAt: stamp(peerB, 100))]);
      expect(await map.readEveryDevicesNames(), isEmpty);
      expect(older.readOurName(), isNull);
      expect(await map.readEveryDevicesRows(), hasLength(1));
    });

    test('the map table is untouched, so an older reader is too', () async {
      // An older build runs SELECT * FROM bf_identity_map and nothing else:
      // the name must not be in that table or change its columns.
      await map.write([row()], self: named(peerA, 'jdoe-desktop'));
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
      final database = sq.sqlite3.open(
        map.filePath,
        mode: sq.OpenMode.readOnly,
      );
      try {
        expect(
          database
              .select('SELECT COUNT(*) AS n FROM bf_identity_map')
              .first['n'],
          1,
        );
      } finally {
        database.close();
      }
    });

    test('an unreadable or unnamed file is skipped, not fatal', () async {
      await map.write(const [], self: named(peerA, 'jdoe-desktop'));
      final stray = File('${map.directoryPath}/notes.db')
        ..writeAsStringSync('');
      File(
        '${map.directoryPath}/${peerB.toString()}.db',
      ).writeAsStringSync('not a database');
      expect(await map.readEveryDevicesNames(), {
        peerA: named(peerA, 'jdoe-desktop'),
      });
      stray.deleteSync();
    });

    test('a name whose stamp cannot be read is no name', () async {
      await map.write(const [], self: named(peerA, 'jdoe-desktop'));
      final database = sq.sqlite3.open(map.filePath);
      try {
        database.execute("UPDATE bf_peer SET hlc = 'not a clock'");
      } finally {
        database.close();
      }
      expect(map.readOurName(), isNull);
    });

    /// Writes a bf_peer row for [peer] into its own file, with raw values —
    /// how a malformed or hostile device's file would look.
    void forge(PeerId peer, List<Object?> nameplatformHlc) {
      final file = IdentityMap(engramRoot: engram.path, peerId: peer);
      Directory(file.directoryPath).createSync(recursive: true);
      final database = sq.sqlite3.open(file.filePath);
      try {
        database
          ..execute(IdentityMap.createSchemaSql)
          ..execute(IdentityMap.createPeerSchemaSql)
          ..execute(
            'INSERT INTO bf_peer (peer, name, platform, hlc) '
            'VALUES (?, ?, ?, ?)',
            [peer.toString(), ...nameplatformHlc],
          );
      } finally {
        database.close();
      }
    }

    test(
      'a malformed peer file is skipped, and never stops the others',
      () async {
        // The table is not STRICT, so another device's file can hold a BLOB
        // or a number where text belongs. That file names no one; reading it
        // must not throw, or one bad file would hide every device's name.
        await map.write(const [], self: named(peerA, 'jdoe-desktop'));
        forge(peerB, [
          [1, 2, 3],
          'linux',
          '500.0',
        ]);
        // A number would be converted to text by the column's TEXT affinity;
        // a BLOB is what survives as something other than text.
        forge(peerC, [
          'jdoe\'s Pixel',
          Uint8List.fromList([1, 2]),
          '500.0',
        ]);

        expect(await map.readEveryDevicesNames(), {
          peerA: named(peerA, 'jdoe-desktop'),
        });
      },
    );

    test('another device\'s name is held to this one\'s rules', () async {
      // Read cut short and normalized, so an enormous name is never loaded
      // whole, and a blank one is no name.
      forge(peerB, ['  ${'x' * 5000}  ', 'linux', '500.0']);
      forge(peerC, ['   ', 'linux', '500.0']);

      final names = await map.readEveryDevicesNames();
      expect(names[peerB]!.name, 'x' * 64);
      expect(names.containsKey(peerC), isFalse);
    });

    test('a name stored here is read back unchanged everywhere', () async {
      // The code-point limit and the read's cut are the same number, so a
      // name heavy with combining marks — within both limits — survives the
      // bounded read whole, and every device agrees what this one is called.
      final heavy = normalizeDeviceName('e\u0301\u0302\u0303' * 70)!;
      expect(heavy.runes.length, deviceNameMaxCodePoints);
      await map.write(const [], self: named(peerA, heavy));
      final other = IdentityMap(engramRoot: engram.path, peerId: peerB);
      expect((await other.readEveryDevicesNames())[peerA]!.name, heavy);
    });

    test('a platform or stamp past its valid form names no one', () async {
      // Refused rather than cut, and never loaded whole: a cut platform or
      // stamp would be a different value, not a shorter one.
      forge(peerB, ['jdoe B', 'x' * 100000, '500.0']);
      forge(peerC, ['jdoe C', 'linux', '1' * 100000]);
      expect(await map.readEveryDevicesNames(), isEmpty);
    });

    test('a NUL cannot hide an oversized platform or stamp', () async {
      // SQLite's length() of TEXT stops at the first NUL, so a short value,
      // a NUL, and a megabyte measured five characters — and was then
      // selected whole. Counted in bytes, it is refused before it is read.
      forge(peerB, ['jdoe B', 'linux\u0000${'x' * 100000}', '500.0']);
      forge(peerC, ['jdoe C', 'linux', '500.0\u0000${'1' * 100000}']);
      expect(await map.readEveryDevicesNames(), isEmpty);
    });

    test('a file without the one-row key yields one name, not all', () async {
      // Another device's bf_peer need not carry the primary key, so it can
      // hold any number of rows about its writer; only one is ever loaded.
      final file = IdentityMap(engramRoot: engram.path, peerId: peerB);
      Directory(file.directoryPath).createSync(recursive: true);
      final database = sq.sqlite3.open(file.filePath);
      try {
        database
          ..execute(IdentityMap.createSchemaSql)
          ..execute('CREATE TABLE bf_peer (peer, name, platform, hlc)');
        final insert = database.prepare(
          'INSERT INTO bf_peer VALUES (?, ?, ?, ?)',
        );
        for (var i = 0; i < 3; i++) {
          insert.execute([peerB.toString(), 'jdoe $i', 'linux', '500.$i']);
        }
        insert.close();
      } finally {
        database.close();
      }
      expect((await map.readEveryDevicesNames())[peerB]!.name, 'jdoe 0');
    });

    test('a negative or overflowing stamp names no one, and never throws', () {
      // The clock's parser asserts non-negative parts rather than refusing
      // them, so a debug build would throw — aborting the open, for this
      // device's own file — and a release build accept the bad clock.
      for (final stamp in [
        '-1.0',
        '500.-1',
        '1.0.0',
        '99999999999999999999.0',
      ]) {
        forge(peerA, ['jdoe-desktop', 'linux', stamp]);
        expect(map.readOurName(), isNull, reason: stamp);
        File(map.filePath).deleteSync();
      }
    });

    test('a name with a NUL in it round-trips, as spaces', () async {
      // Normalized before it is stored, so the NUL that SQLite would cut
      // at is never there to cut.
      final name = normalizeDeviceName('Desk\u0000top')!;
      await map.write(const [], self: named(peerA, name));
      final other = IdentityMap(engramRoot: engram.path, peerId: peerB);
      expect((await other.readEveryDevicesNames())[peerA]!.name, 'Desk top');
      expect(map.readOurName()!.name, name, reason: 'so no republish on open');
    });

    test('a platform that is not an identifier names no one', () async {
      forge(peerB, ['jdoe B', 'Linux; DROP', '500.0']);
      forge(peerC, ['jdoe C', 'android', '500.0']);
      expect((await map.readEveryDevicesNames()).keys, [peerC]);
    });

    test('nothing to read before the shared directory exists', () async {
      expect(await map.readEveryDevicesNames(), isEmpty);
      expect(map.readOurName(), isNull);
    });

    test('a name reads as itself', () {
      expect(named(peerA, 'jdoe-desktop').toString(), contains('jdoe-desktop'));
      expect(named(peerA, 'x').hashCode, named(peerA, 'x').hashCode);
    });
  });
}
