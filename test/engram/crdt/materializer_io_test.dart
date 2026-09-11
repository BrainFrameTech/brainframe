import 'dart:io';

import 'package:brainframe/engram/crdt/app_data_resolver_io.dart';
import 'package:brainframe/engram/crdt/catalog.dart';
import 'package:brainframe/engram/crdt/drift.dart';
import 'package:brainframe/engram/crdt/line_chunked_diff.dart';
import 'package:brainframe/engram/crdt/materializer_io.dart';
import 'package:brainframe/engram/crdt/metadata_db_io.dart';
import 'package:brainframe/engram/crdt/note_document_io.dart';
import 'package:brainframe/engram/fs/engram_location.dart';
import 'package:brainframe/engram/fs/fs_store_io.dart';
import 'package:brainframe/engram/id.dart';
import 'package:flutter_test/flutter_test.dart';

/// The materializer: the only writer of a note path, the ordering that makes a
/// crash recoverable, and the drift test that ordering depends on.
void main() {
  late Directory root;
  late AppDataRootResolver resolveRoot;
  late String engramId;
  late FileSystemEngramStore engram;

  setUp(() {
    root = Directory.systemTemp.createTempSync('brainframe_materializer');
    resolveRoot = appDataRootResolver(overridePath: root.path);
    engramId = newUlid();
    engram = FileSystemEngramStore(EngramLocation('${root.path}/engram'));
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<MetadataDatabase> openStore() =>
      MetadataDatabase.open(engramId, resolveRoot: resolveRoot);

  group('the file is a projection of the CRDT', () {
    test('materializing writes the sequence value verbatim', () async {
      final store = await openStore();
      addTearDown(store.close);
      final note = NoteDocument.mint(
        store: store,
        path: 'inbox/today.md',
        content: '# Today\n\nnotes\n',
      );
      addTearDown(note.dispose);

      await materializeNote(store: store, engram: engram, note: note);

      expect(await engram.readString('inbox/today.md'), '# Today\n\nnotes\n');
    });

    test('frontmatter survives byte for byte', () async {
      // Frontmatter is text inside the sequence, never a parsed structure, so
      // nothing on the way out can reorder a key, requote a value, or drop a
      // comment. Re-serializing through a YAML library would break drift
      // detection forever by reporting a phantom change on every scan.
      const text = '---\n'
          '# a comment the user wrote\n'
          'title:    "Today"\n'
          'zebra: 1\n'
          'alpha: 2\n'
          "quoted: 'single'\n"
          '---\n\n'
          'Body.\n';
      final store = await openStore();
      addTearDown(store.close);
      final note = NoteDocument.mint(
        store: store,
        path: 'inbox/today.md',
        content: text,
      );
      addTearDown(note.dispose);

      await materializeNote(store: store, engram: engram, note: note);

      expect(await engram.readString('inbox/today.md'), text);
    });

    test('materializing twice produces identical bytes', () async {
      final store = await openStore();
      addTearDown(store.close);
      final note = NoteDocument.mint(
        store: store,
        path: 'inbox/today.md',
        content: '---\ntitle: Today\n---\n\nBody 🎉\n',
      );
      addTearDown(note.dispose);

      final first = await materializeNote(
        store: store,
        engram: engram,
        note: note,
      );
      final second = await materializeNote(
        store: store,
        engram: engram,
        note: note,
      );

      // Byte-stability is what stops drift detection reporting a phantom
      // change forever.
      expect(second.materializedHash, first.materializedHash);
    });

    test('the recorded hash and size describe what was written', () async {
      final store = await openStore();
      addTearDown(store.close);
      final note = NoteDocument.mint(
        store: store,
        path: 'inbox/today.md',
        content: 'exactly this\n',
      );
      addTearDown(note.dispose);

      final row = await materializeNote(
        store: store,
        engram: engram,
        note: note,
      );

      final onDisk = await engram.readBytes('inbox/today.md');
      expect(row.materializedHash, contentHash(onDisk));
      expect(row.size, onDisk.length);
      expect(row.mtimeUtc, isNotNull);
    });

    test('an unknown note is refused rather than written', () async {
      final store = await openStore();
      addTearDown(store.close);
      final note = NoteDocument.mint(store: store, path: 'inbox/today.md');
      addTearDown(note.dispose);
      store.catalog.upsert(
        CatalogRow(
          ulid: note.ulid,
          path: 'inbox/today.md',
          mergePolicy: MergePolicy.fugueText,
          state: NoteState.tombstoned,
        ),
      );

      // Tombstoned rows are still findable by ULID, so this stays a real
      // lookup failure rather than a state check: a ULID with no row at all.
      final orphan = NoteDocument.mint(store: store, path: 'other.md');
      addTearDown(orphan.dispose);
      store.database.execute(
        'DELETE FROM bf_catalog WHERE ulid = ?',
        [orphan.ulid],
      );

      expect(
        () => materializeNote(store: store, engram: engram, note: orphan),
        throwsA(isA<UnknownNoteException>()),
      );
      expect(await engram.statFile('other.md'), isNull);
    });
  });

  group('drift detection', () {
    test('a file we just wrote has not drifted', () async {
      final store = await openStore();
      addTearDown(store.close);
      final note = NoteDocument.mint(
        store: store,
        path: 'inbox/today.md',
        content: 'ours\n',
      );
      addTearDown(note.dispose);

      final row = await materializeNote(
        store: store,
        engram: engram,
        note: note,
      );

      expect(await noteFileHasDrifted(engram, row), isFalse);
    });

    test('an external edit is drift', () async {
      final store = await openStore();
      addTearDown(store.close);
      final note = NoteDocument.mint(
        store: store,
        path: 'inbox/today.md',
        content: 'ours\n',
      );
      addTearDown(note.dispose);
      final row = await materializeNote(
        store: store,
        engram: engram,
        note: note,
      );

      await engram.writeString('inbox/today.md', 'edited in another tool\n');

      expect(await noteFileHasDrifted(engram, row), isTrue);
    });

    test('a same-size edit is caught by the hash, not the pre-filter', () async {
      final store = await openStore();
      addTearDown(store.close);
      final note = NoteDocument.mint(
        store: store,
        path: 'inbox/today.md',
        content: 'aaaa\n',
      );
      addTearDown(note.dispose);
      final row = await materializeNote(
        store: store,
        engram: engram,
        note: note,
      );

      // Identical length, so the size half of the pre-filter sees nothing and
      // only the hash can tell these apart. The mtime half still has to see
      // something, or this lands in the blind spot the next test pins — and
      // on a fast machine under a parallel test run it did.
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await engram.writeString('inbox/today.md', 'bbbb\n');
      final stat = await engram.statFile('inbox/today.md');

      expect(stat!.size, row.size, reason: 'size is blind to this edit');
      expect(await noteFileHasDrifted(engram, row), isTrue);
    });

    test('the accepted blind spot: same size, same recorded millisecond',
        () async {
      // Decision 5 says the pre-filter "must never be the sole test" and also
      // "if both are unchanged, skip hashing". Those pull against each other,
      // and this is where: when size and mtime both match, hashing is skipped,
      // so in exactly that case the pre-filter *is* the sole test.
      //
      // The bound is narrow — a same-size edit landing in the same millisecond
      // as our own last write — and it is not one the code can close, because
      // the catalog stores milliseconds and cannot describe a finer instant.
      // Pinned so the limitation is a decision on record rather than a
      // surprise, and so nobody "fixes" the truncation without reading this.
      final store = await openStore();
      addTearDown(store.close);
      final note = NoteDocument.mint(
        store: store,
        path: 'inbox/today.md',
        content: 'aaaa\n',
      );
      addTearDown(note.dispose);
      final row = await materializeNote(
        store: store,
        engram: engram,
        note: note,
      );

      await engram.writeString('inbox/today.md', 'bbbb\n');
      final stat = await engram.statFile('inbox/today.md');
      store.catalog.upsert(
        CatalogRow(
          ulid: row.ulid,
          path: row.path,
          mergePolicy: row.mergePolicy,
          state: row.state,
          materializedHash: row.materializedHash,
          size: row.size,
          mtimeUtc: stat!.mtimeUtc,
          seedClaim: row.seedClaim,
        ),
      );
      final blinded = store.catalog.byUlid(row.ulid)!;

      expect(mayHaveDrifted(blinded, stat), isFalse);
      expect(
        await noteFileHasDrifted(engram, blinded),
        isFalse,
        reason: 'the accepted miss — the hash is never reached',
      );
      expect(
        hasDrifted(blinded, contentHashOfString('bbbb\n')),
        isTrue,
        reason: 'the hash would have caught it, had it been asked',
      );
    });

    test('a missing file counts as drift', () async {
      final store = await openStore();
      addTearDown(store.close);
      final note = NoteDocument.mint(
        store: store,
        path: 'inbox/today.md',
        content: 'ours\n',
      );
      addTearDown(note.dispose);
      final row = await materializeNote(
        store: store,
        engram: engram,
        note: note,
      );

      await engram.delete('inbox/today.md');

      expect(await noteFileHasDrifted(engram, row), isTrue);
    });

    test('a never-materialized row counts as drift', () async {
      final store = await openStore();
      addTearDown(store.close);
      final note = NoteDocument.mint(
        store: store,
        path: 'inbox/today.md',
        content: 'ours\n',
      );
      addTearDown(note.dispose);
      await engram.writeString('inbox/today.md', 'ours\n');

      // The file exists and even matches, but no materializer of ours wrote
      // it, so there is nothing to trust it against.
      expect(
        await noteFileHasDrifted(engram, store.catalog.byUlid(note.ulid)!),
        isTrue,
      );
    });
  });

  group('write ordering survives a crash', () {
    test('a crash before the catalog commit self-heals', () async {
      final store = await openStore();
      addTearDown(store.close);
      final note = NoteDocument.mint(
        store: store,
        path: 'inbox/today.md',
        content: 'first\n',
      );
      addTearDown(note.dispose);
      final committed = await materializeNote(
        store: store,
        engram: engram,
        note: note,
      );

      // Simulate the crash window: the file changed, the row did not.
      note.insert(note.value.length, 'second\n');
      await engram.writeString('inbox/today.md', note.value);
      final stale = committed;

      // The next scan sees drift on a file we wrote.
      expect(await noteFileHasDrifted(engram, stale), isTrue);

      // Reconciling our own output against the CRDT finds no difference...
      final (document, text) = (note.document, note.text);
      final before = document.exportChanges().length;
      applyExternalText(
        document,
        text,
        await engram.readString('inbox/today.md'),
      );
      expect(
        document.exportChanges().length,
        before,
        reason: 'no semantic difference, so no operations',
      );

      // ...and re-recording the hash clears the drift. A redundant diff, not
      // lost or duplicated content.
      final healed = await materializeNote(
        store: store,
        engram: engram,
        note: note,
      );
      expect(await noteFileHasDrifted(engram, healed), isFalse);
      expect(await engram.readString('inbox/today.md'), 'first\nsecond\n');
    });
  });

  group('a line-ending change costs nothing and still rewrites', () {
    test('zero operations, LF on disk, and no drift on the next scan',
        () async {
      // The assertion #141 asked for, and the one a single scan cannot see.
      // Reconciliation produces nothing, so an implementation that gates the
      // write on "did anything change?" would leave the hash stale and report
      // drift on this file forever.
      final store = await openStore();
      addTearDown(store.close);
      final note = NoteDocument.mint(
        store: store,
        path: 'inbox/today.md',
        content: 'one\ntwo\nthree\n',
      );
      addTearDown(note.dispose);
      final first = await materializeNote(
        store: store,
        engram: engram,
        note: note,
      );

      // A Windows tool rewrites the terminators.
      await engram.writeString('inbox/today.md', 'one\r\ntwo\r\nthree\r\n');
      expect(await noteFileHasDrifted(engram, first), isTrue);

      // Scan 1: reconcile, which normalizes and finds nothing to do.
      final before = note.document.exportChanges().length;
      applyExternalText(
        note.document,
        note.text,
        await engram.readString('inbox/today.md'),
      );
      expect(
        note.document.exportChanges().length,
        before,
        reason: 'a pure line-ending change generates no operations',
      );

      // The write and the hash commit happen anyway.
      final rewritten = await materializeNote(
        store: store,
        engram: engram,
        note: note,
      );

      expect(await engram.readString('inbox/today.md'), 'one\ntwo\nthree\n');
      expect(rewritten.materializedHash, first.materializedHash);

      // Scan 2: this is the one that fails if the write was skipped.
      expect(
        await noteFileHasDrifted(engram, rewritten),
        isFalse,
        reason: 'the file is canonical again and the hash matches it',
      );
    });
  });

  group('write back only if it differs', () {
    test('a file that already holds the projection is not rewritten', () async {
      // Decision 6 step 5: the write is skipped when the caller can prove the
      // bytes on disk are already the projection — but step 6 still commits.
      final store = await openStore();
      addTearDown(store.close);
      final note = NoteDocument.mint(
        store: store,
        path: 'inbox/today.md',
        content: 'first\n',
      );
      addTearDown(note.dispose);
      await materializeNote(store: store, engram: engram, note: note);
      final written = await engram.statFile('inbox/today.md');
      // Wide enough that a rewrite would move the mtime on any filesystem.
      await Future<void>.delayed(const Duration(milliseconds: 20));

      final committed = await materializeNote(
        store: store,
        engram: engram,
        note: note,
        onDiskHash: contentHashOfString('first\n'),
      );

      expect(
        (await engram.statFile('inbox/today.md'))!.mtimeUtc,
        written!.mtimeUtc,
        reason: 'nothing touched the file',
      );
      expect(committed.materializedHash, contentHashOfString('first\n'));
      expect(await noteFileHasDrifted(engram, committed), isFalse);
    });

    test('a file that differs from the projection is rewritten', () async {
      final store = await openStore();
      addTearDown(store.close);
      final note = NoteDocument.mint(
        store: store,
        path: 'inbox/today.md',
        content: 'first\n',
      );
      addTearDown(note.dispose);
      await engram.writeString('inbox/today.md', 'first\r\n');

      final committed = await materializeNote(
        store: store,
        engram: engram,
        note: note,
        onDiskHash: contentHashOfString('first\r\n'),
      );

      expect(await engram.readString('inbox/today.md'), 'first\n');
      expect(await noteFileHasDrifted(engram, committed), isFalse);
    });
  });
}
