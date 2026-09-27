import 'dart:async';

import 'package:brainframe/engram/note_reconciler.dart';
import 'package:brainframe/engram/watch/engram_watcher.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

/// The dispatcher of the filesystem watcher design, Decision 3: hints in,
/// the existing scan and reconcile out, batched.
void main() {
  late _FakeWatcher watcher;
  late _RecordingReconciler reconciler;
  late Set<String> tracked;

  WatchDispatcher dispatcher() => WatchDispatcher(
    watcher: watcher,
    reconciler: reconciler,
    isTracked: tracked.contains,
  );

  setUp(() {
    watcher = _FakeWatcher();
    reconciler = _RecordingReconciler();
    tracked = {'a.md', 'b.md', 'notes/c.md'};
  });

  group('batching', () {
    test('a batch waits for quiet, then reconciles each note once', () {
      fakeAsync((async) {
        final d = dispatcher();
        d.start();
        async.flushMicrotasks();

        watcher.emit(const EngramWatchEvent.modified('a.md'));
        watcher.emit(const EngramWatchEvent.modified('a.md'));
        watcher.emit(const EngramWatchEvent.modified('b.md'));
        async.elapse(watchQuietPeriod - const Duration(milliseconds: 1));
        expect(reconciler.log, isEmpty, reason: 'still inside the quiet');

        async.elapse(const Duration(milliseconds: 1));
        async.flushMicrotasks();
        expect(reconciler.log, ['reconcile a.md', 'reconcile b.md']);
      });
    });

    test('a steady stream still dispatches at the cap', () {
      fakeAsync((async) {
        final d = dispatcher();
        d.start();
        async.flushMicrotasks();

        // An event every 200 ms never leaves a 250 ms quiet.
        for (var i = 0; i < 12; i++) {
          watcher.emit(const EngramWatchEvent.modified('a.md'));
          async.elapse(const Duration(milliseconds: 200));
        }
        async.flushMicrotasks();

        expect(reconciler.log, ['reconcile a.md'], reason: 'once, at 2 s');
      });
    });

    test('batches are dispatched one after another, never together', () {
      fakeAsync((async) {
        final gate = Completer<void>();
        reconciler.gate = gate.future;
        final d = dispatcher();
        d.start();
        async.flushMicrotasks();

        watcher.emit(const EngramWatchEvent.modified('a.md'));
        async.elapse(watchQuietPeriod);
        watcher.emit(const EngramWatchEvent.modified('b.md'));
        async.elapse(watchQuietPeriod);
        async.flushMicrotasks();
        expect(reconciler.log, ['reconcile a.md'], reason: 'b waits for a');

        gate.complete();
        async.flushMicrotasks();
        expect(reconciler.log, ['reconcile a.md', 'reconcile b.md']);
      });
    });
  });

  group('what a batch turns into', () {
    test('a listing change is one scan, under the watcher trigger', () {
      fakeAsync((async) {
        final d = dispatcher();
        d.start();
        async.flushMicrotasks();

        watcher.emit(const EngramWatchEvent.listing('new.md'));
        watcher.emit(const EngramWatchEvent.listing('gone.md'));
        watcher.emit(const EngramWatchEvent.modified('a.md'));
        async.elapse(watchQuietPeriod);
        async.flushMicrotasks();

        // The scan covers the modification too; it is not reconciled apart.
        expect(reconciler.log, ['scan watcher']);
      });
    });

    test('a lost watch is a scan', () {
      fakeAsync((async) {
        final d = dispatcher();
        d.start();
        async.flushMicrotasks();

        watcher.emit(const EngramWatchEvent.lost());
        async.elapse(watchQuietPeriod);
        async.flushMicrotasks();

        expect(reconciler.log, ['scan watcher']);
      });
    });

    test('a modification of a path the catalog does not know is a scan', () {
      // It may be half of a move, which only the whole folder can pair.
      fakeAsync((async) {
        final d = dispatcher();
        d.start();
        async.flushMicrotasks();

        watcher.emit(const EngramWatchEvent.modified('a.md'));
        watcher.emit(const EngramWatchEvent.modified('untracked.md'));
        async.elapse(watchQuietPeriod);
        async.flushMicrotasks();

        expect(reconciler.log, ['scan watcher']);
      });
    });

    test('hidden paths are dropped before anything is decided', () {
      // The app's own settings, map and temp writes all live under dots.
      fakeAsync((async) {
        final d = dispatcher();
        d.start();
        async.flushMicrotasks();

        watcher.emit(const EngramWatchEvent.modified('.brainframe/x.json'));
        watcher.emit(const EngramWatchEvent.listing('notes/.a.md.bf-tmp'));
        watcher.emit(const EngramWatchEvent.listing('.git/objects/ab/cd'));
        async.elapse(watchBatchCap);
        async.flushMicrotasks();

        expect(reconciler.log, isEmpty);
      });
    });

    test('a failure is logged, and the next batch still runs', () {
      fakeAsync((async) {
        reconciler.fail = true;
        final d = dispatcher();
        d.start();
        async.flushMicrotasks();

        watcher.emit(const EngramWatchEvent.modified('a.md'));
        async.elapse(watchQuietPeriod);
        async.flushMicrotasks();
        reconciler.fail = false;
        watcher.emit(const EngramWatchEvent.listing('new.md'));
        async.elapse(watchQuietPeriod);
        async.flushMicrotasks();

        expect(reconciler.log, ['reconcile a.md', 'scan watcher']);
      });
    });
  });

  group('lifetime', () {
    // These two await a subscription's cancel, whose already-complete future
    // lives in the root zone and so never completes under fake time; they run
    // on the real clock instead, with the batch timings shortened to match.
    const quiet = Duration(milliseconds: 10);
    const cap = Duration(milliseconds: 20);
    const waitOut = Duration(milliseconds: 60);

    WatchDispatcher quick() => WatchDispatcher(
      watcher: watcher,
      reconciler: reconciler,
      isTracked: tracked.contains,
      quietPeriod: quiet,
      batchCap: cap,
    );

    test(
      'a watcher that cannot start is reported, and nothing listens',
      () async {
        watcher.startError = const EngramWatchUnavailable('no watching here');
        final d = quick();

        await expectLater(d.start(), throwsA(isA<EngramWatchUnavailable>()));

        watcher.emit(const EngramWatchEvent.lost());
        await Future<void>.delayed(waitOut);
        expect(reconciler.log, isEmpty);
      },
    );

    test('a watch that dies is recorded as the failure', () {
      fakeAsync((async) {
        final d = dispatcher();
        d.start();
        async.flushMicrotasks();
        expect(d.failure, isNull);

        watcher.fail(StateError('inotify gave up'));
        async.flushMicrotasks();

        expect(d.failure, isA<EngramWatchUnavailable>());
        expect(d.failure!.cause, isA<StateError>());
      });
    });

    test('an unavailable error is recorded as it is', () {
      fakeAsync((async) {
        final d = dispatcher();
        d.start();
        async.flushMicrotasks();
        const reason = EngramWatchUnavailable('limit reached');

        watcher.fail(reason);
        async.flushMicrotasks();

        expect(d.failure, same(reason));
      });
    });

    test('stop drops the pending batch and stops the watcher, once', () async {
      final d = quick();
      await d.start();
      watcher.emit(const EngramWatchEvent.modified('a.md'));

      await d.stop();
      await d.stop();
      await Future<void>.delayed(waitOut);

      expect(reconciler.log, isEmpty);
      expect(watcher.stops, 1);
      watcher.emit(const EngramWatchEvent.lost());
      watcher.fail(StateError('after stop'));
      await Future<void>.delayed(waitOut);
      expect(reconciler.log, isEmpty);
      expect(d.failure, isNull);
    });

    test('work stopped mid-batch goes no further', () {
      fakeAsync((async) {
        final gate = Completer<void>();
        reconciler.gate = gate.future;
        final d = dispatcher();
        d.start();
        async.flushMicrotasks();
        watcher.emit(const EngramWatchEvent.modified('a.md'));
        watcher.emit(const EngramWatchEvent.modified('b.md'));
        async.elapse(watchQuietPeriod);
        async.flushMicrotasks();

        d.stop();
        gate.complete();
        async.flushMicrotasks();

        expect(reconciler.log, ['reconcile a.md'], reason: 'b not started');
        var idle = false;
        d.idle.then((_) => idle = true);
        async.flushMicrotasks();
        expect(idle, isTrue);
      });
    });
  });

  group('the event and the failure', () {
    test('events compare by kind and path, and say what they are', () {
      expect(
        const EngramWatchEvent.modified('a.md'),
        const EngramWatchEvent.modified('a.md'),
      );
      expect(
        const EngramWatchEvent.modified('a.md'),
        isNot(const EngramWatchEvent.listing('a.md')),
      );
      expect(
        const EngramWatchEvent.lost().hashCode,
        const EngramWatchEvent.lost().hashCode,
      );
      expect(
        const EngramWatchEvent.listing('a.md').toString(),
        'EngramWatchEvent.listing(a.md)',
      );
      expect(const EngramWatchEvent.lost().toString(), contains('lost'));
    });

    test('the failure names its reason and its cause', () {
      expect(
        const EngramWatchUnavailable('limit').toString(),
        'EngramWatchUnavailable: limit',
      );
      expect(
        EngramWatchUnavailable('limit', cause: StateError('x')).toString(),
        contains('Bad state: x'),
      );
    });
  });
}

class _FakeWatcher implements EngramWatcher {
  final StreamController<EngramWatchEvent> _events =
      StreamController<EngramWatchEvent>.broadcast(sync: true);
  EngramWatchUnavailable? startError;
  int stops = 0;

  void emit(EngramWatchEvent event) => _events.add(event);

  void fail(Object error) => _events.addError(error);

  @override
  Stream<EngramWatchEvent> get events => _events.stream;

  @override
  Future<void> start() async {
    final error = startError;
    if (error != null) throw error;
  }

  @override
  Future<void> stop() async => stops++;
}

/// Records what the dispatcher asks for; everything else is unused.
class _RecordingReconciler implements NoteReconciler {
  final List<String> log = [];
  Future<void>? gate;
  bool fail = false;

  @override
  Future<DriftScanReport> scan({ScanTrigger trigger = ScanTrigger.manual}) {
    log.add('scan ${trigger.name}');
    return _answer(DriftScanReport.clean);
  }

  @override
  Future<bool> reconcile(String path) {
    log.add('reconcile $path');
    return _answer(true);
  }

  Future<T> _answer<T>(T value) async {
    await gate;
    if (fail) throw StateError('reconciler failed');
    return value;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
