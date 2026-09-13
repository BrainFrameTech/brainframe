import 'dart:convert';
import 'dart:typed_data';

import 'package:brainframe/engram/crdt/catalog.dart';
import 'package:brainframe/engram/crdt/drift.dart';
import 'package:brainframe/engram/engram_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// Decision 5's comparisons: the hash that decides, and the pre-filter that is
/// only ever allowed to say "maybe".
void main() {
  CatalogRow rowWith({String? hash, int? size, DateTime? mtimeUtc}) =>
      CatalogRow(
        ulid: '01JBFRAMEEXAMPLEULID000000',
        path: 'inbox/today.md',
        mergePolicy: MergePolicy.fugueText,
        state: NoteState.live,
        materializedHash: hash,
        size: size,
        mtimeUtc: mtimeUtc,
      );

  final noon = DateTime.utc(2026, 9, 7, 12);

  group('contentHash', () {
    test('is stable for the same bytes', () {
      final bytes = Uint8List.fromList(utf8.encode('# Today\n'));

      expect(contentHash(bytes), contentHash(Uint8List.fromList(bytes)));
    });

    test('differs for a one-character change', () {
      expect(
        contentHashOfString('# Today\n'),
        isNot(contentHashOfString('# Todau\n')),
      );
    });

    test('a line-ending difference is a different hash', () {
      // The file on disk really did change bytes; normalization happens above
      // this layer, never inside the change detector.
      expect(
        contentHashOfString('a\nb\n'),
        isNot(contentHashOfString('a\r\nb\r\n')),
      );
    });

    test('the string and byte forms agree', () {
      const text = 'frontmatter: yes\n\nbody 🎉\n';

      expect(
        contentHashOfString(text),
        contentHash(Uint8List.fromList(utf8.encode(text))),
      );
    });

    test('is lowercase hex of the expected width', () {
      expect(contentHashOfString('x'), matches(RegExp(r'^[0-9a-f]{64}$')));
    });
  });

  group('ContentDigest', () {
    final png = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a]);

    test('describes bytes by hash and size, as one value', () {
      final digest = ContentDigest.of(png);
      expect(digest.hash, contentHash(png));
      expect(digest.size, png.length);
      expect(digest, ContentDigest.of(Uint8List.fromList(png)));
      expect(
        digest.hashCode,
        ContentDigest.of(Uint8List.fromList(png)).hashCode,
      );
      expect(digest, isNot(ContentDigest.of(Uint8List.fromList([0x89]))));
      expect(digest.toString(), contains('${png.length} bytes'));
    });
  });

  group('digestStream', () {
    // A blob may be larger than memory, so the hash is folded chunk by
    // chunk. What matters is that the answer does not depend on where the
    // chunk boundaries fall — including none at all, and one every byte.
    final bytes = Uint8List.fromList(List.generate(1000, (i) => i * 7 & 0xff));
    final whole = ContentDigest.of(bytes);

    Stream<List<int>> chunked(int size) async* {
      for (var i = 0; i < bytes.length; i += size) {
        yield bytes.sublist(
          i,
          i + size > bytes.length ? bytes.length : i + size,
        );
      }
    }

    test('agrees with the whole-bytes digest at any chunk size', () async {
      expect(await digestStream(chunked(bytes.length)), whole);
      expect(await digestStream(chunked(64)), whole);
      expect(await digestStream(chunked(7)), whole);
      expect(await digestStream(chunked(1)), whole);
    });

    test('an empty stream is the digest of nothing', () async {
      final empty = await digestStream(const Stream<List<int>>.empty());
      expect(empty, ContentDigest.of(Uint8List(0)));
      expect(empty.size, 0);
    });

    test('counts the size across chunks, not per chunk', () async {
      expect((await digestStream(chunked(300))).size, 1000);
    });

    test('digestFile streams from the store', () async {
      final store = _ChunkedStore({'a.bin': bytes}, chunkSize: 128);
      expect(await digestFile(store, 'a.bin'), whole);
      expect(store.reads, ['a.bin'], reason: 'openRead, never readBytes');
    });

    test('a store with no stream of its own still digests', () async {
      // The base class delivers readBytes as one chunk, so a backend that
      // has no streaming primitive is correct, if not memory-bounded.
      final store = _WholeStore({'a.bin': bytes});
      expect(await digestFile(store, 'a.bin'), whole);
    });
  });

  group('hasDrifted decides', () {
    test('a matching hash is not drift', () {
      final hash = contentHashOfString('same\n');

      expect(hasDrifted(rowWith(hash: hash), hash), isFalse);
    });

    test('a different hash is drift', () {
      expect(
        hasDrifted(
          rowWith(hash: contentHashOfString('old\n')),
          contentHashOfString('new\n'),
        ),
        isTrue,
      );
    });

    test('a row this device never materialized is drift', () {
      // There is no output of ours for the file to match, so the file is not
      // ours to trust.
      expect(hasDrifted(rowWith(), contentHashOfString('anything\n')), isTrue);
    });
  });

  group('mayHaveDrifted only ever says maybe', () {
    test('identical size and mtime rules the file out', () {
      final row = rowWith(hash: 'h', size: 10, mtimeUtc: noon);

      expect(
        mayHaveDrifted(row, FileFingerprint(size: 10, mtimeUtc: noon)),
        isFalse,
      );
    });

    test('a changed size is not ruled out', () {
      final row = rowWith(hash: 'h', size: 10, mtimeUtc: noon);

      expect(
        mayHaveDrifted(row, FileFingerprint(size: 11, mtimeUtc: noon)),
        isTrue,
      );
    });

    test('a same-size edit with a later mtime is not ruled out', () {
      // "hello" becoming "world": the size half sees nothing, so mtime is the
      // only thing that can decline to rule the file out, and the hash then
      // confirms it. Size alone would miss every equal-length edit.
      final row = rowWith(hash: 'h', size: 10, mtimeUtc: noon);

      expect(
        mayHaveDrifted(
          row,
          FileFingerprint(
            size: 10,
            mtimeUtc: noon.add(const Duration(seconds: 1)),
          ),
        ),
        isTrue,
      );
    });

    test('a same-size same-second edit is NOT ruled out by the hash test', () {
      // The pre-filter cannot see this one — that is precisely why Decision 5
      // forbids it being the sole test. Same size, same instant, different
      // content: trivially achievable by a script, and the hash is what
      // catches it.
      final row = rowWith(
        hash: contentHashOfString('aaaa\n'),
        size: 5,
        mtimeUtc: noon,
      );
      final unchangedStat = FileFingerprint(size: 5, mtimeUtc: noon);

      expect(
        mayHaveDrifted(row, unchangedStat),
        isFalse,
        reason: 'the cheap half sees nothing',
      );
      expect(
        hasDrifted(row, contentHashOfString('bbbb\n')),
        isTrue,
        reason: 'the hash is what actually catches it',
      );
    });

    test('sub-millisecond precision does not defeat the pre-filter', () {
      // The catalog stores mtime_utc as milliseconds; a filesystem reports
      // microseconds. Comparing them directly means a round-tripped row never
      // matches a fresh stat, so the pre-filter can never rule anything out
      // and quietly becomes "always hash" — present, and doing nothing.
      final stored = DateTime.fromMillisecondsSinceEpoch(
        noon.millisecondsSinceEpoch,
        isUtc: true,
      );
      final fromFilesystem = stored.add(const Duration(microseconds: 375));

      expect(
        mayHaveDrifted(
          rowWith(hash: 'h', size: 10, mtimeUtc: stored),
          FileFingerprint(size: 10, mtimeUtc: fromFilesystem),
        ),
        isFalse,
      );
    });

    test('a whole millisecond apart is still not ruled out', () {
      final stored = DateTime.fromMillisecondsSinceEpoch(
        noon.millisecondsSinceEpoch,
        isUtc: true,
      );

      expect(
        mayHaveDrifted(
          rowWith(hash: 'h', size: 10, mtimeUtc: stored),
          FileFingerprint(
            size: 10,
            mtimeUtc: stored.add(const Duration(milliseconds: 1)),
          ),
        ),
        isTrue,
      );
    });

    test('a missing stat is not ruled out', () {
      expect(
        mayHaveDrifted(rowWith(hash: 'h', size: 10, mtimeUtc: noon), null),
        isTrue,
      );
    });

    test('a row with no recorded hash is not ruled out', () {
      expect(
        mayHaveDrifted(
          rowWith(size: 10, mtimeUtc: noon),
          FileFingerprint(size: 10, mtimeUtc: noon),
        ),
        isTrue,
      );
    });

    test('a row with no recorded size or mtime is not ruled out', () {
      // Missing information costs a hash rather than a missed edit.
      expect(
        mayHaveDrifted(
          rowWith(hash: 'h', mtimeUtc: noon),
          FileFingerprint(size: 10, mtimeUtc: noon),
        ),
        isTrue,
      );
      expect(
        mayHaveDrifted(
          rowWith(hash: 'h', size: 10),
          FileFingerprint(size: 10, mtimeUtc: noon),
        ),
        isTrue,
      );
    });
  });

  group('FileFingerprint', () {
    test('equal fingerprints are equal', () {
      expect(
        FileFingerprint(size: 1, mtimeUtc: noon),
        FileFingerprint(size: 1, mtimeUtc: noon),
      );
    });

    test('each field participates in equality', () {
      expect(
        FileFingerprint(size: 1, mtimeUtc: noon),
        isNot(FileFingerprint(size: 2, mtimeUtc: noon)),
      );
      expect(
        FileFingerprint(size: 1, mtimeUtc: noon),
        isNot(
          FileFingerprint(size: 1, mtimeUtc: noon.add(const Duration(days: 1))),
        ),
      );
    });

    test('toString names both halves', () {
      expect(
        FileFingerprint(size: 12, mtimeUtc: noon).toString(),
        allOf(contains('12'), contains('2026')),
      );
    });
  });
}

