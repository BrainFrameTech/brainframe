import 'dart:io';
import 'dart:typed_data';

import 'package:brainframe/engram/crdt/app_data_resolver_io.dart';
import 'package:brainframe/engram/crdt/blob_document_io.dart';
import 'package:brainframe/engram/crdt/catalog.dart';
import 'package:brainframe/engram/crdt/drift.dart';
import 'package:brainframe/engram/crdt/metadata_db_io.dart';
import 'package:brainframe/engram/crdt/note_document_io.dart';
import 'package:brainframe/engram/id.dart';
import 'package:crdt_lf/crdt_lf.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hlc_dart/hlc_dart.dart';

import '../../crdt/support/peer_ids.dart';
import '../../crdt/support/replica.dart' show kBaseLogicalTime;

/// A blob's document over the op-log: a register of hash and size, never the
/// bytes (Decision 3). The three tests the plan names for step 14 — an image
/// never enters the diff path, concurrent writes resolve through the locked
/// comparator, the database does not grow with the file — plus the codec,
/// the gates, and a restart.
void main() {
  late Directory root;
  late AppDataRootResolver resolveRoot;
  late String engramId;

  setUp(() {
    root = Directory.systemTemp.createTempSync('brainframe_blob_document');
    resolveRoot = appDataRootResolver(overridePath: root.path);
    engramId = newUlid();
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<MetadataDatabase> openStore() =>
      MetadataDatabase.open(engramId, resolveRoot: resolveRoot);

  /// A stand-in for a second device's copy of the same document: the same
  /// ULID, a different peer, and a clock the test controls so the winner
  /// is the comparator's choice rather than the wall clock's.
  ({CRDTDocument doc, CRDTRegisterHandler<BlobState> register}) peerCopy(
    String ulid,
    PeerId peer, {
    int clock = kBaseLogicalTime,
  }) {
    final doc = CRDTDocument(
      peerId: peer,
      documentId: ulid,
      initialClock: HybridLogicalClock(l: clock, c: 0),
    );
    final register = CRDTRegisterHandler<BlobState>(
      doc,
      blobHandlerId,
      valueCodec: const BlobStateCodec(),
      handlerType: blobHandlerType,
    );
    return (doc: doc, register: register);
  }

  final png = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a]);

  group('BlobState', () {
    test('describes bytes by hash and size', () {
      final state = BlobState.of(png);
      expect(state.hash, contentHash(png));
      expect(state.size, png.length);
      expect(state, BlobState.of(Uint8List.fromList(png)));
      expect(state.hashCode, BlobState.of(Uint8List.fromList(png)).hashCode);
      expect(state, isNot(BlobState.of(Uint8List.fromList([0x89]))));
      expect(state.toString(), contains('${png.length} bytes'));
    });

    test('the codec round-trips, in forty-odd bytes', () {
      const codec = BlobStateCodec();
      final state = BlobState.of(png);
      final bytes = codec.encode(state);
      expect(bytes.length, 33, reason: '32 hash bytes and a one-byte varint');
      expect(codec.decode(bytes), state);

      final large = BlobState(hash: state.hash, size: 1 << 40);
      expect(codec.decode(codec.encode(large)), large);
    });

    test('the codec refuses what is not a digest', () {
      const codec = BlobStateCodec();
      expect(
        () => codec.encode(const BlobState(hash: 'abc', size: 1)),
        throwsFormatException,
      );
      expect(
        () => codec.decode(Uint8List.fromList(List.filled(20, 0))),
        throwsFormatException,
      );
    });
  });

  group('mint', () {
    test('seeds the register with the file, and a catalog row', () async {
      final store = await openStore();
      addTearDown(store.close);

      final blob = BlobDocument.mint(store: store, path: 'pic.png', bytes: png);
      addTearDown(blob.dispose);

      expect(blob.document.documentId, blob.ulid);
      expect(blob.state, BlobState.of(png));
      final row = store.catalog.byUlid(blob.ulid)!;
      expect(row.path, 'pic.png');
      expect(row.mergePolicy, MergePolicy.blobLww);
      expect(row.state, NoteState.live);
      expect(row.seededBy, store.peerId);
      expect(
        store.crdt.changeStorageForDocument(blob.ulid).getChanges().length,
        1,
        reason: 'the first claim is in the op-log',
      );
    });

    test('an empty file is a claim like any other', () async {
      final store = await openStore();
      addTearDown(store.close);

      final blob = BlobDocument.mint(
        store: store,
        path: 'empty.bin',
        bytes: Uint8List(0),
      );
      addTearDown(blob.dispose);

      expect(blob.state, BlobState.of(Uint8List(0)));
      expect(
        store.crdt.changeStorageForDocument(blob.ulid).getChanges(),
        isNotEmpty,
        reason: 'never an empty log for a blob we minted',
      );
    });

    test('refuses a text path', () async {
      final store = await openStore();
      addTearDown(store.close);

      expect(
        () => BlobDocument.mint(store: store, path: 'note.md', bytes: png),
        throwsArgumentError,
      );
      expect(store.catalog.byPath('note.md'), isNull);
    });
  });

  group('never enters the diff path', () {
    test('the document has no text sequence', () async {
      final store = await openStore();
      addTearDown(store.close);
      final blob = BlobDocument.mint(store: store, path: 'pic.png', bytes: png);
      addTearDown(blob.dispose);

      // The only handler on the document is the register, so there is
      // nothing a diff could write into — and NoteDocument, which is the
      // diff's only door, will not open it.
      expect(
        () => NoteDocument.open(store: store, ulid: blob.ulid),
        throwsArgumentError,
      );
    });

    test('bytes that look like CRLF are not normalized', () async {
      // Decision 10 is scoped to fugueText. A blob whose bytes happen to
      // contain 0x0d 0x0a must not be rewritten — and here that is true
      // because no bytes are in the log at all, only their hash.
      final store = await openStore();
      addTearDown(store.close);
      final crlf = Uint8List.fromList('PNG\r\nbytes\r\n'.codeUnits);

      final blob = BlobDocument.mint(store: store, path: 'x.png', bytes: crlf);
      addTearDown(blob.dispose);

      expect(blob.state!.hash, contentHash(crlf));
      expect(blob.state!.size, crlf.length);
    });
  });

  group('two concurrent writes resolve through the locked comparator', () {
    test('a later HLC wins regardless of delivery order', () async {
      final store = await openStore();
      addTearDown(store.close);
      final ulid = newUlid();
      final earlier = BlobState.of(Uint8List.fromList([1]));
      final later = BlobState.of(Uint8List.fromList([2]));

      final a = peerCopy(ulid, peerA, clock: kBaseLogicalTime + 1000);
      final b = peerCopy(ulid, peerB);
      a.register.set(later);
      b.register.set(earlier);

      final aChanges = a.doc.exportChanges();
      final bChanges = b.doc.exportChanges();
      a.doc.importChanges(bChanges);
      b.doc.importChanges(aChanges);

      expect(a.register.value, later);
      expect(b.register.value, later, reason: 'both name the same winner');
    });

    test('an equal HLC falls through to peerID', () async {
      // Both claims carry the same logical time; the comparator's second
      // key decides, and the higher peer sorts last, so it wins. That
      // direction is the library's — peer_ordering_test.dart pins that
      // peerA < peerB — and it is pinned here in the same spirit: a change
      // must fail loudly, not silently invert a winner.
      final ulid = newUlid();
      final fromA = BlobState.of(Uint8List.fromList([0xa]));
      final fromB = BlobState.of(Uint8List.fromList([0xb]));

      final a = peerCopy(ulid, peerA);
      final b = peerCopy(ulid, peerB);
      a.register.set(fromA);
      b.register.set(fromB);
      expect(
        a.doc.exportChanges().single.hlc.l,
        b.doc.exportChanges().single.hlc.l,
        reason: 'the tie this case is about',
      );

      a.doc.importChanges(b.doc.exportChanges());
      b.doc.importChanges(a.doc.exportChanges());

      expect(a.register.value, fromB);
      expect(b.register.value, fromB);
    });

    test("a third replica replaying from scratch agrees", () async {
      final ulid = newUlid();
      final fromA = BlobState.of(Uint8List.fromList([0xa]));
      final fromB = BlobState.of(Uint8List.fromList([0xb]));
      final a = peerCopy(ulid, peerA, clock: kBaseLogicalTime + 5);
      final b = peerCopy(ulid, peerB);
      a.register.set(fromA);
      b.register.set(fromB);

      final cold = peerCopy(ulid, peerC);
      cold.doc.importChanges([
        ...b.doc.exportChanges(),
        ...a.doc.exportChanges(),
      ]);

      expect(cold.register.value, fromA, reason: 'the later clock');
    });

    test('through the store: a remote claim lands on reopen', () async {
      final store = await openStore();
      addTearDown(store.close);
      final blob = BlobDocument.mint(
        store: store,
        path: 'pic.png',
        bytes: Uint8List.fromList([1]),
      );
      final ours = blob.state;
      blob.dispose();

      // A peer's claim, stamped well after ours, arrives (how it arrives is
      // #67's; here it is imported by hand) and is persisted.
      final remote = peerCopy(
        blob.ulid,
        peerB,
        clock: DateTime.now().millisecondsSinceEpoch + 60000,
      );
      final theirs = BlobState.of(Uint8List.fromList([2]));
      remote.register.set(theirs);
      store.crdt
          .changeStorageForDocument(blob.ulid)
          .saveChanges(remote.doc.exportChanges());

      final reopened = BlobDocument.open(store: store, ulid: blob.ulid);
      addTearDown(reopened.dispose);
      expect(reopened.state, theirs);
      expect(reopened.state, isNot(ours));
    });
  });

  group('the database does not grow with the file', () {
    test('a claim costs the same whatever the file weighs', () async {
      final store = await openStore();
      addTearDown(store.close);
      final small = Uint8List.fromList([1, 2, 3]);
      final big = Uint8List(4 * 1024 * 1024);
      for (var i = 0; i < big.length; i += 4099) {
        big[i] = i & 0xff;
      }

      final one = BlobDocument.mint(store: store, path: 'a.bin', bytes: small);
      addTearDown(one.dispose);
      final two = BlobDocument.mint(store: store, path: 'b.bin', bytes: big);
      addTearDown(two.dispose);

      int stored(String ulid) =>
          store.database.select(
                'SELECT SUM(LENGTH(bytes)) AS n FROM changes WHERE document_id = ?',
                [ulid],
              ).first['n']
              as int;

      // Four megabytes against three bytes: the only difference in the log
      // is the varint that spells the size, three bytes longer.
      expect(stored(two.ulid) - stored(one.ulid), 3);
      expect(stored(two.ulid), lessThan(256));
    });

    test('recording a new file adds one small change', () async {
      final store = await openStore();
      addTearDown(store.close);
      final blob = BlobDocument.mint(
        store: store,
        path: 'a.bin',
        bytes: Uint8List(0),
      );
      addTearDown(blob.dispose);

      final replaced = Uint8List(1024 * 1024);
      expect(blob.record(replaced), isTrue);

      final changes = store.crdt
          .changeStorageForDocument(blob.ulid)
          .getChanges();
      expect(changes.length, 2);
      expect(changes.last.payloadBytes().length, lessThan(128));
      expect(blob.state, BlobState.of(replaced));
    });

    test('recording the same bytes again writes nothing', () async {
      final store = await openStore();
      addTearDown(store.close);
      final blob = BlobDocument.mint(store: store, path: 'a.bin', bytes: png);
      addTearDown(blob.dispose);

      expect(blob.record(Uint8List.fromList(png)), isFalse);
      expect(
        store.crdt.changeStorageForDocument(blob.ulid).getChanges().length,
        1,
      );
    });
  });

  group('open', () {
    test('a claim survives a restart', () async {
      final ulid = await () async {
        final store = await openStore();
        final blob = BlobDocument.mint(
          store: store,
          path: 'pic.png',
          bytes: png,
        );
        blob.record(Uint8List.fromList([9, 9, 9]));
        blob.dispose();
        store.close();
        return blob.ulid;
      }();

      final store = await openStore();
      addTearDown(store.close);
      final reopened = BlobDocument.open(store: store, ulid: ulid);
      addTearDown(reopened.dispose);

      expect(reopened.state, BlobState.of(Uint8List.fromList([9, 9, 9])));
    });

    test('an unknown ULID is unknown', () async {
      final store = await openStore();
      addTearDown(store.close);
      expect(
        () => BlobDocument.open(store: store, ulid: newUlid()),
        throwsA(isA<UnknownNoteException>()),
      );
    });

    test('an adopted blob with no log is history-pending', () async {
      // The same guard as a text note: not because a register could be
      // seeded twice into duplicated content — it could not — but because a
      // live document for a note whose history is elsewhere is what every
      // caller has been told not to expect.
      final store = await openStore();
      addTearDown(store.close);
      final ulid = newUlid();
      store.catalog.upsert(
        CatalogRow(
          ulid: ulid,
          path: 'adopted/pic.png',
          mergePolicy: MergePolicy.blobLww,
          state: NoteState.historyPending,
          seedClaim: OperationId(peerA, HybridLogicalClock(l: 10, c: 0)),
        ),
      );
      expect(
        () => BlobDocument.open(store: store, ulid: ulid),
        throwsA(isA<NoteHistoryPendingException>()),
      );
    });

    test('refuses a text note', () async {
      final store = await openStore();
      addTearDown(store.close);
      final note = NoteDocument.mint(store: store, path: 'a.md', content: 'x');
      addTearDown(note.dispose);

      expect(
        () => BlobDocument.open(store: store, ulid: note.ulid),
        throwsArgumentError,
      );
    });
  });
}
