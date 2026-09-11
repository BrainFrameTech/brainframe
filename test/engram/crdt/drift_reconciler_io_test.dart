import 'dart:io';
import 'dart:typed_data';

import 'package:brainframe/engram/crdt/app_data_resolver_io.dart';
import 'package:brainframe/engram/crdt/catalog.dart';
import 'package:brainframe/engram/crdt/crdt_note_writer_io.dart';
import 'package:brainframe/engram/crdt/drift_reconciler_io.dart';
import 'package:brainframe/engram/crdt/materializer_io.dart';
import 'package:brainframe/engram/crdt/metadata_db_io.dart';
import 'package:brainframe/engram/crdt/note_document_io.dart';
import 'package:brainframe/engram/crdt/note_document_lock.dart';
import 'package:brainframe/engram/engram_store.dart';
import 'package:brainframe/engram/fs/engram_location.dart';
import 'package:brainframe/engram/fs/fs_store_io.dart';
import 'package:brainframe/engram/id.dart';
import 'package:crdt_lf/crdt_lf.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hlc_dart/hlc_dart.dart';

import '../../crdt/support/peer_ids.dart';

/// The scan: Decision 6 end to end, over real files and a real op-log.
void main() {
  late Directory root;
  late AppDataRootResolver resolveRoot;
  late FileSystemEngramStore engram;

  setUp(() {
    root = Directory.systemTemp.createTempSync('brainframe_drift_scan');
    resolveRoot = appDataRootResolver(overridePath: root.path);
    engram = FileSystemEngramStore(EngramLocation('${root.path}/engram'));
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// One "device": its own database, peer identity, writer, and reconciler,
  /// all over the shared [engram] directory.
  Future<_Device> device({EngramStore? over}) async {
    final store = await MetadataDatabase.open(
      newUlid(),
      resolveRoot: resolveRoot,
    );
    final lock = NoteDocumentLock();
    final files = over ?? engram;
    final d = _Device(
      store,
      CrdtNoteWriter(database: store, engram: files, lock: lock),
      DriftReconciler(database: store, engram: files, lock: lock),
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
    test('a path the catalog does not know', () async {
      // A creation — step 11's question, and this scan must not mint.
      final d = await device();
      await engram.writeString('new.md', 'nobody minted me\n');

      expect(await d.reconciler.reconcile('new.md'), isFalse);
      expect((await d.reconciler.scan()).isClean, isTrue);
      expect(d.store.catalog.byPath('new.md'), isNull);
    });

    test('a file that is gone', () async {
      // Absence is not deletion: neither tombstoned nor reported.
      final d = await device();
      await d.writer.write('a.md', 'one\n');
      await engram.delete('a.md');

      expect(await d.reconciler.reconcile('a.md'), isFalse);
      final report = await d.reconciler.scan();
      expect(report.isClean, isTrue);
      expect(d.store.catalog.byPath('a.md')!.state, NoteState.live);
    });

    test('a blob', () async {
      // Step 14's policy: nothing to diff, and a file that must not be
      // character-merged.
      final d = await device();
      final ulid = newUlid();
      d.store.catalog.upsert(
        CatalogRow(
          ulid: ulid,
          path: 'pic.png',
          mergePolicy: MergePolicy.blobLww,
          state: NoteState.live,
          seedClaim: OperationId(d.store.peerId, HybridLogicalClock.now()),
        ),
      );
      await engram.writeString('pic.png', 'not really a png');

      expect(await d.reconciler.reconcile('pic.png'), isFalse);
      expect((await d.reconciler.scan()).isClean, isTrue);
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
}

class _Device {
  _Device(this.store, this.writer, this.reconciler);

  final MetadataDatabase store;
  final CrdtNoteWriter writer;
  final DriftReconciler reconciler;

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
    await reconciler.close();
    store.close();
  }
}
