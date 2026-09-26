import 'dart:convert';
import 'dart:typed_data';

import 'package:brainframe/engram/engram_store.dart';
import 'package:brainframe/engram/note_writer.dart';
import 'package:flutter_test/flutter_test.dart';

/// The seam the editor saves through, and the implementation that writes
/// straight to the store.
void main() {
  group('DirectNoteWriter', () {
    test('writes the text to the store at the given path', () async {
      final store = _RecordingStore();

      await DirectNoteWriter(store).write('inbox/today.md', '# Today\n');

      expect(store.writes, {'inbox/today.md': '# Today\n'});
    });

    test('a failing store surfaces its error', () async {
      // The controller relies on this: a throw is what turns the status to
      // error and leaves the buffer dirty for the next flush to retry.
      final store = _RecordingStore(fail: true);

      expect(
        () => DirectNoteWriter(store).write('a.md', 'x'),
        throwsA(isA<Exception>()),
      );
    });

    test('a second write to one path replaces the first', () async {
      final store = _RecordingStore();
      final writer = DirectNoteWriter(store);

      await writer.write('a.md', 'first');
      await writer.write('a.md', 'second');

      expect(store.writes['a.md'], 'second');
    });
  });

  group('DirectNoteWriter looks before it writes (watcher Decision 5)', () {
    test('a file as the buffer left it is written over, as given', () async {
      final store = _RecordingStore()..writes['a.md'] = 'one\n';

      final saved = await DirectNoteWriter(
        store,
      ).write('a.md', 'one!\n', base: 'one\n');

      expect(saved, 'one!\n');
      expect(store.writes['a.md'], 'one!\n');
    });

    test('a file changed since is merged with, not written over', () async {
      final store = _RecordingStore()..writes['a.md'] = 'one\ntwo\nthree\n';

      final saved = await DirectNoteWriter(
        store,
      ).write('a.md', 'ONE\ntwo\n', base: 'one\ntwo\n');

      expect(saved, 'ONE\ntwo\nthree\n');
      expect(store.writes['a.md'], 'ONE\ntwo\nthree\n');
    });

    test('a file that differs only in line endings is not a change', () async {
      final store = _RecordingStore()..writes['a.md'] = 'one\r\n';

      final saved = await DirectNoteWriter(
        store,
      ).write('a.md', 'one!\r\n', base: 'one\n');

      expect(saved, 'one!\r\n', reason: 'nothing to merge; the buffer wins');
    });

    test('no file yet is nothing to merge with', () async {
      final store = _RecordingStore();

      final saved = await DirectNoteWriter(
        store,
      ).write('new.md', 'typed\n', base: '');

      expect(saved, 'typed\n');
      expect(store.writes['new.md'], 'typed\n');
    });

    test('a refused merge says which note, and that nothing was written', () {
      const e = NoteMergeOverLimitException(
        path: 'a.md',
        merged: 'merged',
        onDisk: 'external',
      );

      expect(e.toString(), contains('a.md'));
      expect(e.toString(), contains('nothing was written'));
    });

    test('without a base, the file is not read at all', () async {
      final store = _RecordingStore()..writes['a.md'] = 'changed outside\n';

      final saved = await DirectNoteWriter(store).write('a.md', 'mine\n');

      expect(saved, 'mine\n');
      expect(store.reads, 0);
    });
  });
}

class _RecordingStore extends EngramStore {
  _RecordingStore({this.fail = false});

  final bool fail;
  final Map<String, String> writes = {};
  int reads = 0;

  @override
  Future<List<String>> list() async => writes.keys.toList();

  /// What was written, and an absent path for anything that was not.
  @override
  Future<Uint8List> readBytes(String path) async {
    reads++;
    final text = writes[path];
    if (text == null) throw Exception('no file at $path');
    return Uint8List.fromList(utf8.encode(text));
  }

  @override
  Future<void> writeBytes(String path, Uint8List bytes) async {
    if (fail) throw Exception('write failed');
    writes[path] = utf8.decode(bytes);
  }
}
