import 'dart:io';

import 'package:brainframe/engram/crdt/catalog.dart';
import 'package:brainframe/engram/crdt/identity_authorship_io.dart';
import 'package:brainframe/engram/crdt/identity_map.dart';
import 'package:brainframe/engram/crdt/identity_map_io.dart';
import 'package:brainframe/engram/id.dart';
import 'package:crdt_lf/crdt_lf.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hlc_dart/hlc_dart.dart';

import '../../crdt/support/peer_ids.dart';

/// The rows this device has authored in the shared map, and the write that
/// keeps the map honest.
void main() {
  late Directory root;
  late IdentityMap map;

  setUp(() {
    root = Directory.systemTemp.createTempSync('brainframe_authored');
    map = IdentityMap(engramRoot: root.path, peerId: peerA);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  CatalogRow note(String path, {String? ulid, OperationId? seed}) => CatalogRow(
    ulid: ulid ?? newUlid(),
    path: path,
    mergePolicy: MergePolicy.fugueText,
    state: NoteState.live,
    seedClaim: seed ?? OperationId(peerA, HybridLogicalClock.now()),
  );

  /// A writer that hands rows straight to [sink] with no timers.
  DebouncedIdentityMapWriter immediate(List<List<IdentityRow>> sink) =>
      DebouncedIdentityMapWriter(
        (rows) async => sink.add(rows),
        idleDebounce: Duration.zero,
        maxWait: Duration.zero,
      );

  test('starts from what this device last wrote', () async {
    // Starting empty would republish only the newest claim and silently
    // retract every earlier one.
    final earlier = note('a.md');
    await map.write([
      IdentityRow(
        ulid: earlier.ulid,
        path: earlier.path,
        mergePolicy: earlier.mergePolicy,
        recordedAt: OperationId(peerA, HybridLogicalClock.now()),
        seedClaim: earlier.seedClaim,
      ),
    ]);

    final authored = await AuthoredIdentity.load(map);
    addTearDown(authored.dispose);

    expect(authored.rows.keys, [earlier.ulid]);
  });

  test(
    'records the whole row, stamped by this device, and schedules a write',
    () async {
      final written = <List<IdentityRow>>[];
      final authored = await AuthoredIdentity.load(
        map,
        writer: immediate(written),
      );
      addTearDown(authored.dispose);
      final row = note('a.md');

      authored.record(row, deleted: false);
      await authored.flush();

      expect(written, hasLength(1));
      final published = written.single.single;
      expect(published.ulid, row.ulid);
      expect(published.path, 'a.md');
      expect(published.mergePolicy, MergePolicy.fugueText);
      expect(published.seedClaim, row.seedClaim);
      expect(published.deleted, isFalse);
      expect(published.recordedBy, peerA);
    },
  );

  test('a later claim about one note replaces the earlier one', () async {
    final written = <List<IdentityRow>>[];
    final authored = await AuthoredIdentity.load(
      map,
      writer: immediate(written),
    );
    addTearDown(authored.dispose);
    final row = note('a.md');

    authored.record(row, deleted: false);
    authored.record(
      CatalogRow(
        ulid: row.ulid,
        path: 'b.md',
        mergePolicy: row.mergePolicy,
        state: row.state,
        seedClaim: row.seedClaim,
      ),
      deleted: false,
    );
    await authored.flush();

    expect(authored.rows.length, 1);
    expect(authored.rows[row.ulid]!.path, 'b.md');
    expect(written.last.single.path, 'b.md');
  });

  test('a deletion is the same row with the flag set', () async {
    final authored = await AuthoredIdentity.load(map);
    addTearDown(authored.dispose);
    final row = note('a.md');

    authored.record(row, deleted: true);
    await authored.flush();

    final onDisk = await map.readOurs();
    expect(onDisk.single.deleted, isTrue);
    expect(onDisk.single.path, 'a.md', reason: 'the path it died at');
    expect(onDisk.single.seedClaim, row.seedClaim, reason: 'carried forward');
  });

  test('flush writes the file, and a reload reads it back', () async {
    final authored = await AuthoredIdentity.load(map);
    addTearDown(authored.dispose);
    final a = note('a.md');
    final b = note('b.md');
    authored.record(a, deleted: false);
    authored.record(b, deleted: false);

    await authored.flush();
    final reloaded = await AuthoredIdentity.load(map);
    addTearDown(reloaded.dispose);

    expect(reloaded.rows.keys, unorderedEquals([a.ulid, b.ulid]));
  });

  group('repairFrom', () {
    test('records our mints the file lacks, tombstones as deleted', () async {
      // The file is behind the catalog: a write was lost to the debounce.
      final written = <List<IdentityRow>>[];
      final authored = await AuthoredIdentity.load(
        map,
        writer: immediate(written),
      );
      addTearDown(authored.dispose);
      final minted = note('a.md');
      final gone = CatalogRow(
        ulid: newUlid(),
        path: 'gone.md',
        mergePolicy: MergePolicy.fugueText,
        state: NoteState.tombstoned,
        seedClaim: OperationId(peerA, HybridLogicalClock.now()),
      );

      expect(authored.repairFrom([minted, gone]), 2);
      await authored.flush();

      expect(authored.rows.keys, containsAll([minted.ulid, gone.ulid]));
      expect(authored.rows[minted.ulid]!.deleted, isFalse);
      expect(authored.rows[gone.ulid]!.deleted, isTrue);
      expect(authored.rows[gone.ulid]!.path, 'gone.md');
      expect(written, isNotEmpty, reason: 'a repair is a write');
    });

    test('leaves rows the file already states alone', () async {
      final written = <List<IdentityRow>>[];
      final authored = await AuthoredIdentity.load(
        map,
        writer: immediate(written),
      );
      addTearDown(authored.dispose);
      final minted = note('a.md');
      authored.record(minted, deleted: false);
      await authored.flush();
      written.clear();

      expect(authored.repairFrom([minted]), 0);
      await authored.flush();

      expect(written, isEmpty, reason: 'a healthy open schedules no write');
    });

    test('re-records a row the catalog states differently', () async {
      final written = <List<IdentityRow>>[];
      final authored = await AuthoredIdentity.load(
        map,
        writer: immediate(written),
      );
      addTearDown(authored.dispose);
      final minted = note('a.md');
      authored.record(minted, deleted: false);
      final moved = CatalogRow(
        ulid: minted.ulid,
        path: 'b.md',
        mergePolicy: minted.mergePolicy,
        state: NoteState.live,
        seedClaim: minted.seedClaim,
      );

      expect(authored.repairFrom([moved]), 1);

      expect(authored.rows[minted.ulid]!.path, 'b.md');
    });

    test('ignores notes another device seeded', () async {
      // Those claims are theirs; a rename of ours over one is not knowable
      // from the catalog alone, and is the flush-on-quit's job.
      final authored = await AuthoredIdentity.load(map, writer: immediate([]));
      addTearDown(authored.dispose);
      final theirs = note(
        'theirs.md',
        seed: OperationId(peerB, HybridLogicalClock.now()),
      );

      expect(authored.repairFrom([theirs]), 0);

      expect(authored.rows, isEmpty);
    });
  });

  test('dispose drops what was pending without writing it', () async {
    final written = <List<IdentityRow>>[];
    final authored = await AuthoredIdentity.load(
      map,
      writer: DebouncedIdentityMapWriter(
        (rows) async => written.add(rows),
        idleDebounce: const Duration(days: 1),
        maxWait: const Duration(days: 1),
      ),
    );
    authored.record(note('a.md'), deleted: false);

    authored.dispose();
    await authored.flush();

    expect(written, isEmpty);
    expect(File(map.filePath).existsSync(), isFalse);
  });

  group('what this device calls itself (the device names design)', () {
    test('publishing writes the name with the rows', () async {
      final authored = await AuthoredIdentity.load(map);
      addTearDown(authored.dispose);
      final claim = note('a.md');
      authored.record(claim, deleted: false);

      expect(authored.publishName('jdoe-desktop', platform: 'linux'), isTrue);
      await authored.flush();

      final written = map.readOurName()!;
      expect(written.name, 'jdoe-desktop');
      expect(written.platform, 'linux');
      expect(written.peer, peerA);
      expect(await map.readOurs(), hasLength(1), reason: 'the rows still go');
    });

    test('a later claim never drops a name published earlier', () async {
      // The file is rewritten whole for every claim; the name is carried in
      // every rewrite, including one in a later session that has not
      // published yet.
      final first = await AuthoredIdentity.load(map);
      first.publishName('jdoe-desktop', platform: 'linux');
      await first.flush();

      final second = await AuthoredIdentity.load(map);
      addTearDown(second.dispose);
      expect(second.name?.name, 'jdoe-desktop', reason: 'loaded with rows');
      second.record(note('b.md'), deleted: false);
      await second.flush();

      expect(map.readOurName()?.name, 'jdoe-desktop');
    });

    test('quiet when the name is already published', () async {
      final writes = <List<IdentityRow>>[];
      await map.write(
        const [],
        self: PeerName(
          peer: peerA,
          name: 'jdoe-desktop',
          platform: 'linux',
          setAt: HybridLogicalClock(l: 1, c: 0),
        ),
      );
      final authored = await AuthoredIdentity.load(
        map,
        writer: immediate(writes),
      );
      addTearDown(authored.dispose);

      expect(authored.publishName('jdoe-desktop', platform: 'linux'), isFalse);
      await authored.flush();
      expect(writes, isEmpty, reason: 'every open publishes; few write');

      expect(authored.publishName('Work laptop', platform: 'linux'), isTrue);
      await authored.flush();
      expect(writes, hasLength(1));
      expect(authored.name?.name, 'Work laptop');
      expect(
        authored.name!.setAt.compareTo(HybridLogicalClock(l: 1, c: 0)),
        greaterThan(0),
        reason: 'a rename is stamped anew',
      );
    });

    test('a changed platform alone is published too', () async {
      final authored = await AuthoredIdentity.load(map);
      addTearDown(authored.dispose);
      authored.publishName('jdoe', platform: 'linux');
      expect(authored.publishName('jdoe', platform: 'android'), isTrue);
    });
  });

  group('a map file that cannot be read is not an empty one (step 1.5)', () {
    /// This device's file as another session left it: a claim to have
    /// renamed a note another device made — which nothing but this file
    /// records — and a name.
    Future<IdentityRow> earlierSession() async {
      final adopted = IdentityRow(
        ulid: newUlid(),
        path: 'renamed-here.md',
        mergePolicy: MergePolicy.fugueText,
        recordedAt: OperationId(peerA, HybridLogicalClock(l: 1000, c: 0)),
        seedClaim: OperationId(peerB, HybridLogicalClock(l: 500, c: 0)),
      );
      await map.write(
        [adopted],
        self: PeerName(
          peer: peerA,
          name: 'jdoe-desktop',
          platform: 'linux',
          setAt: HybridLogicalClock(l: 1000, c: 0),
        ),
      );
      return adopted;
    }

    /// Makes the file unreadable — locked, or half-arrived — keeping what
    /// was in it to put back.
    List<int> breakFile() {
      final file = File(map.filePath);
      final bytes = file.readAsBytesSync();
      file.writeAsStringSync('not a database right now');
      return bytes;
    }

    test('an unreadable file at open is never written over', () async {
      await earlierSession();
      breakFile();

      final authored = await AuthoredIdentity.load(map);
      addTearDown(authored.dispose);
      expect(authored.loaded, isFalse);

      // What an open does: publish the name, record a mint.
      authored.publishName('jdoe-desktop', platform: 'linux');
      authored.record(note('new.md'), deleted: false);
      await authored.flush();

      expect(
        File(map.filePath).readAsStringSync(),
        'not a database right now',
        reason: 'held: a write now would discard the file\'s claims',
      );
    });

    test(
      'once it reads, its claims are kept and the owed write goes out',
      () async {
        final adopted = await earlierSession();
        final good = breakFile();

        final authored = await AuthoredIdentity.load(map);
        addTearDown(authored.dispose);
        final mint = note('new.md');
        authored.record(mint, deleted: false);
        await authored.flush();
        expect(authored.loaded, isFalse);

        // The sync service finishes; the file reads again.
        File(map.filePath).writeAsBytesSync(good);
        await authored.flush();

        expect(authored.loaded, isTrue);
        final written = await map.readOurs();
        expect(
          written.map((row) => row.path),
          unorderedEquals(['renamed-here.md', 'new.md']),
          reason: 'the file\'s rename survives, beside this session\'s mint',
        );
        expect(written.firstWhere((row) => row.ulid == adopted.ulid), adopted);
        expect(map.readOurName()?.name, 'jdoe-desktop', reason: 'kept, too');
      },
    );

    test('a change made while held retries the read by itself', () async {
      await earlierSession();
      final good = breakFile();
      final authored = await AuthoredIdentity.load(map);
      addTearDown(authored.dispose);

      File(map.filePath).writeAsBytesSync(good);
      authored.record(note('new.md'), deleted: false);
      // The retry is asynchronous; a flush waits for whatever it scheduled.
      await pumpEventQueue();
      expect(authored.loaded, isTrue);
      await authored.flush();
      expect(
        (await map.readOurs()).map((row) => row.path),
        unorderedEquals(['renamed-here.md', 'new.md']),
      );
    });

    test('this session\'s claim and name win over the file\'s', () async {
      final adopted = await earlierSession();
      final good = breakFile();
      final authored = await AuthoredIdentity.load(map);
      addTearDown(authored.dispose);

      // Renamed again this session — newer than the file's claim.
      authored.record(
        CatalogRow(
          ulid: adopted.ulid,
          path: 'renamed-again.md',
          mergePolicy: MergePolicy.fugueText,
          state: NoteState.live,
          seedClaim: adopted.seedClaim,
        ),
        deleted: false,
      );
      authored.publishName('Work laptop', platform: 'linux');
      File(map.filePath).writeAsBytesSync(good);
      await authored.flush();

      expect((await map.readOurs()).single.path, 'renamed-again.md');
      expect(map.readOurName()?.name, 'Work laptop');
    });

    test('a file that vanishes while held is still not written', () async {
      // A sync service replacing the file may delete it first. A write in
      // that gap would land over the claims it is bringing back.
      final adopted = await earlierSession();
      final good = breakFile();
      final authored = await AuthoredIdentity.load(map);
      addTearDown(authored.dispose);

      File(map.filePath).deleteSync();
      authored.record(note('new.md'), deleted: false);
      await authored.flush();
      expect(authored.loaded, isFalse);
      expect(File(map.filePath).existsSync(), isFalse);

      File(map.filePath).writeAsBytesSync(good);
      await authored.flush();
      expect(
        (await map.readOurs()).map((row) => row.ulid),
        contains(adopted.ulid),
      );
    });

    test('a read that lands after dispose sends nothing', () async {
      await earlierSession();
      final good = breakFile();
      final written = <List<IdentityRow>>[];
      final authored = await AuthoredIdentity.load(
        map,
        writer: immediate(written),
      );

      File(map.filePath).writeAsBytesSync(good);
      authored.record(note('new.md'), deleted: false);
      authored.dispose();
      await pumpEventQueue();
      await authored.flush();

      expect(written, isEmpty, reason: 'a torn-down session writes nothing');
    });

    test('a repair while held reads the file once, not once a row', () async {
      await earlierSession();
      final good = breakFile();
      final counting = _CountingMap(root.path, peerA);
      final authored = await AuthoredIdentity.load(counting);
      addTearDown(authored.dispose);
      counting.loads = 0;

      // The file comes back just before the open repairs from its catalog.
      File(map.filePath).writeAsBytesSync(good);
      final repaired = authored.repairFrom([
        for (var i = 0; i < 50; i++) note('mint-$i.md'),
      ]);
      await pumpEventQueue();

      expect(repaired, 50);
      expect(authored.loaded, isTrue);
      expect(counting.loads, 1, reason: 'one read shared by every row');
    });

    test('a missing file is an empty map, written as normal', () async {
      final authored = await AuthoredIdentity.load(map);
      addTearDown(authored.dispose);
      expect(authored.loaded, isTrue);
      authored.record(note('a.md'), deleted: false);
      await authored.flush();
      expect(await map.readOurs(), hasLength(1));
    });
  });
}

/// An [IdentityMap] that counts its strict reads.
class _CountingMap extends IdentityMap {
  _CountingMap(String engramRoot, PeerId peerId)
    : super(engramRoot: engramRoot, peerId: peerId);

  int loads = 0;

  @override
  Future<({List<IdentityRow> rows, PeerName? name, bool found})> loadOurs() {
    loads++;
    return super.loadOurs();
  }
}
