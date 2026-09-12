import 'dart:io';

import 'package:brainframe/engram/crdt/app_data_resolver_io.dart';
import 'package:brainframe/engram/crdt/catalog.dart';
import 'package:brainframe/engram/crdt/crdt_note_writer_io.dart';
import 'package:brainframe/engram/crdt/identity_authorship_io.dart';
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

/// The editor's save, arriving as operations instead of a file write.
void main() {
  late Directory root;
  late AppDataRootResolver resolveRoot;
  late String engramId;
  late FileSystemEngramStore engram;

  setUp(() {
    root = Directory.systemTemp.createTempSync('brainframe_crdt_writer');
    resolveRoot = appDataRootResolver(overridePath: root.path);
    engramId = newUlid();
    engram = FileSystemEngramStore(EngramLocation('${root.path}/engram'));
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<MetadataDatabase> openStore() =>
      MetadataDatabase.open(engramId, resolveRoot: resolveRoot);

  Future<CrdtNoteWriter> writerFor(MetadataDatabase store) async =>
      CrdtNoteWriter(database: store, engram: engram, lock: NoteDocumentLock());

  group('a path the catalog has never seen', () {
    test('is minted, seeded with the buffer, and written', () async {
      final store = await openStore();
      addTearDown(store.close);
      final writer = await writerFor(store);

      await writer.write('inbox/today.md', '# Today\n');

      expect(await engram.readString('inbox/today.md'), '# Today\n');
      final row = store.catalog.byPath('inbox/today.md');
      expect(row, isNotNull);
      expect(row!.materializedHash, isNotNull);
    });

    test('the seed is the buffer, not the file it replaced', () async {
      // Seeding with anything else would make the user's first keystroke an
      // edit against a document they never saw.
      final store = await openStore();
      addTearDown(store.close);
      await engram.writeString('inbox/today.md', 'stale content\n');
      final writer = await writerFor(store);

      await writer.write('inbox/today.md', 'what the user typed\n');

      final note = NoteDocument.open(
        store: store,
        ulid: store.catalog.byPath('inbox/today.md')!.ulid,
      );
      addTearDown(note.dispose);
      expect(note.value, 'what the user typed\n');
    });

    test('the note is left with no drift', () async {
      final store = await openStore();
      addTearDown(store.close);
      final writer = await writerFor(store);

      await writer.write('inbox/today.md', 'content\n');

      expect(
        await noteFileHasDrifted(
          engram,
          store.catalog.byPath('inbox/today.md')!,
        ),
        isFalse,
      );
    });
  });

  group('the identity map', () {
    test('a mint is announced to other devices', () async {
      // A note minted here and recorded nowhere else is a note a second
      // device mints again under another ULID.
      final store = await openStore();
      addTearDown(store.close);
      final map = IdentityMap(
        engramRoot: '${root.path}/engram',
        peerId: store.peerId,
      );
      final identity = await AuthoredIdentity.load(map);
      addTearDown(identity.dispose);
      final writer = CrdtNoteWriter(
        database: store,
        engram: engram,
        lock: NoteDocumentLock(),
        identity: identity,
      );

      await writer.write('inbox/today.md', '# Today\n');
      await identity.flush();

      final row = (await map.readOurs()).single;
      expect(row.ulid, store.catalog.byPath('inbox/today.md')!.ulid);
      expect(row.path, 'inbox/today.md');
      expect(row.seededBy, store.peerId);
      expect(row.deleted, isFalse);
    });

    test('a save to an existing note announces nothing new', () async {
      final store = await openStore();
      addTearDown(store.close);
      final identity = await AuthoredIdentity.load(
        IdentityMap(engramRoot: '${root.path}/engram', peerId: store.peerId),
      );
      addTearDown(identity.dispose);
      final writer = CrdtNoteWriter(
        database: store,
        engram: engram,
        lock: NoteDocumentLock(),
        identity: identity,
      );
      await writer.write('inbox/today.md', 'first\n');
      final before = identity.rows[store.catalog.byPath('inbox/today.md')!.ulid];

      await writer.write('inbox/today.md', 'first\nsecond\n');

      expect(identity.rows.length, 1);
      expect(identical(identity.rows.values.single, before), isTrue);
    });
  });

  group('a note that already has history', () {
    test('a second save appends to the same note, not a new one', () async {
      final store = await openStore();
      addTearDown(store.close);
      final writer = await writerFor(store);

      await writer.write('inbox/today.md', 'first\n');
      final ulid = store.catalog.byPath('inbox/today.md')!.ulid;
      await writer.write('inbox/today.md', 'first\nsecond\n');

      expect(store.catalog.byPath('inbox/today.md')!.ulid, ulid);
      expect(await engram.readString('inbox/today.md'), 'first\nsecond\n');
    });

    test('the edit is durable across a reopen', () async {
      final store = await openStore();
      addTearDown(store.close);
      final writer = await writerFor(store);
      await writer.write('inbox/today.md', 'first\n');
      await writer.write('inbox/today.md', 'edited\n');

      final note = NoteDocument.open(
        store: store,
        ulid: store.catalog.byPath('inbox/today.md')!.ulid,
      );
      addTearDown(note.dispose);

      expect(note.value, 'edited\n');
    });

    test('the save is minimal, never a replace-all', () async {
      // The property that only a second device can see: a replace-all
      // converges and silently discards every concurrent remote insertion.
      final store = await openStore();
      addTearDown(store.close);
      final writer = await writerFor(store);
      await writer.write('inbox/today.md', 'one\ntwo\n');
      final ulid = store.catalog.byPath('inbox/today.md')!.ulid;

      // A peer, offline, appends a line.
      final peer = CRDTDocument(
        peerId: peerB,
        documentId: ulid,
        initialClock: HybridLogicalClock.now(),
      );
      final peerText = CRDTFugueTextHandler(peer, noteHandlerId);
      final seeded = NoteDocument.open(store: store, ulid: ulid);
      peer.importChanges(seeded.document.exportChanges());
      seeded.dispose();
      peerText.insert(peerText.value.length, 'three\n');

      // Meanwhile the user edits a word here and saves.
      await writer.write('inbox/today.md', 'one\nTWO\n');

      final merged = NoteDocument.open(store: store, ulid: ulid);
      addTearDown(merged.dispose);
      merged.document.importChanges(peer.exportChanges());

      expect(merged.value, contains('three'), reason: "the peer's line lives");
      expect(merged.value, contains('TWO'));
    });

    test('a save that changes nothing still rewrites a drifted file', () async {
      // The buffer matches the CRDT, so the diff produces nothing — but the
      // file does not match, which is the ordinary case after an external tool
      // rewrites terminators. Skipping the write on "no operations" is the trap.
      final store = await openStore();
      addTearDown(store.close);
      final writer = await writerFor(store);
      await writer.write('inbox/today.md', 'one\ntwo\n');
      await engram.writeString('inbox/today.md', 'one\r\ntwo\r\n');

      await writer.write('inbox/today.md', 'one\ntwo\n');

      expect(await engram.readString('inbox/today.md'), 'one\ntwo\n');
      expect(
        await noteFileHasDrifted(
          engram,
          store.catalog.byPath('inbox/today.md')!,
        ),
        isFalse,
      );
    });
  });

  group('a history-pending note', () {
    test('is written directly rather than refused', () async {
      // Decision 4's bounded exception: the ULID was adopted from another
      // device's map but its op-log has not arrived, so there is no document to
      // apply operations to. Refusing would lose the user's edit.
      final store = await openStore();
      addTearDown(store.close);
      final ulid = newUlid();
      store.catalog.upsert(
        CatalogRow(
          ulid: ulid,
          path: 'inbox/adopted.md',
          mergePolicy: MergePolicy.fugueText,
          state: NoteState.live,
          // No seed claim of ours, and no op-log: history pending.
        ),
      );
      final writer = await writerFor(store);

      await writer.write('inbox/adopted.md', 'typed anyway\n');

      expect(await engram.readString('inbox/adopted.md'), 'typed anyway\n');
    });

    test('no operations are invented for it', () async {
      final store = await openStore();
      addTearDown(store.close);
      final ulid = newUlid();
      store.catalog.upsert(
        CatalogRow(
          ulid: ulid,
          path: 'inbox/adopted.md',
          mergePolicy: MergePolicy.fugueText,
          state: NoteState.live,
        ),
      );
      final writer = await writerFor(store);

      await writer.write('inbox/adopted.md', 'typed anyway\n');

      // Seeding here is what Decision 7 forbids: it would build a disjoint
      // character universe under a ULID whose real history is still in flight.
      expect(store.crdt.changeStorageForDocument(ulid).getChanges(), isEmpty);
    });
  });
}
