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
}

class _RecordingStore extends EngramStore {
  _RecordingStore({this.fail = false});

  final bool fail;
  final Map<String, String> writes = {};

  @override
  Future<List<String>> list() async => writes.keys.toList();

  @override
  Future<Uint8List> readBytes(String path) =>
      throw UnimplementedError('not needed');

  @override
  Future<void> writeBytes(String path, Uint8List bytes) async {
    if (fail) throw Exception('write failed');
    writes[path] = utf8.decode(bytes);
  }
}
