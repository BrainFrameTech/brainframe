import 'dart:async';
import 'dart:io';

import 'package:brainframe/engram/watch/engram_watcher.dart';
import 'package:brainframe/engram/watch/engram_watcher_io.dart';
import 'package:flutter_test/flutter_test.dart';

/// The platform watchers of the filesystem watcher design, Decision 2.
void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('brainframe_watch'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// Waits for the watcher to report [expected], among whatever else.
  Future<void> sees(EngramWatcher watcher, EngramWatchEvent expected) =>
      expectLater(
        watcher.events,
        emitsThrough(expected),
      ).timeout(const Duration(seconds: 5));

  group('DirectoryTreeWatcher, over real directories (inotify)', () {
    // inotify is Linux's, and so is this implementation's shape: elsewhere
    // the factory picks the recursive watcher, tested below.
    final skip = Platform.isLinux ? false : 'inotify is Linux-only';

    test('a file saved in place is a modification', () async {
      File('${root.path}/a.md').writeAsStringSync('one\n');
      final watcher = DirectoryTreeWatcher(root.path);
      addTearDown(watcher.stop);
      await watcher.start();

      final seen = sees(watcher, const EngramWatchEvent.modified('a.md'));
      File('${root.path}/a.md').writeAsStringSync('two\n');
      await seen;
    }, skip: skip);

    test('a file created is a listing change', () async {
      final watcher = DirectoryTreeWatcher(root.path);
      addTearDown(watcher.stop);
      await watcher.start();

      final seen = sees(watcher, const EngramWatchEvent.listing('new.md'));
      File('${root.path}/new.md').writeAsStringSync('hi\n');
      await seen;
    }, skip: skip);

    test('a directory already there is watched, a hidden one is not', () async {
      Directory('${root.path}/notes/deep').createSync(recursive: true);
      for (final name in ['00', '01', 'ab', 'ff']) {
        Directory(
          '${root.path}/.git/objects/$name',
        ).createSync(recursive: true);
      }
      Directory('${root.path}/.brainframe/shared').createSync(recursive: true);
      final watcher = DirectoryTreeWatcher(root.path);
      addTearDown(watcher.stop);
      await watcher.start();

      // The root, notes and notes/deep: not one watch spent on a dot.
      expect(watcher.watchCount, 3);
      final seen = sees(
        watcher,
        const EngramWatchEvent.listing('notes/deep/x.md'),
      );
      File('${root.path}/notes/deep/x.md').writeAsStringSync('x\n');
      await seen;
    }, skip: skip);

    test('a directory created later is followed', () async {
      final watcher = DirectoryTreeWatcher(root.path);
      addTearDown(watcher.stop);
      await watcher.start();

      final created = sees(watcher, const EngramWatchEvent.listing('later'));
      Directory('${root.path}/later').createSync();
      await created;
      // Its watch is placed asynchronously; wait until it is there.
      await _until(() => watcher.watchCount == 2);

      final inside = sees(
        watcher,
        const EngramWatchEvent.listing('later/x.md'),
      );
      File('${root.path}/later/x.md').writeAsStringSync('x\n');
      await inside;
    }, skip: skip);

    test('a hidden directory created later is not followed', () async {
      final watcher = DirectoryTreeWatcher(root.path);
      addTearDown(watcher.stop);
      await watcher.start();

      final created = sees(watcher, const EngramWatchEvent.listing('.trash'));
      Directory('${root.path}/.trash').createSync();
      await created;
      await Future<void>.delayed(const Duration(milliseconds: 100));

      expect(watcher.watchCount, 1);
    }, skip: skip);

    test('a directory deleted stops being watched', () async {
      Directory('${root.path}/old/inner').createSync(recursive: true);
      final watcher = DirectoryTreeWatcher(root.path);
      addTearDown(watcher.stop);
      await watcher.start();
      expect(watcher.watchCount, 3);

      final gone = sees(watcher, const EngramWatchEvent.listing('old'));
      Directory('${root.path}/old').deleteSync(recursive: true);
      await gone;
      await _until(() => watcher.watchCount == 1);
    }, skip: skip);

    test('a directory moved is followed to where it went', () async {
      Directory('${root.path}/from').createSync();
      final watcher = DirectoryTreeWatcher(root.path);
      addTearDown(watcher.stop);
      await watcher.start();

      final moved = sees(watcher, const EngramWatchEvent.listing('to'));
      Directory('${root.path}/from').renameSync('${root.path}/to');
      await moved;
      await _until(() => watcher.watchCount == 2);

      final inside = sees(watcher, const EngramWatchEvent.listing('to/x.md'));
      File('${root.path}/to/x.md').writeAsStringSync('x\n');
      await inside;
    }, skip: skip);

    test('the folder itself deleted ends the watcher', () async {
      final watcher = DirectoryTreeWatcher(root.path);
      await watcher.start();

      final ended = expectLater(
        watcher.events,
        emitsThrough(emitsError(isA<EngramWatchUnavailable>())),
      ).timeout(const Duration(seconds: 5));
      root.deleteSync(recursive: true);
      await ended;
      expect(watcher.watchCount, 0);
    }, skip: skip);

    test('stop releases every watch', () async {
      Directory('${root.path}/a/b').createSync(recursive: true);
      final watcher = DirectoryTreeWatcher(root.path);
      await watcher.start();
      expect(watcher.watchCount, 3);

      await watcher.stop();
      await watcher.stop();

      expect(watcher.watchCount, 0);
    }, skip: skip);
  });

  group('DirectoryTreeWatcher, with the watches injected', () {
    test('a folder that is not there cannot be watched', () async {
      final watcher = DirectoryTreeWatcher(
        '${root.path}/missing',
        watchDirectory: (_) => const Stream.empty(),
      );

      await expectLater(
        watcher.start(),
        throwsA(isA<EngramWatchUnavailable>()),
      );
      expect(watcher.watchCount, 0);
    });

    test('a watch that cannot be placed ends the watcher, whole', () async {
      // The inotify limit reached: "No space left on device", errno 28.
      Directory('${root.path}/a').createSync();
      final watches = <String, StreamController<FileSystemEvent>>{};
      final watcher = DirectoryTreeWatcher(
        root.path,
        watchDirectory: (directory) =>
            (watches[directory.path] = StreamController<FileSystemEvent>())
                .stream,
      );
      await watcher.start();
      expect(watcher.watchCount, 2);

      final ended = expectLater(
        watcher.events,
        emitsError(isA<EngramWatchUnavailable>()),
      );
      watches['${root.path}/a']!.addError(
        const FileSystemException(
          'Failed to watch path',
          '',
          OSError('No space left on device', 28),
        ),
      );
      await ended;
      expect(watcher.watchCount, 0, reason: 'none kept watching part of it');
    });

    test('events are made engram-relative and sorted by kind', () async {
      final rootWatch = StreamController<FileSystemEvent>();
      final watcher = DirectoryTreeWatcher(
        root.path,
        watchDirectory: (directory) => directory.path == root.path
            ? rootWatch.stream
            : const Stream.empty(),
      );
      await watcher.start();
      final seen = <EngramWatchEvent>[];
      final subscription = watcher.events.listen(seen.add);
      addTearDown(subscription.cancel);

      final r = root.path;
      rootWatch
        ..add(FileSystemModifyEvent('$r/a.md', false, true))
        ..add(FileSystemModifyEvent('$r/dir', true, false))
        ..add(FileSystemModifyEvent(r, true, false))
        ..add(FileSystemDeleteEvent('$r/b.md', false))
        ..add(FileSystemMoveEvent('$r/c.md', false, '$r/d.md'))
        ..add(FileSystemMoveEvent('$r/e.md', false, null));
      await Future<void>.delayed(Duration.zero);

      expect(seen, const [
        EngramWatchEvent.modified('a.md'),
        EngramWatchEvent.listing('b.md'),
        EngramWatchEvent.listing('c.md'),
        EngramWatchEvent.listing('d.md'),
        EngramWatchEvent.listing('e.md'),
      ]);
    });

    test(
      'a directory gone before it could be listed is not a failure',
      () async {
        final rootWatch = StreamController<FileSystemEvent>();
        final watcher = DirectoryTreeWatcher(
          root.path,
          watchDirectory: (directory) => directory.path == root.path
              ? rootWatch.stream
              : const Stream.empty(),
        );
        await watcher.start();
        final errors = <Object>[];
        final subscription = watcher.events.listen(null, onError: errors.add);
        addTearDown(subscription.cancel);

        // Reported created, but already gone again when it is listed.
        rootWatch.add(FileSystemCreateEvent('${root.path}/fleeting', true));
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(errors, isEmpty);
        expect(watcher.watchCount, 1);
      },
    );
  });

  group('DirectoryTreeWatcher, following the tree by its events', () {
    late StreamController<FileSystemEvent> rootWatch;

    DirectoryTreeWatcher injected() {
      rootWatch = StreamController<FileSystemEvent>();
      return DirectoryTreeWatcher(
        root.path,
        watchDirectory: (directory) => directory.path == root.path
            ? rootWatch.stream
            : StreamController<FileSystemEvent>().stream,
      );
    }

    test('a directory reported deleted takes its watches with it', () async {
      Directory('${root.path}/sub/inner').createSync(recursive: true);
      final watcher = injected();
      await watcher.start();
      expect(watcher.watchCount, 3);

      // Reported as a file, as the SDK reports every deletion.
      rootWatch.add(FileSystemDeleteEvent('${root.path}/sub', false));
      await Future<void>.delayed(Duration.zero);

      expect(watcher.watchCount, 1);
    });

    test(
      'a new directory that cannot be listed ends the watcher',
      () async {
        final watcher = injected();
        await watcher.start();
        final errors = <Object>[];
        final subscription = watcher.events.listen(null, onError: errors.add);
        addTearDown(subscription.cancel);
        // Made after the watch starts: there, but unreadable — not a
        // directory that vanished, a real failure.
        final locked = Directory('${root.path}/locked')..createSync();
        Process.runSync('chmod', ['000', locked.path]);
        addTearDown(() => Process.runSync('chmod', ['755', locked.path]));

        rootWatch.add(FileSystemCreateEvent(locked.path, true));
        await _until(() => errors.isNotEmpty);

        expect(errors.single, isA<EngramWatchUnavailable>());
        expect(watcher.watchCount, 0);
      },
      skip: Platform.isWindows ? 'POSIX permissions' : false,
    );
  });

  group('RecursiveWatcher, with the watch injected', () {
    late List<StreamController<FileSystemEvent>> watches;

    RecursiveWatcher recursive({int maxRestarts = 3}) {
      watches = [];
      return RecursiveWatcher(
        root.path,
        maxRestarts: maxRestarts,
        watchRoot: () {
          final watch = StreamController<FileSystemEvent>();
          watches.add(watch);
          return watch.stream;
        },
      );
    }

    test('events are made engram-relative and sorted by kind', () async {
      final watcher = recursive();
      await watcher.start();
      final seen = <EngramWatchEvent>[];
      final subscription = watcher.events.listen(seen.add);
      addTearDown(subscription.cancel);

      final r = root.path;
      watches.single
        ..add(FileSystemModifyEvent('$r/notes/a.md', false, true))
        ..add(FileSystemModifyEvent('$r/notes', true, false))
        ..add(FileSystemModifyEvent(r, true, false))
        ..add(FileSystemCreateEvent('$r/.git/objects/ab', true))
        ..add(FileSystemMoveEvent('$r/c.md', false, '$r/sub/c.md'));
      await Future<void>.delayed(Duration.zero);

      // Hidden paths are passed on: the dispatcher drops them.
      expect(seen, const [
        EngramWatchEvent.modified('notes/a.md'),
        EngramWatchEvent.listing('.git/objects/ab'),
        EngramWatchEvent.listing('c.md'),
        EngramWatchEvent.listing('sub/c.md'),
      ]);
    });

    test('a watch that fails is re-established, and asks for a scan', () async {
      // A Windows buffer overflow is the ordinary case.
      final watcher = recursive();
      await watcher.start();
      final seen = <EngramWatchEvent>[];
      final subscription = watcher.events.listen(seen.add);
      addTearDown(subscription.cancel);

      watches.single.addError(const FileSystemException('overflow'));
      await Future<void>.delayed(Duration.zero);
      expect(seen, const [EngramWatchEvent.lost()]);
      expect(watches, hasLength(2));

      await watches.last.close(); // ended: the same again
      await Future<void>.delayed(Duration.zero);
      expect(seen, const [EngramWatchEvent.lost(), EngramWatchEvent.lost()]);
      expect(watches, hasLength(3));
    });

    test('a watch that cannot be kept ends the watcher', () async {
      final watcher = recursive(maxRestarts: 2);
      await watcher.start();
      final errors = <Object>[];
      final subscription = watcher.events.listen(null, onError: errors.add);
      addTearDown(subscription.cancel);

      for (var i = 0; i < 3; i++) {
        watches.last.addError(const FileSystemException('overflow'));
        await Future<void>.delayed(Duration.zero);
      }

      expect(errors.single, isA<EngramWatchUnavailable>());
      expect(watches, hasLength(3), reason: 'two restarts, then no more');
    });

    test('an event between failures resets the count', () async {
      final watcher = recursive(maxRestarts: 1);
      await watcher.start();
      final errors = <Object>[];
      final subscription = watcher.events.listen(null, onError: errors.add);
      addTearDown(subscription.cancel);

      for (var i = 0; i < 3; i++) {
        watches.last.addError(const FileSystemException('overflow'));
        await Future<void>.delayed(Duration.zero);
        watches.last.add(
          FileSystemModifyEvent('${root.path}/a.md', false, true),
        );
        await Future<void>.delayed(Duration.zero);
      }

      expect(errors, isEmpty);
    });

    test('a folder that is gone is not watched again', () async {
      final watcher = recursive();
      await watcher.start();
      final errors = <Object>[];
      final subscription = watcher.events.listen(null, onError: errors.add);
      addTearDown(subscription.cancel);

      root.deleteSync(recursive: true);
      await watches.single.close();
      await Future<void>.delayed(Duration.zero);

      expect(errors.single, isA<EngramWatchUnavailable>());
      expect(watches, hasLength(1));
    });

    test('stopped, it hears nothing and restarts nothing', () async {
      final watcher = recursive();
      await watcher.start();
      await watcher.start(); // already running: nothing more
      expect(watches, hasLength(1));
      final seen = <EngramWatchEvent>[];
      final subscription = watcher.events.listen(seen.add);
      addTearDown(subscription.cancel);

      await watcher.stop();
      watches.single.add(
        FileSystemModifyEvent('${root.path}/a.md', false, true),
      );
      await Future<void>.delayed(Duration.zero);

      expect(seen, isEmpty);
      expect(watches, hasLength(1));
    });
  });

  group('choosing a watcher', () {
    test('this platform gets the watcher its primitive supports', () {
      final watcher = engramWatcherFor(root.path);
      if (!FileSystemEntity.isWatchSupported) {
        expect(watcher, isNull);
      } else if (Platform.isLinux || Platform.isAndroid) {
        expect(watcher, isA<DirectoryTreeWatcher>());
      } else if (Platform.isMacOS || Platform.isWindows) {
        expect(watcher, isA<RecursiveWatcher>());
      } else {
        expect(watcher, isNull);
      }
    });

    test('paths are made engram-relative whatever the separator', () {
      expect(relativeToRoot('/e', '/e/notes/a.md'), 'notes/a.md');
      expect(relativeToRoot('/e', '/e'), '');
      expect(relativeToRoot(r'C:\e', r'C:\e\notes\a.md'), 'notes/a.md');
    });
  });
}

/// Polls [condition] until it holds, failing after a few seconds.
Future<void> _until(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) fail('condition never held');
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
