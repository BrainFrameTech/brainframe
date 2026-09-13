import 'dart:io';
import 'dart:typed_data';

import 'package:brainframe/engram/crdt/app_data_resolver_io.dart';
import 'package:brainframe/engram/crdt/blob_document_io.dart';
import 'package:brainframe/engram/crdt/blob_note_writer_io.dart';
import 'package:brainframe/engram/crdt/catalog.dart';
import 'package:brainframe/engram/crdt/crdt_note_writer_io.dart';
import 'package:brainframe/engram/crdt/drift.dart';
import 'package:brainframe/engram/crdt/identity_authorship_io.dart';
import 'package:brainframe/engram/crdt/identity_map_io.dart';
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

/// The editor's save for a plain-file note: the bytes to disk, then one
/// claim — and the text writer handing such a note here by its policy.
void main() {
  late Directory root;
  late AppDataRootResolver resolveRoot;
  late String engramRoot;
  late FileSystemEngramStore engram;

  setUp(() {
    root = Directory.systemTemp.createTempSync('brainframe_blob_writer');
    resolveRoot = appDataRootResolver(overridePath: root.path);
    engramRoot = '${root.path}/engram';
    Directory(engramRoot).createSync();
    engram = FileSystemEngramStore(EngramLocation(engramRoot));
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<MetadataDatabase> openStore() =>
      MetadataDatabase.open(newUlid(), resolveRoot: resolveRoot);

  Future<AuthoredIdentity> identityFor(MetadataDatabase store) =>
      AuthoredIdentity.load(
        IdentityMap(engramRoot: engramRoot, peerId: store.peerId),
        writer: DebouncedIdentityMapWriter(
          (_) async {},
          idleDebounce: const Duration(days: 1),
          maxWait: const Duration(days: 1),
        ),
      );

  /// A `.md` note the ceiling has made a plain file — what step 18 mints for
  /// an oversized arrival and step 19 produces by conversion, built by hand
  /// here since neither exists yet: a `blobLww` row at a text path, seeded
  /// by this device, with one claim in its log describing [bytes].
  String plainFileNote(MetadataDatabase store, String path, Uint8List bytes) {
    final ulid = newUlid();
    final document = CRDTDocument(
      peerId: store.peerId,
      documentId: ulid,
      initialClock: HybridLogicalClock.now(),
    );
    CRDTRegisterHandler<ContentDigest>(
      document,
      blobHandlerId,
      valueCodec: const ContentDigestCodec(),
      handlerType: blobHandlerType,
    ).set(ContentDigest.of(bytes));
    store.catalog.upsert(
      CatalogRow(
        ulid: ulid,
        path: path,
        mergePolicy: MergePolicy.blobLww,
        state: NoteState.live,
        materializedHash: contentHash(bytes),
        size: bytes.length,
        seedClaim: OperationId(store.peerId, document.hlc),
      ),
    );
    store.crdt
        .changeStorageForDocument(ulid)
        .saveChanges(document.exportChanges());
    document.dispose();
    return ulid;
  }

  int changesOf(MetadataDatabase store, String ulid) =>
      store.crdt.changeStorageForDocument(ulid).getChanges().length;

  group('BlobNoteWriter', () {
    test('writes the file, then one claim describing it', () async {
      final store = await openStore();
      addTearDown(store.close);
      final before = Uint8List.fromList('old\n'.codeUnits);
      await engram.writeBytes('big.md', before);
      final ulid = plainFileNote(store, 'big.md', before);
      final writer = BlobNoteWriter(
        database: store,
        engram: engram,
        lock: NoteDocumentLock(),
      );

      await writer.write('big.md', 'new text\n');

      expect(await engram.readString('big.md'), 'new text\n');
      expect(changesOf(store, ulid), 2, reason: 'the seed and one claim');
      final blob = BlobDocument.open(store: store, ulid: ulid);
      addTearDown(blob.dispose);
      expect(blob.state, ContentDigest.of(await engram.readBytes('big.md')));
      final row = store.catalog.byUlid(ulid)!;
      expect(row.materializedHash, blob.state!.hash);
      expect(row.size, 9);
      expect(row.mergePolicy, MergePolicy.blobLww, reason: 'still a blob');
    });

    test('saving the same text again writes no claim', () async {
      final store = await openStore();
      addTearDown(store.close);
      final bytes = Uint8List.fromList('same\n'.codeUnits);
      await engram.writeBytes('big.md', bytes);
      final ulid = plainFileNote(store, 'big.md', bytes);
      final writer = BlobNoteWriter(
        database: store,
        engram: engram,
        lock: NoteDocumentLock(),
      );

      await writer.write('big.md', 'same\n');

      expect(changesOf(store, ulid), 1);
      expect(await engram.readString('big.md'), 'same\n');
    });

    test('the bytes are written exactly as typed, never normalized', () async {
      // Decision 10 is scoped to fugueText. A plain file keeps its CRLF.
      final store = await openStore();
      addTearDown(store.close);
      final bytes = Uint8List.fromList('x\n'.codeUnits);
      await engram.writeBytes('big.md', bytes);
      plainFileNote(store, 'big.md', bytes);
      final writer = BlobNoteWriter(
        database: store,
        engram: engram,
        lock: NoteDocumentLock(),
      );

      await writer.write('big.md', 'one\r\ntwo\r\n');

      expect(await engram.readString('big.md'), 'one\r\ntwo\r\n');
    });

    test('a path the catalog has never seen is minted and announced', () async {
      // The editor creating a file with a blob's extension: minted from the
      // buffer, as a text note would be, and recorded in the map.
      final store = await openStore();
      addTearDown(store.close);
      final identity = await identityFor(store);
      final writer = BlobNoteWriter(
        database: store,
        engram: engram,
        lock: NoteDocumentLock(),
        identity: identity,
      );

      await writer.write('notes.unknown', 'contents');

      expect(await engram.readString('notes.unknown'), 'contents');
      final row = store.catalog.byPath('notes.unknown')!;
      expect(row.mergePolicy, MergePolicy.blobLww);
      expect(row.seededBy, store.peerId);
      expect(row.materializedHash, contentHashOfString('contents'));
      expect(changesOf(store, row.ulid), 1);
      expect(identity.rows.keys, [row.ulid]);
    });

    test('a history-pending blob is written, and nothing else', () async {
      // Adopted from another device's map, claims not yet arrived: the file
      // is saved — that is the point of writing it first — and the catalog
      // is left for the log to reconcile against when it lands.
      final store = await openStore();
      addTearDown(store.close);
      final ulid = newUlid();
      store.catalog.upsert(
        CatalogRow(
          ulid: ulid,
          path: 'theirs.md',
          mergePolicy: MergePolicy.blobLww,
          state: NoteState.historyPending,
          seedClaim: OperationId(peerB, HybridLogicalClock.now()),
        ),
      );
      final writer = BlobNoteWriter(
        database: store,
        engram: engram,
        lock: NoteDocumentLock(),
      );

      await writer.write('theirs.md', 'edited here\n');

      expect(await engram.readString('theirs.md'), 'edited here\n');
      expect(changesOf(store, ulid), 0);
      expect(store.catalog.byUlid(ulid)!.materializedHash, isNull);
    });

    test('refuses a text note', () async {
      final store = await openStore();
      addTearDown(store.close);
      final note = NoteDocument.mint(store: store, path: 'a.md', content: 'x');
      note.dispose();
      final writer = BlobNoteWriter(
        database: store,
        engram: engram,
        lock: NoteDocumentLock(),
      );

      await expectLater(() => writer.write('a.md', 'y'), throwsArgumentError);
      expect(await engram.statFile('a.md'), isNull, reason: 'nothing written');
    });
  });

  group('CrdtNoteWriter hands a blob to the blob writer', () {
    test(
      'a .md whose row is blobLww is saved whole, with no operations',
      () async {
        final store = await openStore();
        addTearDown(store.close);
        final bytes = Uint8List.fromList('big\n'.codeUnits);
        await engram.writeBytes('big.md', bytes);
        final ulid = plainFileNote(store, 'big.md', bytes);
        final writer = CrdtNoteWriter(
          database: store,
          engram: engram,
          lock: NoteDocumentLock(),
        );

        await writer.write('big.md', 'bigger\n');

        expect(await engram.readString('big.md'), 'bigger\n');
        expect(changesOf(store, ulid), 2, reason: 'a claim, not operations');
        expect(
          () => NoteDocument.open(store: store, ulid: ulid),
          throwsArgumentError,
          reason: 'never became a text note',
        );
      },
    );

    test('a text note still goes through the CRDT', () async {
      final store = await openStore();
      addTearDown(store.close);
      final writer = CrdtNoteWriter(
        database: store,
        engram: engram,
        lock: NoteDocumentLock(),
      );

      await writer.write('a.md', 'one\n');
      await writer.write('a.md', 'one\ntwo\n');

      final row = store.catalog.byPath('a.md')!;
      expect(row.mergePolicy, MergePolicy.fugueText);
      final note = NoteDocument.open(store: store, ulid: row.ulid);
      addTearDown(note.dispose);
      expect(note.value, 'one\ntwo\n');
    });

    test('a new file with a blob extension is minted as a blob', () async {
      final store = await openStore();
      addTearDown(store.close);
      final writer = CrdtNoteWriter(
        database: store,
        engram: engram,
        lock: NoteDocumentLock(),
      );

      await writer.write('data.csv', 'a,b\n');

      final row = store.catalog.byPath('data.csv')!;
      expect(row.mergePolicy, MergePolicy.blobLww);
      expect(await engram.readString('data.csv'), 'a,b\n');
      final blob = BlobDocument.open(store: store, ulid: row.ulid);
      addTearDown(blob.dispose);
      expect(blob.state, ContentDigest.of(await engram.readBytes('data.csv')));
    });

    test('the two saves share one lock', () async {
      // Both writers are handed the same lock, so a blob save and a text
      // save queue rather than interleave; pinned by ordering two through
      // the writer and seeing both land.
      final store = await openStore();
      addTearDown(store.close);
      final bytes = Uint8List.fromList('b\n'.codeUnits);
      await engram.writeBytes('big.md', bytes);
      plainFileNote(store, 'big.md', bytes);
      final writer = CrdtNoteWriter(
        database: store,
        engram: engram,
        lock: NoteDocumentLock(),
      );

      await Future.wait([
        writer.write('big.md', 'B\n'),
        writer.write('a.md', 'A\n'),
      ]);

      expect(await engram.readString('big.md'), 'B\n');
      expect(await engram.readString('a.md'), 'A\n');
    });
  });
}
