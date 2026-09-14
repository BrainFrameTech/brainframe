import 'dart:typed_data';

import 'package:brainframe/engram/engram_store.dart';
import 'package:brainframe/engram/fs/folder_preview.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Uint8List text(int length, {int? crAt}) {
    final bytes = Uint8List.fromList(List.filled(length, 0x61));
    if (crAt != null) bytes[crAt] = 0x0d;
    return bytes;
  }

  group('hasCarriageReturn', () {
    test('is false for an empty stream', () async {
      expect(await hasCarriageReturn(const Stream<List<int>>.empty()), isFalse);
    });

    test('finds one on a chunk boundary', () async {
      final chunks = Stream<List<int>>.fromIterable([
        [0x61, 0x62],
        [0x0d, 0x0a],
      ]);
      expect(await hasCarriageReturn(chunks), isTrue);
    });
  });

  group('countCrlfTextFiles', () {
    test('counts a CRLF file larger than a chunk without reading it whole',
        () async {
      // #152: the store refuses to hand over a whole file, and the answer
      // is found in the first chunk, so the rest is never pulled.
      final store = _ChunkedStore(
        {'a.md': text(1000, crAt: 10)},
        chunkSize: 100,
      );

      expect(await countCrlfTextFiles(store, ['a.md']), 1);
      expect(store.chunksYielded['a.md'], 1, reason: 'left at the first \\r');
    });

    test('a file whose only \\r is in its last chunk is still counted',
        () async {
      final store = _ChunkedStore(
        {'a.md': text(1000, crAt: 999)},
        chunkSize: 100,
      );

      expect(await countCrlfTextFiles(store, ['a.md']), 1);
      expect(store.chunksYielded['a.md'], 10, reason: 'read to the end');
    });

    test('an LF file is passed over once, and a blob is never opened',
        () async {
      final store = _ChunkedStore(
        {
          'lf.md': text(250),
          'pic.png': text(250, crAt: 0),
          'notes.txt': text(250, crAt: 200),
        },
        chunkSize: 100,
      );

      expect(
        await countCrlfTextFiles(store, ['lf.md', 'pic.png', 'notes.txt']),
        1,
      );
      expect(store.chunksYielded['lf.md'], 3);
      expect(store.chunksYielded.containsKey('pic.png'), isFalse);
    });

    test('reports every file as one step, a blob included', () async {
      final store = _ChunkedStore(
        {'a.md': text(10), 'b.png': text(10), 'c.md': text(10, crAt: 0)},
        chunkSize: 100,
      );
      final steps = <(int, int)>[];

      await countCrlfTextFiles(
        store,
        ['a.md', 'b.png', 'c.md'],
        onProgress: (done, total) => steps.add((done, total)),
      );

      expect(steps, [(0, 3), (1, 3), (2, 3), (3, 3)]);
    });

    test('stops between files when told to, with the count so far', () async {
      final store = _ChunkedStore(
        {
          'a.md': text(10, crAt: 0),
          'b.md': text(10, crAt: 0),
          'c.md': text(10, crAt: 0),
        },
        chunkSize: 100,
      );
      var seen = 0;

      final count = await countCrlfTextFiles(
        store,
        ['a.md', 'b.md', 'c.md'],
        onProgress: (done, _) => seen = done,
        isCancelled: () => seen == 2,
      );

      expect(count, 2);
      expect(store.chunksYielded.keys, ['a.md', 'b.md'], reason: 'c never');
    });

    test('a store with no stream of its own still counts', () async {
      // The base class delivers readBytes as one chunk: correct, if not
      // memory-bounded, for a backend that has no streaming primitive.
      final store = _WholeStore({'a.md': text(10, crAt: 5), 'b.md': text(10)});
      expect(await countCrlfTextFiles(store, ['a.md', 'b.md']), 1);
    });
  });
}

/// A store that streams in fixed chunks and refuses to hand over a whole
/// file, counting the chunks each path actually yielded: what proves the
/// preview never loaded one and stopped where it could.
class _ChunkedStore extends EngramStore {
  _ChunkedStore(this.files, {required this.chunkSize});

  final Map<String, Uint8List> files;
  final int chunkSize;
  final Map<String, int> chunksYielded = {};

  @override
  Future<List<String>> list() async => files.keys.toList();

  @override
  Future<Uint8List> readBytes(String path) =>
      throw StateError('readBytes($path): the preview never reads a file whole');

  @override
  Stream<List<int>> openRead(String path) async* {
    final bytes = files[path]!;
    for (var i = 0; i < bytes.length; i += chunkSize) {
      final end = i + chunkSize > bytes.length ? bytes.length : i + chunkSize;
      chunksYielded[path] = (chunksYielded[path] ?? 0) + 1;
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
