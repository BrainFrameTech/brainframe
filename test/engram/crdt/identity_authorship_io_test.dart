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
}
