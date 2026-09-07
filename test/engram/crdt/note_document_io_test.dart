import 'dart:io';

import 'package:brainframe/engram/crdt/app_data_resolver_io.dart';
import 'package:brainframe/engram/crdt/app_data_source.dart';
import 'package:brainframe/engram/crdt/catalog.dart';
import 'package:brainframe/engram/crdt/metadata_db_io.dart';
import 'package:brainframe/engram/crdt/note_document_io.dart';
import 'package:brainframe/engram/id.dart';
import 'package:crdt_lf/crdt_lf.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hlc_dart/hlc_dart.dart';

import '../../crdt/support/peer_ids.dart';

/// One note's document over the durable op-log: minting, reopening, and the
/// guard that stops a second device seeding a document it did not mint.
void main() {
  late Directory root;
  late AppDataRootResolver resolveRoot;
  late String engramId;

  setUp(() {
    root = Directory.systemTemp.createTempSync('brainframe_note_document');
    resolveRoot = appDataRootResolver(overridePath: root.path);
    engramId = newUlid();
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<MetadataDatabase> openStore() =>
      MetadataDatabase.open(engramId, resolveRoot: resolveRoot);

  group('mint', () {
    test('the documentId is the note ULID', () async {
      final store = await openStore();
      addTearDown(store.close);

      final note = NoteDocument.mint(store: store, path: 'inbox/today.md');
      addTearDown(note.dispose);

      // Note identity and CRDT document identity are one string, so nothing
      // has to map between them and nothing can disagree.
      expect(note.document.documentId, note.ulid);
      expect(isCanonicalUlid(note.ulid), isTrue);
    });

    test('seeds the document with the initial content', () async {
      final store = await openStore();
      addTearDown(store.close);

      final note = NoteDocument.mint(
        store: store,
        path: 'inbox/today.md',
        content: '# Today',
      );
      addTearDown(note.dispose);

      expect(note.value, '# Today');
    });

    test('empty content seeds nothing at all', () async {
      final store = await openStore();
      addTearDown(store.close);

      final note = NoteDocument.mint(
        store: store,
        path: 'inbox/empty.md',
        content: '',
      );
      addTearDown(note.dispose);

      // The seed is written unconditionally; CRDTFugueTextHandler.insert
      // itself returns early on empty text. Pinned here because that no-op is
      // the library's behaviour, not ours — if it ever started registering an
      // empty operation, an empty note would gain a meaningless change and
      // "our own empty note" would stop being distinguishable by op-log alone.
      expect(note.value, isEmpty);
      expect(note.document.exportChanges(), isEmpty);
      expect(
        store.crdt.changeStorageForDocument(note.ulid).getChanges(),
        isEmpty,
      );
    });

    test('writes a catalog row with the derived policy', () async {
      final store = await openStore();
      addTearDown(store.close);

      final note = NoteDocument.mint(store: store, path: 'refs/diagram.png');
      addTearDown(note.dispose);

      final row = store.catalog.byUlid(note.ulid)!;
      expect(row.path, 'refs/diagram.png');
      expect(row.mergePolicy, MergePolicy.blobLww);
      expect(row.state, NoteState.live);
    });

    test('takes the seed claim for this device', () async {
      final store = await openStore();
      addTearDown(store.close);

      final note = NoteDocument.mint(store: store, path: 'inbox/today.md');
      addTearDown(note.dispose);

      // So a later adopting device can tell a history exists somewhere.
      expect(store.catalog.byUlid(note.ulid)!.seededBy, store.peerId);
    });

    test('stamps operations with the store peer identity', () async {
      final store = await openStore();
      addTearDown(store.close);

      final note = NoteDocument.mint(
        store: store,
        path: 'inbox/today.md',
        content: 'hello',
      );
      addTearDown(note.dispose);

      expect(note.document.peerId, store.peerId);
      expect(
        note.document.exportChanges().map((change) => change.author).toSet(),
        {store.peerId},
      );
    });

    test('the seed reaches the op-log, not only memory', () async {
      final store = await openStore();
      addTearDown(store.close);

      final note = NoteDocument.mint(
        store: store,
        path: 'inbox/today.md',
        content: 'seeded',
      );
      addTearDown(note.dispose);

      // The frontier bookkeeping must not treat the seed as already saved;
      // if it did, this note would reopen empty with no error anywhere.
      expect(
        store.crdt.changeStorageForDocument(note.ulid).getChanges(),
        isNotEmpty,
      );
    });

    test('two findable notes cannot claim one path', () async {
      final store = await openStore();
      addTearDown(store.close);

      NoteDocument.mint(store: store, path: 'inbox/today.md').dispose();

      expect(
        () => NoteDocument.mint(store: store, path: 'inbox/today.md'),
        throwsA(anything),
      );
    });
  });

  group('terminators are normalized at every door', () {
    test('seeding CRLF content yields an LF sequence', () async {
      final store = await openStore();
      addTearDown(store.close);

      // The adoption and scan case: a file authored on Windows, seeded whole.
      final note = NoteDocument.mint(
        store: store,
        path: 'inbox/today.md',
        content: 'one\r\ntwo\r\nthree\r\n',
      );
      addTearDown(note.dispose);

      expect(note.value, 'one\ntwo\nthree\n');
      expect(note.value.contains('\r'), isFalse);
    });

    test('a lone carriage return is seeded as content', () async {
      final store = await openStore();
      addTearDown(store.close);

      final note = NoteDocument.mint(
        store: store,
        path: 'inbox/today.md',
        content: 'a\rb\r\nc',
      );
      addTearDown(note.dispose);

      // The CRLF goes; the bare \r is text the user typed and stays.
      expect(note.value, 'a\rb\nc');
    });

    test('the op-log holds LF, not just the in-memory value', () async {
      final store = await openStore();
      addTearDown(store.close);

      final note = NoteDocument.mint(
        store: store,
        path: 'inbox/today.md',
        content: 'one\r\ntwo\r\n',
      );
      final ulid = note.ulid;
      note.dispose();

      // Normalizing only the materialized value would leave CRLF in the
      // permanent log, where it would reach every peer that syncs it. This is
      // the assertion that catches normalization applied too late.
      final reopened = NoteDocument.open(store: store, ulid: ulid);
      addTearDown(reopened.dispose);

      expect(reopened.value, 'one\ntwo\n');
    });

    test('insert normalizes a pasted CRLF run', () async {
      final store = await openStore();
      addTearDown(store.close);

      final note = NoteDocument.mint(
        store: store,
        path: 'inbox/today.md',
        content: 'start\n',
      );
      addTearDown(note.dispose);

      // The step 9 door: a paste off a Windows clipboard.
      note.insert(note.value.length, 'a\r\nb\r\n');

      expect(note.value, 'start\na\nb\n');
    });

    test('a blobLww note keeps its bytes exactly', () async {
      final store = await openStore();
      addTearDown(store.close);

      // Decision 10 is scoped to fugueText. A blob whose bytes happen to
      // contain 0x0d 0x0a must not be rewritten — normalization applied too
      // broadly corrupts a file no one can recover, which is the asymmetry
      // Decision 3's default is built around.
      final note = NoteDocument.mint(
        store: store,
        path: 'refs/diagram.png',
        content: 'PNG\r\nbytes\r\n',
      );
      addTearDown(note.dispose);

      expect(note.value, 'PNG\r\nbytes\r\n');
    });

    test('content with no CRLF is seeded unchanged', () async {
      final store = await openStore();
      addTearDown(store.close);

      final note = NoteDocument.mint(
        store: store,
        path: 'inbox/today.md',
        content: '# Today\n\nnotes\n',
      );
      addTearDown(note.dispose);

      expect(note.value, '# Today\n\nnotes\n');
    });
  });

  group('history survives a restart', () {
    test('create, edit, close, reopen', () async {
      final first = await openStore();
      final note = NoteDocument.mint(
        store: first,
        path: 'inbox/today.md',
        content: 'Hello',
      );
      final ulid = note.ulid;
      note
        ..insert(5, ' world')
        ..dispose();
      first.close();

      final second = await openStore();
      addTearDown(second.close);
      final reopened = NoteDocument.open(store: second, ulid: ulid);
      addTearDown(reopened.dispose);

      expect(reopened.value, 'Hello world');
    });

    test('a deletion survives too', () async {
      final first = await openStore();
      final note = NoteDocument.mint(
        store: first,
        path: 'inbox/today.md',
        content: 'Hello world',
      );
      final ulid = note.ulid;
      note
        ..delete(5, 6)
        ..dispose();
      first.close();

      final second = await openStore();
      addTearDown(second.close);
      final reopened = NoteDocument.open(store: second, ulid: ulid);
      addTearDown(reopened.dispose);

      expect(reopened.value, 'Hello');
    });

    test('every change is stored, not just the last', () async {
      final store = await openStore();
      addTearDown(store.close);

      final note = NoteDocument.mint(
        store: store,
        path: 'inbox/today.md',
        content: 'a',
      );
      addTearDown(note.dispose);
      for (var i = 0; i < 20; i++) {
        note.insert(note.value.length, 'x');
      }

      // The incremental save writes only what is newer than the last
      // frontier. This is the assertion that fails if that ever under-saves —
      // silently, and as data loss rather than an error.
      expect(
        store.crdt.changeStorageForDocument(note.ulid).getChanges().length,
        note.document.exportChanges().length,
      );
    });

    test('a long edit run reopens with every character', () async {
      final first = await openStore();
      final note = NoteDocument.mint(
        store: first,
        path: 'inbox/today.md',
        content: '',
      );
      final ulid = note.ulid;
      for (var i = 0; i < 20; i++) {
        note.insert(note.value.length, '$i,');
      }
      final expected = note.value;
      note.dispose();
      first.close();

      final second = await openStore();
      addTearDown(second.close);
      final reopened = NoteDocument.open(store: second, ulid: ulid);
      addTearDown(reopened.dispose);

      expect(reopened.value, expected);
    });
  });

  group('documents in one database stay isolated', () {
    test('each note reopens with its own content', () async {
      final first = await openStore();
      final a = NoteDocument.mint(
        store: first,
        path: 'a.md',
        content: 'note A',
      );
      final b = NoteDocument.mint(
        store: first,
        path: 'b.md',
        content: 'note B',
      );
      final (idA, idB) = (a.ulid, b.ulid);
      a.dispose();
      b.dispose();
      first.close();

      final second = await openStore();
      addTearDown(second.close);
      final reopenedA = NoteDocument.open(store: second, ulid: idA);
      addTearDown(reopenedA.dispose);
      final reopenedB = NoteDocument.open(store: second, ulid: idB);
      addTearDown(reopenedB.dispose);

      expect(reopenedA.value, 'note A');
      expect(reopenedB.value, 'note B');
    });

    test('editing one note leaves the other untouched', () async {
      final store = await openStore();
      addTearDown(store.close);

      final a = NoteDocument.mint(store: store, path: 'a.md', content: 'A');
      addTearDown(a.dispose);
      final b = NoteDocument.mint(store: store, path: 'b.md', content: 'B');
      addTearDown(b.dispose);

      a.insert(1, '!');

      expect(b.value, 'B');
      expect(
        store.crdt.changeStorageForDocument(b.ulid).getChanges().length,
        1,
        reason: 'B holds only its own seed',
      );
    });
  });

  group('deleting metadata.db loses history, never content', () {
    test('the markdown file is untouched and the history is gone', () async {
      // The file is the engram's; the store is the device's. Step 4 does not
      // write the file at all — the editor still does, exactly as today — so
      // this pins the boundary rather than a behaviour of the materializer.
      final engramFile = File('${root.path}/inbox-today.md')
        ..createSync(recursive: true)
        ..writeAsStringSync('Hello world');

      final first = await openStore();
      final ulid = NoteDocument.mint(
        store: first,
        path: 'inbox/today.md',
        content: 'Hello world',
      ).ulid;
      first.close();

      final databasePath =
          '${root.path}/engrams/$engramId/$metadataDatabaseFileName';
      expect(File(databasePath).existsSync(), isTrue);
      File(databasePath).deleteSync();

      final rebuilt = await openStore();
      addTearDown(rebuilt.close);

      expect(rebuilt.catalog.byUlid(ulid), isNull, reason: 'history is gone');
      expect(
        engramFile.readAsStringSync(),
        'Hello world',
        reason: 'content never lived in the database',
      );
    });
  });

  group('never seed under a ULID this device did not mint', () {
    /// A catalog row this device adopted: an identity it knows, a seed claim
    /// held by someone else, and no local history — exactly what the identity
    /// map produces before any log has arrived.
    void adoptRow(MetadataDatabase store, String ulid) {
      store.catalog.upsert(
        CatalogRow(
          ulid: ulid,
          path: 'adopted/note.md',
          mergePolicy: MergePolicy.fugueText,
          state: NoteState.historyPending,
          seedClaim: OperationId(peerA, HybridLogicalClock(l: 10, c: 0)),
        ),
      );
    }

    test('an adopted note with no log refuses to open', () async {
      final store = await openStore();
      addTearDown(store.close);
      final ulid = newUlid();
      adoptRow(store, ulid);

      // Handing back an empty document here is what would let the caller seed
      // it, producing a disjoint character universe that merges as duplicated
      // content rather than as one note.
      expect(
        () => NoteDocument.open(store: store, ulid: ulid),
        throwsA(isA<NoteHistoryPendingException>()),
      );
    });

    test('the refusal names the note', () async {
      final store = await openStore();
      addTearDown(store.close);
      final ulid = newUlid();
      adoptRow(store, ulid);

      expect(
        () => NoteDocument.open(store: store, ulid: ulid),
        throwsA(
          isA<NoteHistoryPendingException>().having(
            (e) => e.toString(),
            'toString',
            contains(ulid),
          ),
        ),
      );
    });

    test('an unclaimed seed is not this device\'s to open either', () async {
      // A map that outlived every op-log backing it. Taking the seed is a
      // deliberate act on the user's first edit (Decision 9), not something
      // that falls out of opening the note.
      final store = await openStore();
      addTearDown(store.close);
      final ulid = newUlid();
      store.catalog.upsert(
        CatalogRow(
          ulid: ulid,
          path: 'adopted/note.md',
          mergePolicy: MergePolicy.fugueText,
          state: NoteState.historyPending,
        ),
      );

      expect(
        () => NoteDocument.open(store: store, ulid: ulid),
        throwsA(isA<NoteHistoryPendingException>()),
      );
    });

    test('our own empty note reopens as an empty document', () async {
      // The seed claim is ours, so an empty op-log is not a missing history —
      // it is a note we minted and have not typed into.
      final first = await openStore();
      final ulid = NoteDocument.mint(store: first, path: 'inbox/empty.md').ulid;
      first.close();

      final second = await openStore();
      addTearDown(second.close);
      final reopened = NoteDocument.open(store: second, ulid: ulid);
      addTearDown(reopened.dispose);

      expect(reopened.value, isEmpty);
    });

    test('an empty note we minted still accepts a first edit', () async {
      final first = await openStore();
      final ulid = NoteDocument.mint(store: first, path: 'inbox/empty.md').ulid;
      first.close();

      final second = await openStore();
      final reopened = NoteDocument.open(store: second, ulid: ulid);
      reopened
        ..insert(0, 'first words')
        ..dispose();
      second.close();

      final third = await openStore();
      addTearDown(third.close);
      final again = NoteDocument.open(store: third, ulid: ulid);
      addTearDown(again.dispose);

      expect(again.value, 'first words');
    });

    test('a ULID with no catalog row is unknown, not pending', () async {
      final store = await openStore();
      addTearDown(store.close);

      expect(
        () => NoteDocument.open(store: store, ulid: newUlid()),
        throwsA(isA<UnknownNoteException>()),
      );
    });

    test('the unknown-note failure names the note', () async {
      final store = await openStore();
      addTearDown(store.close);
      final ulid = newUlid();

      expect(
        () => NoteDocument.open(store: store, ulid: ulid),
        throwsA(
          isA<UnknownNoteException>().having(
            (e) => e.toString(),
            'toString',
            contains(ulid),
          ),
        ),
      );
    });
  });

  group('dispose', () {
    test('releases the document', () async {
      final store = await openStore();
      addTearDown(store.close);

      final note = NoteDocument.mint(store: store, path: 'inbox/today.md');
      note.dispose();

      expect(note.document.isDisposed, isTrue);
    });

    test('is safe to call twice', () async {
      final store = await openStore();
      addTearDown(store.close);

      final note = NoteDocument.mint(store: store, path: 'inbox/today.md');

      expect(note.dispose, returnsNormally);
      expect(note.dispose, returnsNormally);
    });

    test('a disposed note reopens from the op-log', () async {
      // The document is the expensive, disposable half; the op-log outlives
      // it. That is what makes holding one note at a time viable.
      final store = await openStore();
      addTearDown(store.close);

      final note = NoteDocument.mint(
        store: store,
        path: 'inbox/today.md',
        content: 'durable',
      );
      final ulid = note.ulid;
      note.dispose();

      final reopened = NoteDocument.open(store: store, ulid: ulid);
      addTearDown(reopened.dispose);

      expect(reopened.value, 'durable');
    });
  });
}
