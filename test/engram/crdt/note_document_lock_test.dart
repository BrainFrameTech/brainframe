import 'dart:async';

import 'package:brainframe/engram/crdt/note_document_lock.dart';
import 'package:flutter_test/flutter_test.dart';

/// The turnstile that keeps one NoteDocument open at a time.
void main() {
  test('actions run one at a time, in queue order', () async {
    final lock = NoteDocumentLock();
    final log = <String>[];
    final gate = Completer<void>();

    final first = lock.run(() async {
      log.add('first start');
      await gate.future;
      log.add('first end');
    });
    final second = lock.run(() async {
      log.add('second start');
      log.add('second end');
    });
    await Future<void>.delayed(Duration.zero);

    expect(log, ['first start'], reason: 'second waits on first');
    gate.complete();
    await Future.wait([first, second]);
    expect(log, ['first start', 'first end', 'second start', 'second end']);
  });

  test('returns the action result', () async {
    final lock = NoteDocumentLock();
    expect(await lock.run(() async => 42), 42);
  });

  test(
    'a failing action releases the lock and fails only its caller',
    () async {
      final lock = NoteDocumentLock();

      final failing = lock.run<void>(() async => throw StateError('boom'));
      final next = lock.run(() async => 'ran');

      await expectLater(failing, throwsStateError);
      expect(await next, 'ran');
    },
  );
}
