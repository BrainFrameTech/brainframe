import 'dart:io';
import 'dart:typed_data';

import 'package:brainframe/engram/crdt/app_data_resolver_io.dart';
import 'package:brainframe/engram/crdt/catalog.dart';
import 'package:brainframe/engram/crdt/crdt_note_writer_io.dart';
import 'package:brainframe/engram/crdt/drift_reconciler_io.dart';
import 'package:brainframe/engram/crdt/identity_authorship_io.dart';
import 'package:brainframe/engram/crdt/identity_map.dart';
import 'package:brainframe/engram/crdt/identity_map_io.dart';
import 'package:brainframe/engram/crdt/materializer_io.dart';
import 'package:brainframe/engram/crdt/metadata_db_io.dart';
import 'package:brainframe/engram/crdt/note_document_io.dart';
import 'package:brainframe/engram/crdt/note_document_lock.dart';
import 'package:brainframe/engram/fs/engram_location.dart';
import 'package:brainframe/engram/fs/fs_store_io.dart';
import 'package:brainframe/engram/id.dart';
import 'package:crdt_lf/crdt_lf.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hlc_dart/hlc_dart.dart';

import '../../crdt/support/peer_ids.dart';

/// The scan: Decisions 6 and 7 end to end, over real files, a real op-log,
/// and a real identity map.
void main() {
  late Directory root;
  late AppDataRootResolver resolveRoot;
  late String engramRoot;
  late FileSystemEngramStore engram;

  setUp(() {
    root = Directory.systemTemp.createTempSync('brainframe_drift_scan');
    resolveRoot = appDataRootResolver(overridePath: root.path);
    engramRoot = '${root.path}/engram';
    Directory(engramRoot).createSync();
    engram = FileSystemEngramStore(EngramLocation(engramRoot));
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// One "device": its own database, peer identity, identity-map file,
  /// writer, and reconciler, all over the shared [engram] directory.
  ///
  /// The map is written only on [_Device.publish], never by a timer: what the
  /// other device can see is then something each test states.
  Future<_Device> device({String? engramId}) async {
    final store = await MetadataDatabase.open(
      engramId ?? newUlid(),
      resolveRoot: resolveRoot,
    );
    final map = IdentityMap(engramRoot: engramRoot, peerId: store.peerId);
    final identity = await AuthoredIdentity.load(
      map,
      writer: DebouncedIdentityMapWriter(
        map.write,
        idleDebounce: const Duration(days: 1),
        maxWait: const Duration(days: 1),
      ),
    );
    final lock = NoteDocumentLock();
    final d = _Device(
      store,
      identity,
      CrdtNoteWriter(
        database: store,
        engram: engram,
        lock: lock,
        identity: identity,
      ),
      DriftReconciler(
        database: store,
        engram: engram,
        lock: lock,
        identity: identity,
      ),
    );
    addTearDown(d.close);
    return d;
  }

  /// The op-log length for [path] on [d].
  int changesOf(_Device d, String path) => d.store.crdt
      .changeStorageForDocument(d.store.catalog.byPath(path)!.ulid)
      .getChanges()
      .length;

  group('one note', () {
    test('an unchanged file is not reconciled', () async {
      final d = await device();
      await d.writer.write('a.md', 'one\n');

      expect(await d.reconciler.reconcile('a.md'), isFalse);
      expect((await d.reconciler.scan()).isClean, isTrue);
    });

    test('an external edit becomes history and stays on disk', () async {
      final d = await device();
      await d.writer.write('a.md', 'one\ntwo\n');
      final before = changesOf(d, 'a.md');

      await engram.writeString('a.md', 'one\nTWO\nthree\n');
      expect(await d.reconciler.reconcile('a.md'), isTrue);

      final note = NoteDocument.open(
        store: d.store,
        ulid: d.store.catalog.byPath('a.md')!.ulid,
      );
      addTearDown(note.dispose);
      expect(note.value, 'one\nTWO\nthree\n', reason: 'the edit is history');
      expect(changesOf(d, 'a.md'), greaterThan(before));
      expect(await engram.readString('a.md'), 'one\nTWO\nthree\n');
      expect(
        await noteFileHasDrifted(engram, d.store.catalog.byPath('a.md')!),
        isFalse,
        reason: 'the new hash is committed',
      );
    });

    test('a reconciled note is not reconciled again', () async {
      final d = await device();
      await d.writer.write('a.md', 'one\n');
      await engram.writeString('a.md', 'one\ntwo\n');

      expect(await d.reconciler.reconcile('a.md'), isTrue);
      expect(await d.reconciler.reconcile('a.md'), isFalse);
    });

    test('the synthesized operations carry this device\'s peer', () async {
      // Attribution is honest by construction: we do not know who made the
      // external edit, so it is ours.
      final d = await device();
      await d.writer.write('a.md', 'one\n');
      await engram.writeString('a.md', 'one\ntwo\n');
      await d.reconciler.reconcile('a.md');

      final ulid = d.store.catalog.byPath('a.md')!.ulid;
      final authors = d.store.crdt
          .changeStorageForDocument(ulid)
          .getChanges()
          .map((change) => change.author)
          .toSet();
      expect(authors, {d.store.peerId});
    });

    test('a later save applies on top of the reconciled history', () async {
      final d = await device();
      await d.writer.write('a.md', 'one\n');
      await engram.writeString('a.md', 'one\ntwo\n');
      await d.reconciler.reconcile('a.md');

      await d.writer.write('a.md', 'one\ntwo\nthree\n');

      expect(await engram.readString('a.md'), 'one\ntwo\nthree\n');
      expect(await d.reconciler.reconcile('a.md'), isFalse);
    });
  });

  group('a line-ending change', () {
    test(
      'produces no operations, rewrites LF, and reports no drift after',
      () async {
        // The assertion the plan singles out: a CRLF file reconciles to zero
        // operations and is *still* rewritten with a refreshed hash, so the
        // next scan is quiet. A gate on "did this produce operations?" fails
        // the second scan, not the first.
        final d = await device();
        await d.writer.write('a.md', 'one\ntwo\nthree\n');
        final before = changesOf(d, 'a.md');

        await engram.writeString('a.md', 'one\r\ntwo\r\nthree\r\n');
        expect(await d.reconciler.reconcile('a.md'), isTrue);

        expect(changesOf(d, 'a.md'), before, reason: 'no operations');
        expect(await engram.readString('a.md'), 'one\ntwo\nthree\n');
        expect(
          (await d.reconciler.scan()).isClean,
          isTrue,
          reason: 'the one a single scan cannot see',
        );
      },
    );
  });

  group('crash ordering', () {
    test('a file written before the row was committed self-heals', () async {
      // Decision 5's crash window: the materializer wrote the file, the
      // process died before the hash was recorded. The next scan sees drift
      // on our own output, diffs it against the CRDT, finds nothing, and
      // re-records the hash. No content lost, none duplicated.
      final d = await device();
      await d.writer.write('a.md', 'first\n');
      final ulid = d.store.catalog.byPath('a.md')!.ulid;
      final stale = d.store.catalog.byUlid(ulid)!;

      final note = NoteDocument.open(store: d.store, ulid: ulid);
      note.insert(note.value.length, 'second\n');
      await engram.writeString('a.md', note.value);
      note.dispose();
      d.store.catalog.upsert(stale); // the commit that never happened
      final before = changesOf(d, 'a.md');

      final report = await d.reconciler.scan();

      expect(report.reconciled, ['a.md']);
      expect(changesOf(d, 'a.md'), before, reason: 'a redundant diff');
      expect(await engram.readString('a.md'), 'first\nsecond\n');
      expect((await d.reconciler.scan()).isClean, isTrue);
    });
  });

  group('what the scan leaves alone', () {
    test('a file that is gone, by reconcile(path)', () async {
      // One path cannot tell a move from a deletion; that needs the folder.
      final d = await device();
      await d.writer.write('a.md', 'one\n');
      await engram.delete('a.md');

      expect(await d.reconciler.reconcile('a.md'), isFalse);
      expect(d.store.catalog.byPath('a.md')!.state, NoteState.live);
    });

    test('a blob is not diffed, but its hash is kept current', () async {
      // Step 14's policy: nothing to diff, and a file that must not be
      // character-merged. What a blob does need is a hash that describes the
      // file as it is now, or a moved blob could never be found again.
      final d = await device();
      await engram.writeString('pic.png', 'not really a png');
      await d.reconciler.scan();
      final before = d.store.catalog.byPath('pic.png')!;
      expect(before.mergePolicy, MergePolicy.blobLww);
      expect(changesOf(d, 'pic.png'), 0, reason: 'no seed for a blob');

      await engram.writeString('pic.png', 'still not a png, but longer');
      expect(await d.reconciler.reconcile('pic.png'), isFalse);

      final after = d.store.catalog.byPath('pic.png')!;
      expect(after.materializedHash, isNot(before.materializedHash));
      expect(changesOf(d, 'pic.png'), 0);
      expect(await engram.readString('pic.png'), 'still not a png, but longer');
    });

    test('a history-pending note', () async {
      // Adopted from a map, no log yet: nothing to diff into. The file stays
      // as the user left it and is neither rewritten nor reported.
      final d = await device();
      d.store.catalog.upsert(
        CatalogRow(
          ulid: newUlid(),
          path: 'adopted.md',
          mergePolicy: MergePolicy.fugueText,
          state: NoteState.historyPending,
        ),
      );
      await engram.writeString('adopted.md', 'edited elsewhere\r\n');

      expect(await d.reconciler.reconcile('adopted.md'), isFalse);
      expect((await d.reconciler.scan()).isClean, isTrue);
      expect(await engram.readString('adopted.md'), 'edited elsewhere\r\n');
      expect(
        d.identity.rows,
        isEmpty,
        reason: 'a row we merely learned is never ours to write',
      );
    });

    test(
      'a live row whose seed belongs to another peer and has no log',
      () async {
        // The same condition as history-pending, reached through open()
        // rather than the state column: skipped, not failed.
        final d = await device();
        d.store.catalog.upsert(
          CatalogRow(
            ulid: newUlid(),
            path: 'theirs.md',
            mergePolicy: MergePolicy.fugueText,
            state: NoteState.live,
            seedClaim: OperationId(peerB, HybridLogicalClock.now()),
          ),
        );
        await engram.writeString('theirs.md', 'content\n');

        expect(await d.reconciler.reconcile('theirs.md'), isFalse);
        expect((await d.reconciler.scan()).isClean, isTrue);
      },
    );
  });

  group('the scan', () {
    test(
      'visits every live note and reports the drifted ones in order',
      () async {
        final d = await device();
        await d.writer.write('b.md', 'b\n');
        await d.writer.write('a.md', 'a\n');
        await d.writer.write('c.md', 'c\n');
        await engram.writeString('c.md', 'c changed\n');
        await engram.writeString('a.md', 'a changed\n');

        final report = await d.reconciler.scan();

        expect(report.reconciled, ['a.md', 'c.md']);
        expect(report.failed, isEmpty);
        expect(await engram.readString('b.md'), 'b\n');
      },
    );

    test('one failure does not stop the rest', () async {
      final d = await device();
      await d.writer.write('a.md', 'a\n');
      await d.writer.write('b.md', 'b\n');
      await engram.writeString('a.md', 'a changed\n');
      await engram.writeString('b.md', 'b changed\n');
      // Invalid UTF-8 cannot be a text note; decoding it is the failure.
      await engram.writeBytes('a.md', Uint8List.fromList([0xff, 0xfe, 0x0a]));

      final report = await d.reconciler.scan();

      expect(report.reconciled, ['b.md']);
      expect(report.failed.keys, ['a.md']);
      expect(report.failed['a.md'], isA<FormatException>());
      expect(report.isClean, isFalse);
    });

    test('a failed note is untouched and still drifted', () async {
      final d = await device();
      await d.writer.write('a.md', 'a\n');
      final before = changesOf(d, 'a.md');
      final bad = Uint8List.fromList([0xff, 0xfe, 0x0a]);
      await engram.writeBytes('a.md', bad);

      await d.reconciler.scan();

      expect(await engram.readBytes('a.md'), bad);
      expect(changesOf(d, 'a.md'), before);
      expect(
        await noteFileHasDrifted(engram, d.store.catalog.byPath('a.md')!),
        isTrue,
      );
    });

    test('reconcile(path) surfaces the failure instead', () async {
      final d = await device();
      await d.writer.write('a.md', 'a\n');
      await engram.writeBytes('a.md', Uint8List.fromList([0xff, 0xfe, 0x0a]));

      await expectLater(d.reconciler.reconcile('a.md'), throwsFormatException);
    });

    test('two overlapping scans are one scan', () async {
      final d = await device();
      await d.writer.write('a.md', 'a\n');
      await engram.writeString('a.md', 'a changed\n');

      final first = d.reconciler.scan();
      final second = d.reconciler.scan();

      expect(identical(first, second), isTrue);
      expect((await first).reconciled, ['a.md']);
      // And once it is done, the next one is fresh — and quiet.
      expect((await d.reconciler.scan()).isClean, isTrue);
    });

    test('every reconciled path is announced on the stream', () async {
      final d = await device();
      await d.writer.write('a.md', 'a\n');
      await d.writer.write('b.md', 'b\n');
      final seen = <String>[];
      final subscription = d.reconciler.reconciled.listen(seen.add);
      addTearDown(subscription.cancel);

      await engram.writeString('a.md', 'a changed\n');
      await d.reconciler.scan();
      await engram.writeString('b.md', 'b changed\n');
      await d.reconciler.reconcile('b.md');
      await d.reconciler.reconcile('b.md'); // no drift: no event
      await Future<void>.delayed(Duration.zero);

      expect(seen, ['a.md', 'b.md']);
    });
  });

  group('the lock', () {
    test('a reconciliation and a save of one note are serialized', () async {
      // Without the lock both open the note, both diff against the same base,
      // and the second applies an insertion the first already made: the note
      // ends up with the text twice, and Fugue reports a clean merge.
      final d = await device();
      await d.writer.write('a.md', 'one\n');
      await engram.writeString('a.md', 'one\ntwo\n');

      final reconcile = d.reconciler.reconcile('a.md');
      final save = d.writer.write('a.md', 'ONE\ntwo\n');
      await Future.wait([reconcile, save]);

      expect(await engram.readString('a.md'), 'ONE\ntwo\n');
    });

    test('two reconciliations of one note are serialized', () async {
      final d = await device();
      await d.writer.write('a.md', 'one\n');
      await engram.writeString('a.md', 'one\ntwo\n');

      final results = await Future.wait([
        d.reconciler.reconcile('a.md'),
        d.reconciler.reconcile('a.md'),
      ]);

      expect(results, [true, false], reason: 'the second finds no drift');
      expect(await engram.readString('a.md'), 'one\ntwo\n');
    });
  });

  group('two devices over one folder', () {
    test('converge, edited alternately with a scan between', () async {
      // The direct test of "locally arriving CRDTs work": two metadata.db
      // files, two peerIDs, one engram directory, and the file as the only
      // channel between them. Each device's edit reaches the other as drift.
      final a = await device();
      final b = await device();

      // A creates the note. B has never seen the path; its first save mints
      // its own row — a creation, from B's side — over the same file.
      await a.writer.write('shared.md', 'from A\n');
      await b.writer.write('shared.md', 'from A\nfrom B\n');

      // A scans: B's line is drift, and becomes A's history.
      expect((await a.reconciler.scan()).reconciled, ['shared.md']);
      expect(a.valueOf('shared.md'), 'from A\nfrom B\n');

      // A edits; B scans.
      await a.writer.write('shared.md', 'from A\nfrom B\nA again\n');
      expect((await b.reconciler.scan()).reconciled, ['shared.md']);
      expect(b.valueOf('shared.md'), 'from A\nfrom B\nA again\n');

      // B edits in the middle; A scans.
      await b.writer.write(
        'shared.md',
        'from A\nB in the middle\nfrom B\nA again\n',
      );
      expect((await a.reconciler.scan()).reconciled, ['shared.md']);

      final file = await engram.readString('shared.md');
      expect(file, 'from A\nB in the middle\nfrom B\nA again\n');
      expect(a.valueOf('shared.md'), file);
      expect(b.valueOf('shared.md'), file);
      expect((await a.reconciler.scan()).isClean, isTrue);
      expect((await b.reconciler.scan()).isClean, isTrue);
    });

    test(
      'each device keeps its own hash, and neither trusts the other\'s',
      () async {
        // Decision 5: the hash is device-local. After A writes, only A's row
        // matches the file; B still sees drift and must reconcile for itself.
        final a = await device();
        final b = await device();
        await a.writer.write('shared.md', 'v1\n');
        await b.writer.write('shared.md', 'v1\n');
        expect((await a.reconciler.scan()).isClean, isTrue);
        expect((await b.reconciler.scan()).isClean, isTrue);

        await a.writer.write('shared.md', 'v2, longer\n');

        expect((await a.reconciler.scan()).isClean, isTrue);
        expect((await b.reconciler.scan()).reconciled, ['shared.md']);
        expect(b.valueOf('shared.md'), 'v2, longer\n');
      },
    );
  });

  group('a concurrent remote insertion survives', () {
    test('the reconciliation is minimal, never replace-all', () async {
      // The property only a second peer can see, at the scan rather than the
      // save: a replace-all tombstones every element a peer might be editing.
      final d = await device();
      await d.writer.write('a.md', 'one\ntwo\n');
      final ulid = d.store.catalog.byPath('a.md')!.ulid;

      // A peer, offline, appends a line to the same document.
      final peer = CRDTDocument(
        peerId: peerB,
        documentId: ulid,
        initialClock: HybridLogicalClock.now(),
      );
      final peerText = CRDTFugueTextHandler(peer, noteHandlerId);
      final seeded = NoteDocument.open(store: d.store, ulid: ulid);
      peer.importChanges(seeded.document.exportChanges());
      seeded.dispose();
      peerText.insert(peerText.value.length, 'three\n');

      // Meanwhile the file is edited outside the app and reconciled here.
      await engram.writeString('a.md', 'one\nTWO!\n');
      expect(await d.reconciler.reconcile('a.md'), isTrue);

      final merged = NoteDocument.open(store: d.store, ulid: ulid);
      addTearDown(merged.dispose);
      merged.document.importChanges(peer.exportChanges());
      expect(merged.value, 'one\nTWO!\nthree\n');
    });
  });

  group('creations (Decision 7)', () {
    test('a file nobody claims is minted, seeded, and announced', () async {
      final d = await device();
      await engram.writeString('new.md', 'nobody minted me\r\n');

      final report = await d.reconciler.scan();

      expect(report.created, ['new.md']);
      final row = d.store.catalog.byPath('new.md')!;
      expect(row.state, NoteState.live);
      expect(row.seededBy, d.store.peerId, reason: 'we took the claim');
      expect(d.valueOf('new.md'), 'nobody minted me\n', reason: 'seeded LF');
      expect(
        await engram.readString('new.md'),
        'nobody minted me\r\n',
        reason: 'found, not rewritten: the first save normalizes',
      );
      expect((await d.reconciler.scan()).isClean, isTrue);

      await d.publish();
      final announced = (await d.mapRowFor('new.md'))!;
      expect(announced.ulid, row.ulid);
      expect(announced.seededBy, d.store.peerId);
      expect(announced.deleted, isFalse);
    });

    test('reconcile(path) brings in an unknown file the same way', () async {
      // The before-open trigger: the editor reads a file that already has a
      // row, so the writer never has to mint from the buffer.
      final d = await device();
      await engram.writeString('new.md', 'hello\n');

      expect(await d.reconciler.reconcile('new.md'), isTrue);

      expect(d.store.catalog.byPath('new.md')!.state, NoteState.live);
      expect(await d.reconciler.reconcile('new.md'), isFalse);
      await d.publish();
      expect(await d.mapRowFor('new.md'), isNotNull);
    });

    test('a first save on a minted-by-scan note applies on top', () async {
      final d = await device();
      await engram.writeString('new.md', 'one\r\ntwo\r\n');
      await d.reconciler.scan();

      await d.writer.write('new.md', 'one\ntwo\nthree\n');

      expect(await engram.readString('new.md'), 'one\ntwo\nthree\n');
      expect(changesOf(d, 'new.md'), 2, reason: 'the seed and one edit');
    });

    test('a blob is minted with an empty sequence', () async {
      final d = await device();
      await engram.writeBytes('pic.png', Uint8List.fromList([0x89, 0x50, 0]));

      final report = await d.reconciler.scan();

      expect(report.created, ['pic.png']);
      final row = d.store.catalog.byPath('pic.png')!;
      expect(row.mergePolicy, MergePolicy.blobLww);
      expect(row.materializedHash, isNotNull);
      expect(row.sketch, isNull);
      expect(changesOf(d, 'pic.png'), 0);
      expect(await engram.readBytes('pic.png'), [0x89, 0x50, 0]);
    });

    test('a file that cannot be brought in fails alone', () async {
      // Invalid UTF-8 at a text path cannot be seeded; the others still are.
      final d = await device();
      await engram.writeBytes('bad.md', Uint8List.fromList([0xff, 0xfe]));
      await engram.writeString('good.md', 'fine\n');

      final report = await d.reconciler.scan();

      expect(report.created, ['good.md']);
      expect(report.failed.keys, ['bad.md']);
      expect(report.failed['bad.md'], isA<FormatException>());
      expect(d.store.catalog.byPath('bad.md'), isNull);
    });

    test('the map row carries nothing device-local', () async {
      // The content hash never leaves the device: Decision 5 spells out what
      // sharing it destroys.
      final d = await device();
      await engram.writeString('new.md', 'content\n');
      await d.reconciler.scan();
      await d.publish();

      final bytes = await File(d.identity.map.filePath).readAsBytes();
      final text = String.fromCharCodes(bytes);
      for (final forbidden in ['materialized_hash', 'mtime', 'sketch']) {
        expect(text, isNot(contains(forbidden)));
      }
      expect(text, isNot(contains(d.store.catalog.byPath('new.md')!.materializedHash!)));
    });
  });

  group('hidden paths', () {
    test('dot-directories and dotfiles are not notes', () async {
      // Without this the scan mints a note for every object in a checkout's
      // own dot-directory, and the map carries each to every other device.
      final d = await device();
      await engram.writeString('visible.md', 'a note\n');
      await engram.writeString('.obsidian/workspace.json', '{}');
      await engram.writeString('notes/.secret.md', 'hidden\n');
      await engram.writeString('.DS_Store', 'junk');

      final report = await d.reconciler.scan();

      expect(report.created, ['visible.md']);
      expect(d.store.catalog.byPath('.obsidian/workspace.json'), isNull);
      expect(d.store.catalog.byPath('notes/.secret.md'), isNull);
      expect(d.store.catalog.byPath('.DS_Store'), isNull);
      expect(await d.reconciler.reconcile('.DS_Store'), isFalse);
    });

    test('a file renamed into a dot-directory is a deletion, not a move',
        () async {
      final d = await device();
      await d.writer.write('a.md', 'content that would match exactly\n');
      await engram.move('a.md', '.trash/a.md');

      final report = await d.reconciler.scan();

      expect(report.tombstoned, ['a.md']);
      expect(report.moved, isEmpty);
      expect(d.store.catalog.byPath('.trash/a.md'), isNull);
    });
  });

  group('moves (Decision 7)', () {
    test('a gone path and a new one with the same content is a move',
        () async {
      // Exactly how git detects a rename: keep the id and the history.
      final d = await device();
      await d.writer.write('old.md', 'one\ntwo\n');
      final ulid = d.store.catalog.byPath('old.md')!.ulid;
      final history = changesOf(d, 'old.md');
      await engram.move('old.md', 'folder/new.md');

      final report = await d.reconciler.scan();

      expect(report.moved, {'old.md': 'folder/new.md'});
      expect(report.tombstoned, isEmpty);
      expect(report.created, isEmpty);
      final row = d.store.catalog.byPath('folder/new.md')!;
      expect(row.ulid, ulid);
      expect(row.state, NoteState.live);
      expect(d.store.catalog.byPath('old.md'), isNull);
      expect(changesOf(d, 'folder/new.md'), history, reason: 'no new ops');
      expect((await d.reconciler.scan()).isClean, isTrue);

      await d.publish();
      expect((await d.mapRowFor('folder/new.md'))!.ulid, ulid);
      expect(await d.mapRowFor('old.md'), isNull);
    });

    test('a renamed blob is a move too', () async {
      final d = await device();
      await engram.writeBytes('a.png', Uint8List.fromList([1, 2, 3, 4]));
      await d.reconciler.scan();
      final ulid = d.store.catalog.byPath('a.png')!.ulid;
      await engram.move('a.png', 'b.png');

      final report = await d.reconciler.scan();

      expect(report.moved, {'a.png': 'b.png'});
      expect(d.store.catalog.byPath('b.png')!.ulid, ulid);
    });

    test('a rename with an edit is re-associated, then reconciled', () async {
      final d = await device();
      final text = List.generate(
        30,
        (i) => 'Line $i of a note long enough to sketch reliably.',
      ).join('\n');
      await d.writer.write('old.md', '$text\n');
      final ulid = d.store.catalog.byPath('old.md')!.ulid;
      await engram.move('old.md', 'new.md');
      await engram.writeString('new.md', '$text\nAnd a line added after.\n');

      final report = await d.reconciler.scan();

      expect(report.moved, {'old.md': 'new.md'});
      expect(report.reconciled, ['new.md'], reason: 'the edit is drift');
      expect(report.tombstoned, isEmpty);
      expect(d.store.catalog.byPath('new.md')!.ulid, ulid);
      expect(d.valueOf('new.md'), '$text\nAnd a line added after.\n');
      expect((await d.reconciler.scan()).isClean, isTrue);
    });

    test('below the cutoff is a delete plus a create, and is surfaced',
        () async {
      // The honest price of rejecting a frontmatter id: the history stays
      // with the tombstone, and the report says so with both halves.
      final d = await device();
      await d.writer.write(
        'old.md',
        List.generate(20, (i) => 'original line number $i here').join('\n'),
      );
      final ulid = d.store.catalog.byPath('old.md')!.ulid;
      await engram.delete('old.md');
      await engram.writeString(
        'new.md',
        List.generate(20, (i) => 'completely different text $i').join('\n'),
      );

      final report = await d.reconciler.scan();

      expect(report.moved, isEmpty);
      expect(report.tombstoned, ['old.md']);
      expect(report.created, ['new.md']);
      expect(d.store.catalog.byUlid(ulid)!.state, NoteState.tombstoned);
      expect(d.store.catalog.byPath('new.md')!.ulid, isNot(ulid));
    });

    test('a tie between two candidates matches neither', () async {
      // Re-associating with the wrong one merges two histories; a miss for
      // both is the cheap failure.
      final d = await device();
      await d.writer.write('a.md', 'identical content in two notes\n');
      await d.writer.write('b.md', 'identical content in two notes\n');
      await engram.delete('a.md');
      await engram.delete('b.md');
      await engram.writeString('c.md', 'identical content in two notes\n');

      final report = await d.reconciler.scan();

      // An exact hash match is taken for the first candidate in path order:
      // both are the same content, so either identity is as good, and the
      // other is a deletion. The sketch path, where a wrong guess costs,
      // is the one that refuses ties.
      expect(report.moved.length + report.created.length, 1);
      expect(report.tombstoned.length, report.moved.isEmpty ? 2 : 1);
    });

    test('a history-pending note cannot be matched, and says so', () async {
      // No hash and no sketch: an external rename of an adopted note is a
      // tombstone and a fresh mint. The in-app rename path exists so this
      // is only ever the external case.
      final d = await device();
      d.store.catalog.upsert(
        CatalogRow(
          ulid: newUlid(),
          path: 'adopted.md',
          mergePolicy: MergePolicy.fugueText,
          state: NoteState.historyPending,
          seedClaim: OperationId(peerB, HybridLogicalClock.now()),
        ),
      );
      await engram.writeString('renamed.md', 'the adopted content\n');

      final report = await d.reconciler.scan();

      expect(report.tombstoned, ['adopted.md']);
      expect(report.created, ['renamed.md']);
    });
  });

  group('deletions (Decision 7)', () {
    test('a gone path with no candidate is tombstoned, and the map told',
        () async {
      final d = await device();
      await d.writer.write('a.md', 'one\n');
      final ulid = d.store.catalog.byPath('a.md')!.ulid;
      await engram.delete('a.md');

      final report = await d.reconciler.scan();

      expect(report.tombstoned, ['a.md']);
      expect(d.store.catalog.byPath('a.md'), isNull);
      expect(d.store.catalog.byUlid(ulid)!.state, NoteState.tombstoned);
      await d.publish();
      final row = d.identity.rows[ulid]!;
      expect(row.deleted, isTrue);
      expect(row.path, 'a.md');
    });

    test('a freed path does not resurrect a dead note', () async {
      final d = await device();
      await d.writer.write('a.md', 'the old note\n');
      final dead = d.store.catalog.byPath('a.md')!.ulid;
      await engram.delete('a.md');
      await d.reconciler.scan();
      await engram.writeString('a.md', 'an unrelated new note\n');

      final report = await d.reconciler.scan();

      expect(report.created, ['a.md']);
      final fresh = d.store.catalog.byPath('a.md')!;
      expect(fresh.ulid, isNot(dead));
      expect(changesOf(d, 'a.md'), 1, reason: 'its own seed, no old history');
    });

    test('a history-pending note that is gone is tombstoned', () async {
      final d = await device();
      d.store.catalog.upsert(
        CatalogRow(
          ulid: newUlid(),
          path: 'adopted.md',
          mergePolicy: MergePolicy.fugueText,
          state: NoteState.historyPending,
        ),
      );

      final report = await d.reconciler.scan();

      expect(report.tombstoned, ['adopted.md']);
    });
  });

  group('absence is not deletion', () {
    test('a folder that is not there tombstones nothing', () async {
      // An unmounted drive lists as empty. Taking that at face value would
      // tombstone every note in the engram.
      final d = await device();
      await d.writer.write('a.md', 'one\n');
      await d.writer.write('b.md', 'two\n');
      Directory(engramRoot).deleteSync(recursive: true);

      final report = await d.reconciler.scan();

      expect(report.complete, isFalse);
      expect(report.listingFailure, isA<FileSystemException>());
      expect(report.tombstoned, isEmpty);
      expect(report.created, isEmpty);
      expect(d.store.catalog.byPath('a.md')!.state, NoteState.live);
      expect(d.store.catalog.byPath('b.md')!.state, NoteState.live);
    });

    test('an incomplete scan still reconciles the drift it can see',
        () async {
      // The folder replaced by a file: the store lists nothing, and the
      // notes it cannot stat stay as they were.
      final d = await device();
      await d.writer.write('a.md', 'one\n');
      Directory(engramRoot).deleteSync(recursive: true);

      final report = await d.reconciler.scan();

      expect(report.isClean, isFalse);
      expect(report.complete, isFalse);
      expect(report.failed, isEmpty);
    });

    test('without an identity map there is no listing to trust', () async {
      final store = MetadataDatabase.openInMemory();
      addTearDown(store.close);
      final reconciler = DriftReconciler(
        database: store,
        engram: engram,
        lock: NoteDocumentLock(),
        identity: null,
      );
      addTearDown(reconciler.close);
      await engram.writeString('new.md', 'content\n');

      final report = await reconciler.scan();

      expect(report.complete, isFalse);
      expect(report.created, isEmpty);
      expect(await reconciler.reconcile('new.md'), isFalse);
    });
  });

  group('the identity map (Decision 9)', () {
    test('a cold copy adopts, rather than mints', () async {
      // Identity travels, history does not: the second device finds every
      // note under the first device's ULID and seeds nothing.
      final a = await device();
      await engram.writeString('one.md', 'first\n');
      await engram.writeString('two.md', 'second\n');
      await a.reconciler.scan();
      await a.publish();
      final ulids = {
        for (final path in ['one.md', 'two.md'])
          path: a.store.catalog.byPath(path)!.ulid,
      };

      final b = await device();
      final report = await b.reconciler.scan();

      expect(report.adopted, ['one.md', 'two.md']);
      expect(report.created, isEmpty);
      for (final entry in ulids.entries) {
        final row = b.store.catalog.byPath(entry.key)!;
        expect(row.ulid, entry.value);
        expect(row.state, NoteState.historyPending);
        expect(row.seededBy, a.store.peerId);
        expect(changesOf(b, entry.key), 0, reason: 'never seeded');
      }
      expect(b.identity.rows, isEmpty, reason: 'adopted rows are not ours');
      expect((await b.reconciler.scan()).isClean, isTrue);
    });

    test('an adopted note is edited as a file, and the minter sees drift',
        () async {
      final a = await device();
      await engram.writeString('note.md', 'from A\n');
      await a.reconciler.scan();
      await a.publish();
      final b = await device();
      await b.reconciler.scan();

      await b.writer.write('note.md', 'from A\nfrom B, directly\n');
      expect(changesOf(b, 'note.md'), 0, reason: 'a direct write, no ops');

      expect((await a.reconciler.scan()).reconciled, ['note.md']);
      expect(a.valueOf('note.md'), 'from A\nfrom B, directly\n');
    });

    test('with the map deleted, a cold copy mints fresh ULIDs', () async {
      final a = await device();
      await engram.writeString('one.md', 'first\n');
      await a.reconciler.scan();
      await a.publish();
      final old = a.store.catalog.byPath('one.md')!.ulid;
      Directory(a.identity.map.directoryPath).deleteSync(recursive: true);

      final b = await device();
      final report = await b.reconciler.scan();

      expect(report.created, ['one.md']);
      expect(b.store.catalog.byPath('one.md')!.ulid, isNot(old));
      expect(await engram.readString('one.md'), 'first\n');
    });

    test('a non-minting device\'s rename propagates', () async {
      // The silent failure in Decision 9: B notices the rename, records it
      // in B's file, and C — opening cold — adopts A's ULID at the new path
      // instead of minting a fresh one.
      final a = await device();
      await engram.writeString('trails/cedar.md', 'cedar marsh\n');
      await a.reconciler.scan();
      await a.publish();
      final ulid = a.store.catalog.byPath('trails/cedar.md')!.ulid;

      final b = await device();
      await b.reconciler.scan();
      await engram.move('trails/cedar.md', 'journal/cedar.md');
      // B has no hash for an adopted note, so the rename is reported to it
      // as the app would — which is the case the explicit path exists for.
      await b.reconciler.noteMoved('trails/cedar.md', 'journal/cedar.md');
      await b.publish();
      expect((await b.mapRowFor('journal/cedar.md'))!.ulid, ulid);

      final c = await device();
      final report = await c.reconciler.scan();

      expect(report.adopted, ['journal/cedar.md']);
      expect(c.store.catalog.byPath('journal/cedar.md')!.ulid, ulid);
    });

    test('deleting metadata.db loses history, not content or identity',
        () async {
      final id = newUlid();
      final a = await device(engramId: id);
      await engram.writeString('note.md', 'the content\n');
      await a.reconciler.scan();
      await a.writer.write('note.md', 'the content\nand an edit\n');
      await a.publish();
      final ulid = a.store.catalog.byPath('note.md')!.ulid;
      final peer = a.store.peerId;
      await a.close();
      File('${await engramStorePath(id, resolveRoot: resolveRoot)}/metadata.db')
          .deleteSync();

      // The same device, reopened: a fresh database, the same map file.
      final store = await MetadataDatabase.open(id, resolveRoot: resolveRoot);
      addTearDown(store.close);
      expect(store.peerId, isNot(peer), reason: 'the peer id went with the db');
      final map = IdentityMap(engramRoot: engramRoot, peerId: store.peerId);
      final identity = await AuthoredIdentity.load(map);
      addTearDown(identity.dispose);
      final lock = NoteDocumentLock();
      final reconciler = DriftReconciler(
        database: store,
        engram: engram,
        lock: lock,
        identity: identity,
      );
      addTearDown(reconciler.close);

      final report = await reconciler.scan();

      expect(report.adopted, ['note.md']);
      final row = store.catalog.byPath('note.md')!;
      expect(row.ulid, ulid, reason: 'identity survives');
      expect(row.state, NoteState.historyPending, reason: 'history does not');
      expect(await engram.readString('note.md'), 'the content\nand an edit\n');
    });

    test('our own map with no local row recovers the note as ours', () async {
      // The peer id survived (the map names it) but the catalog row did not:
      // the note is live under our claim with an empty log, and the next
      // reconciliation seeds it again from the file.
      final a = await device();
      await engram.writeString('note.md', 'the content\n');
      await a.reconciler.scan();
      await a.publish();
      final ulid = a.store.catalog.byPath('note.md')!.ulid;
      a.store.database.execute('DELETE FROM bf_catalog');
      a.store.database.execute('DELETE FROM changes');

      final report = await a.reconciler.scan();

      expect(report.adopted, ['note.md']);
      final row = a.store.catalog.byPath('note.md')!;
      expect(row.ulid, ulid);
      expect(row.state, NoteState.live);
      expect(row.materializedHash, isNull, reason: 'never written by this db');

      expect((await a.reconciler.scan()).reconciled, ['note.md']);
      expect(a.valueOf('note.md'), 'the content\n');
    });

    test('two devices that both minted converge on the lowest ULID',
        () async {
      // Both saved the file before either could see the other's map — the
      // writer mints without asking, which is this case exactly. The loser
      // retires its document rather than re-keying it.
      final a = await device();
      final b = await device();
      await a.writer.write('note.md', 'shared text\n');
      await b.writer.write('note.md', 'shared text\n');
      await a.publish();
      await b.publish();
      final ulidA = a.store.catalog.byPath('note.md')!.ulid;
      final ulidB = b.store.catalog.byPath('note.md')!.ulid;
      final (winner, loser) = ulidA.compareTo(ulidB) < 0 ? (a, b) : (b, a);
      final winning = winner.store.catalog.byPath('note.md')!.ulid;
      final losing = loser.store.catalog.byPath('note.md')!.ulid;

      final loserReport = await loser.reconciler.scan();
      final winnerReport = await winner.reconciler.scan();

      expect(loserReport.retired, ['note.md']);
      expect(winnerReport.isClean, isTrue);
      final adopted = loser.store.catalog.byPath('note.md')!;
      expect(adopted.ulid, winning);
      expect(adopted.state, NoteState.historyPending);
      expect(loser.store.catalog.byUlid(losing)!.state, NoteState.tombstoned);
      expect(await engram.readString('note.md'), 'shared text\n');

      await loser.publish();
      expect(loser.identity.rows[losing]!.deleted, isTrue);
      expect((await loser.reconciler.scan()).isClean, isTrue);
      expect((await winner.reconciler.scan()).isClean, isTrue);
    });
  });

  group('in-app file management', () {
    test('a created note is minted and announced', () async {
      final d = await device();
      await engram.writeString('new.md', '# New\n');

      await d.reconciler.noteCreated('new.md');

      expect(d.store.catalog.byPath('new.md')!.state, NoteState.live);
      await d.publish();
      expect(await d.mapRowFor('new.md'), isNotNull);
    });

    test('a moved note keeps its identity and the map records the path',
        () async {
      final d = await device();
      await d.writer.write('a.md', 'content\n');
      final ulid = d.store.catalog.byPath('a.md')!.ulid;
      await engram.move('a.md', 'b/c.md');

      await d.reconciler.noteMoved('a.md', 'b/c.md');

      expect(d.store.catalog.byPath('b/c.md')!.ulid, ulid);
      expect(d.store.catalog.byPath('a.md'), isNull);
      expect((await d.reconciler.scan()).isClean, isTrue);
      await d.publish();
      expect((await d.mapRowFor('b/c.md'))!.ulid, ulid);
    });

    test('a moved history-pending note keeps the adopted identity', () async {
      // The reason the app reports rather than letting the scan infer.
      final a = await device();
      await engram.writeString('a.md', 'content\n');
      await a.reconciler.scan();
      await a.publish();
      final ulid = a.store.catalog.byPath('a.md')!.ulid;
      final b = await device();
      await b.reconciler.scan();
      await engram.move('a.md', 'moved.md');

      await b.reconciler.noteMoved('a.md', 'moved.md');

      final row = b.store.catalog.byPath('moved.md')!;
      expect(row.ulid, ulid);
      expect(row.state, NoteState.historyPending);
      expect((await b.reconciler.scan()).isClean, isTrue);
    });

    test('a move into a hidden path is a deletion', () async {
      final d = await device();
      await d.writer.write('a.md', 'content\n');
      final ulid = d.store.catalog.byPath('a.md')!.ulid;
      await engram.move('a.md', '.trash/a.md');

      await d.reconciler.noteMoved('a.md', '.trash/a.md');

      expect(d.store.catalog.byUlid(ulid)!.state, NoteState.tombstoned);
    });

    test('a move of an unknown path is nothing to record', () async {
      final d = await device();
      await engram.writeString('b.md', 'content\n');

      await d.reconciler.noteMoved('a.md', 'b.md');

      expect(d.store.catalog.byPath('b.md'), isNull);
      expect(d.identity.rows, isEmpty);
    });

    test('a deleted note is tombstoned and the map told', () async {
      final d = await device();
      await d.writer.write('a.md', 'content\n');
      final ulid = d.store.catalog.byPath('a.md')!.ulid;
      await engram.delete('a.md');

      await d.reconciler.noteDeleted('a.md');
      await d.reconciler.noteDeleted('never-existed.md');

      expect(d.store.catalog.byUlid(ulid)!.state, NoteState.tombstoned);
      expect((await d.reconciler.scan()).isClean, isTrue);
      await d.publish();
      expect(d.identity.rows[ulid]!.deleted, isTrue);
    });
  });

  group('the sketch is rebuilt by a scan', () {
    test('a row that predates the sketch gets one without drifting', () async {
      final d = await device();
      await d.writer.write('a.md', 'some words to sketch here\n');
      final row = d.store.catalog.byPath('a.md')!;
      expect(row.sketch, isNotNull);
      d.store.catalog.upsert(
        CatalogRow(
          ulid: row.ulid,
          path: row.path,
          mergePolicy: row.mergePolicy,
          state: row.state,
          materializedHash: row.materializedHash,
          size: row.size,
          mtimeUtc: row.mtimeUtc,
          seedClaim: row.seedClaim,
        ),
      );

      final report = await d.reconciler.scan();

      expect(report.isClean, isTrue, reason: 'not drift, just bookkeeping');
      expect(d.store.catalog.byPath('a.md')!.sketch, isNotNull);
    });
  });
}

class _Device {
  _Device(this.store, this.identity, this.writer, this.reconciler);

  final MetadataDatabase store;
  final AuthoredIdentity identity;
  final CrdtNoteWriter writer;
  final DriftReconciler reconciler;

  /// Writes this device's identity-map file, so the other device can read it.
  Future<void> publish() => identity.flush();

  /// The row this device's map holds for [path], if any.
  Future<IdentityRow?> mapRowFor(String path) async {
    for (final row in await identity.map.readOurs()) {
      if (row.path == path) return row;
    }
    return null;
  }

  /// The note's CRDT value on this device, rebuilt from its op-log.
  String valueOf(String path) {
    final note = NoteDocument.open(
      store: store,
      ulid: store.catalog.byPath(path)!.ulid,
    );
    try {
      return note.value;
    } finally {
      note.dispose();
    }
  }

  Future<void> close() async {
    identity.dispose();
    await reconciler.close();
    store.close();
  }
}