/// A store that streams in fixed chunks and refuses to hand over a whole
/// file: what proves a digest never loaded one.
class _ChunkedStore extends EngramStore {
  _ChunkedStore(this.files, {required this.chunkSize});

  final Map<String, Uint8List> files;
  final int chunkSize;
  final List<String> reads = [];

  @override
  Future<List<String>> list() async => files.keys.toList();

  @override
  Future<Uint8List> readBytes(String path) =>
      throw StateError('readBytes($path): a blob is never read whole');

  @override
  Stream<List<int>> openRead(String path) async* {
    reads.add(path);
    final bytes = files[path]!;
    for (var i = 0; i < bytes.length; i += chunkSize) {
      final end = i + chunkSize > bytes.length ? bytes.length : i + chunkSize;
      yield bytes.sublist(i, end);
    }
  }

  @override
  Future<void> writeBytes(String path, Uint8List bytes) async {}
}

/// A store with only [readBytes]: the base class's default [openRead].
class _WholeStore extends EngramStore {
  _WholeStore(this.files);

  final Map<String, Uint8List> files;

  @override
  Future<List<String>> list() async => files.keys.toList();

  @override
  Future<Uint8List> readBytes(String path) async => files[path]!;

  @override
  Future<void> writeBytes(String path, Uint8List bytes) async {}
}
