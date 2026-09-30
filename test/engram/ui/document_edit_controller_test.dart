import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:brainframe/commands/pending_saves.dart';
import 'package:brainframe/engram/engram_store.dart';
import 'package:brainframe/engram/note_writer.dart';
import 'package:brainframe/engram/ui/document_edit_controller.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// Records each write as `path::text`, and can be told to fail the next one.
///
/// Reads back what was written, and nothing else: a path it never wrote is
/// absent, which is what the writer's look-before-writing needs to see for a
/// file the test opened with text it never put on disk.
class _RecordingStore extends EngramStore {
  final List<String> writes = [];
  final Map<String, Uint8List> _files = {};
  bool failNext = false;

  @override
  Future<List<String>> list() async => _files.keys.toList();

  @override
  Future<Uint8List> readBytes(String path) async =>
      _files[path] ?? (throw Exception('no file at $path'));

  @override
  Future<void> writeBytes(String path, Uint8List bytes) async {
    if (failNext) {
      failNext = false;
      throw Exception('write failed');
    }
    _files[path] = bytes;
    writes.add('$path::${utf8.decode(bytes)}');
  }
}

DocumentEditController _controller(_RecordingStore store) =>
    DocumentEditController(
      writer: DirectNoteWriter(store),
      observeLifecycle: false,
      idleDebounce: const Duration(seconds: 5),
      maxWait: const Duration(seconds: 30),
    );

void main() {
  group('save pipeline', () {
    test('idle debounce writes once after the pause', () {
      fakeAsync((async) {
        final store = _RecordingStore();
        final c = _controller(store);
        c.openFile('a.md', 'hi');
        c.edit('hi there');
        expect(c.status, SaveStatus.dirty);

        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();

        expect(store.writes, ['a.md::hi there']);
        expect(c.status, SaveStatus.saved);
        expect(c.isDirty, isFalse);
        c.dispose();
      });
    });

    test('the idle timer resets on each keystroke', () {
      fakeAsync((async) {
        final store = _RecordingStore();
        final c = _controller(store);
        c.openFile('a.md', '');
        c.edit('a');
        async.elapse(const Duration(seconds: 4)); // < 5s: no write yet
        c.edit('ab'); // resets the idle timer
        async.elapse(const Duration(seconds: 4)); // 8s total, but only 4s idle
        async.flushMicrotasks();
        expect(store.writes, isEmpty);

        async.elapse(const Duration(seconds: 1)); // now 5s idle since last edit
        async.flushMicrotasks();
        expect(store.writes, ['a.md::ab']);
        c.dispose();
      });
    });

    test('max-wait cap forces a write during continuous typing', () {
      fakeAsync((async) {
        final store = _RecordingStore();
        final c = _controller(store);
        c.openFile('a.md', '');
        // Type every 4s so the 5s idle timer never elapses; the 30s cap must
        // still checkpoint at least once.
        for (var i = 1; i <= 8; i++) {
          c.edit('x' * i);
          async.elapse(const Duration(seconds: 4));
        }
        async.flushMicrotasks();
        expect(store.writes, isNotEmpty);
        c.dispose();
      });
    });

    test('switching files flushes the outgoing file first', () {
      fakeAsync((async) {
        final store = _RecordingStore();
        final c = _controller(store);
        c.openFile('a.md', 'A');
        c.edit('A edited');
        c.openFile('b.md', 'B');
        async.flushMicrotasks();

        expect(store.writes, ['a.md::A edited']);
        expect(c.path, 'b.md');
        expect(c.text, 'B');
        expect(c.status, SaveStatus.saved);
        c.dispose();
      });
    });

    test('re-opening the current file keeps the live buffer', () {
      fakeAsync((async) {
        final store = _RecordingStore();
        final c = _controller(store);
        c.openFile('a.md', 'A');
        c.edit('A2');
        c.openFile('a.md', 'A'); // no-op; must not reset the buffer
        expect(c.text, 'A2');
        expect(c.isDirty, isTrue);
        c.dispose();
      });
    });

    test('app inactive/pause/hide/detach flushes the buffer', () {
      // `inactive` is what a desktop window gets when another window takes
      // focus — the only lifecycle event it gets for that — and a second
      // instance over the same engram scans the moment it is focused.
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.detached,
      ]) {
        fakeAsync((async) {
          final store = _RecordingStore();
          final c = _controller(store);
          c.openFile('a.md', 'A');
          c.edit('A2');
          c.didChangeAppLifecycleState(state);
          async.flushMicrotasks();
          expect(store.writes, ['a.md::A2'], reason: 'flushed on $state');
          c.dispose();
        });
      }
    });

    test('the resumed lifecycle state does not write', () {
      fakeAsync((async) {
        final store = _RecordingStore();
        final c = _controller(store);
        c.openFile('a.md', 'A');
        c.edit('A2');
        c.didChangeAppLifecycleState(AppLifecycleState.resumed);
        async.flushMicrotasks();
        expect(store.writes, isEmpty);
        expect(c.isDirty, isTrue);
        c.dispose();
      });
    });

    test('a failed write sets error and keeps the buffer dirty', () {
      fakeAsync((async) {
        final store = _RecordingStore()..failNext = true;
        final c = _controller(store);
        c.openFile('a.md', 'A');
        c.edit('A2');
        c.flush();
        async.flushMicrotasks();
        expect(c.status, SaveStatus.error);
        expect(c.isDirty, isTrue);
        expect(store.writes, isEmpty);
        c.dispose();
      });
    });

    test('a pending debounce never writes to a switched-away file', () {
      fakeAsync((async) {
        final store = _RecordingStore();
        final c = _controller(store);
        c.openFile('a.md', 'A');
        c.edit('AA'); // idle timer armed for a.md
        c.openFile('b.md', 'B'); // flushes a.md, cancels the timer
        async.flushMicrotasks();
        final afterSwitch = store.writes.length;

        async.elapse(const Duration(seconds: 30)); // any stale timer would fire
        async.flushMicrotasks();

        expect(store.writes.length, afterSwitch);
        expect(store.writes, ['a.md::AA']);
        c.dispose();
      });
    });

    test('editing back to the saved text cancels the pending write', () {
      fakeAsync((async) {
        final store = _RecordingStore();
        final c = _controller(store);
        c.openFile('a.md', 'A');
        c.edit('A changed');
        expect(c.status, SaveStatus.dirty);
        c.edit('A'); // back to on-disk content
        expect(c.status, SaveStatus.saved);

        async.elapse(const Duration(seconds: 30));
        async.flushMicrotasks();
        expect(store.writes, isEmpty);
        c.dispose();
      });
    });

    test('manual flush writes immediately', () {
      fakeAsync((async) {
        final store = _RecordingStore();
        final c = _controller(store);
        c.openFile('a.md', 'A');
        c.edit('A2');
        c.flush();
        async.flushMicrotasks();
        expect(store.writes, ['a.md::A2']);
        expect(c.status, SaveStatus.saved);
        c.dispose();
      });
    });

    test('flush is a no-op when clean', () {
      fakeAsync((async) {
        final store = _RecordingStore();
        final c = _controller(store);
        c.openFile('a.md', 'A');
        c.flush();
        async.flushMicrotasks();
        expect(store.writes, isEmpty);
        c.dispose();
      });
    });

    test('edit before any file is open is ignored', () {
      final store = _RecordingStore();
      final c = _controller(store);
      c.edit('x');
      expect(c.isDirty, isFalse);
      expect(c.status, SaveStatus.saved);
      c.dispose();
    });

    test('notifies on every edit, not only a status change', () {
      // The status bar counts the buffer (ceiling step 21); a run of typing
      // that stays dirty throughout still has to reach it.
      fakeAsync((async) {
        final store = _RecordingStore();
        final c = _controller(store);
        c.openFile('a.md', 'A');
        var notifications = 0;
        c.addListener(() => notifications++);

        c.edit('A2'); // saved -> dirty: a transition
        c.edit('A23'); // still dirty
        c.edit('A234'); // still dirty

        expect(notifications, 3);
        c.dispose();
      });
    });

    test('notifies listeners on status transitions', () {
      fakeAsync((async) {
        final store = _RecordingStore();
        final c = _controller(store);
        var notifications = 0;
        c.addListener(() => notifications++);
        c.openFile('a.md', 'A'); // stays saved: no transition
        c.edit('A2'); // saved -> dirty
        async.elapse(const Duration(seconds: 5)); // dirty -> saving -> saved
        async.flushMicrotasks();
        expect(notifications, greaterThanOrEqualTo(2));
        c.dispose();
      });
    });
  });

  group('mergeFromDisk (the watcher design, Decision 7)', () {
    test('a clean buffer adopts the file, and notifies', () {
      // The file under the open path was rewritten by reconciliation. The
      // status does not change — saved before, saved after — but the buffer
      // did, and the pane puts it into the field on notification.
      fakeAsync((async) {
        final store = _RecordingStore();
        final c = _controller(store);
        c.openFile('a.md', 'A');
        var notifications = 0;
        c.addListener(() => notifications++);

        c.mergeFromDisk(() async => 'A merged');
        async.flushMicrotasks();

        expect(c.text, 'A merged');
        expect(c.isDirty, isFalse);
        expect(c.status, SaveStatus.saved);
        expect(notifications, 1);
        expect(store.writes, isEmpty, reason: 'a reload is not a save');
        c.dispose();
      });
    });

    test('a dirty buffer is merged with it, and the merge saved', () {
      // Before, the typing was dropped in favour of the file. Now neither is:
      // the external edit and the keystrokes both survive, and the ordinary
      // debounce saves the merge.
      fakeAsync((async) {
        final store = _RecordingStore();
        final c = _controller(store);
        c.openFile('a.md', 'one\ntwo\n');
        c.edit('ONE\ntwo\n');

        c.mergeFromDisk(() async => 'one\ntwo\nthree\n');
        async.flushMicrotasks();

        expect(c.text, 'ONE\ntwo\nthree\n');
        expect(c.isDirty, isTrue);
        expect(c.status, SaveStatus.dirty);

        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();
        expect(store.writes, ['a.md::ONE\ntwo\nthree\n']);
        expect(c.status, SaveStatus.saved);
        c.dispose();
      });
    });

    test('the file is read only once a write in flight has landed', () {
      // Read before our own save lands, the file is older than the saved
      // text, and merging it would undo that save.
      fakeAsync((async) {
        final store = _RecordingStore();
        final c = _controller(store);
        c.openFile('a.md', 'A');
        c.edit('A typed');
        c.flush(); // in flight: the store's write is a pending microtask
        final writesSeenByRead = <int>[];

        c.mergeFromDisk(() async {
          writesSeenByRead.add(store.writes.length);
          return 'A typed'; // what our own save left on disk
        });
        async.flushMicrotasks();

        expect(writesSeenByRead, [1]);
        expect(c.text, 'A typed', reason: 'our own save changes nothing');
        expect(c.status, SaveStatus.saved);
        c.dispose();
      });
    });

    test(
      'a write that starts while reading is awaited, and the file re-read',
      () {
        fakeAsync((async) {
          final store = _RecordingStore();
          final c = _controller(store);
          c.openFile('a.md', 'A');
          var reads = 0;

          c.mergeFromDisk(() async {
            reads++;
            if (reads == 1) {
              c.edit('A typed');
              c.flush();
            }
            return 'A typed';
          });
          async.flushMicrotasks();

          expect(reads, 2);
          expect(c.text, 'A typed');
          expect(c.isDirty, isFalse);
          c.dispose();
        });
      },
    );

    test('a file that says what was last saved changes nothing', () {
      // A notification of our own save, or a line-ending rewrite of it.
      fakeAsync((async) {
        final store = _RecordingStore();
        final c = _controller(store);
        c.openFile('a.md', 'one\n');
        c.edit('one!\n');
        var notifications = 0;
        c.addListener(() => notifications++);

        c.mergeFromDisk(() async => 'one\r\n');
        async.flushMicrotasks();

        expect(c.text, 'one!\n');
        expect(notifications, 0);
        c.dispose();
      });
    });

    test('a merge over the size limit is withheld', () {
      fakeAsync((async) {
        final store = _RecordingStore();
        final c = _controller(store)..sizeLimitBytes = 12;
        c.openFile('a.md', 'one\n');
        c.edit('one typed\n');

        c.mergeFromDisk(() async => 'one\nplus more\n');
        async.flushMicrotasks();
        async.elapse(const Duration(seconds: 31));
        async.flushMicrotasks();

        expect(c.text, 'one typed\nplus more\n');
        expect(c.status, SaveStatus.overLimit);
        expect(store.writes, isEmpty, reason: 'nothing is saved past it');
        c.dispose();
      });
    });

    test('a merge that ends where the file is, is clean', () {
      fakeAsync((async) {
        final store = _RecordingStore();
        final c = _controller(store);
        c.openFile('a.md', 'one\n');
        c.edit('one\ntwo\n');

        // The same line was added outside: the merge applies it once.
        c.mergeFromDisk(() async => 'one\ntwo\n');
        async.flushMicrotasks();

        expect(c.text, 'one\ntwo\n');
        expect(c.status, SaveStatus.saved);
        c.dispose();
      });
    });

    test('a file switched away from while reading is left alone', () {
      fakeAsync((async) {
        final store = _RecordingStore();
        final c = _controller(store);
        c.openFile('a.md', 'A');

        c.mergeFromDisk(() async {
          await c.openFile('b.md', 'B');
          return 'A merged';
        });
        async.flushMicrotasks();

        expect(c.path, 'b.md');
        expect(c.text, 'B');
        c.dispose();
      });
    });

    test('is a no-op before a file is open', () {
      fakeAsync((async) {
        final store = _RecordingStore();
        final c = _controller(store);
        var notifications = 0;
        c.addListener(() => notifications++);
        var reads = 0;

        c.mergeFromDisk(() async {
          reads++;
          return 'nothing to merge';
        });
        async.flushMicrotasks();

        expect(c.text, '');
        expect(reads, 0);
        expect(notifications, 0);
        c.dispose();
      });
    });
  });

  group('the size limit (ceiling step 22)', () {
    // Over the limit the save is withheld: nothing is written until the
    // user rolls back or the limit is lifted by a conversion.
    test('typing past the limit withholds the save', () {
      fakeAsync((async) {
        final store = _RecordingStore();
        final c = _controller(store)..sizeLimitBytes = 10;
        c.openFile('a.md', 'short');

        c.edit('this is well over ten bytes');
        expect(c.status, SaveStatus.overLimit);
        expect(c.isDirty, isTrue);

        async.elapse(const Duration(seconds: 60));
        async.flushMicrotasks();
        expect(store.writes, isEmpty, reason: 'no timer fires a save');

        c.flush();
        async.flushMicrotasks();
        expect(store.writes, isEmpty, reason: 'and a flush writes nothing');
        expect(c.status, SaveStatus.overLimit);
        expect(c.text, 'this is well over ten bytes', reason: 'buffer kept');
        c.dispose();
      });
    });

    test('exactly the limit is allowed', () {
      fakeAsync((async) {
        final store = _RecordingStore();
        final c = _controller(store)..sizeLimitBytes = 10;
        c.openFile('a.md', '');
        c.edit('0123456789');
        expect(c.status, SaveStatus.dirty);
        c.dispose();
      });
    });

    test('editing back under the limit saves as usual', () {
      fakeAsync((async) {
        final store = _RecordingStore();
        final c = _controller(store)..sizeLimitBytes = 10;
        c.openFile('a.md', 'short');
        c.edit('this is well over ten bytes');
        expect(c.status, SaveStatus.overLimit);

        c.edit('under');
        expect(c.status, SaveStatus.dirty);
        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();

        expect(store.writes, ['a.md::under']);
        expect(c.status, SaveStatus.saved);
        c.dispose();
      });
    });

    test('rollBack discards the buffer for the last saved text', () {
      fakeAsync((async) {
        final store = _RecordingStore();
        final c = _controller(store)..sizeLimitBytes = 10;
        c.openFile('a.md', 'saved');
        c.edit('this is well over ten bytes');
        var notifications = 0;
        c.addListener(() => notifications++);

        c.rollBack();

        expect(c.text, 'saved');
        expect(c.status, SaveStatus.saved);
        expect(c.isDirty, isFalse);
        expect(notifications, 1);
        async.elapse(const Duration(seconds: 60));
        async.flushMicrotasks();
        expect(store.writes, isEmpty);
        c.dispose();
      });
    });

    test('lifting the limit lets the withheld edit save', () {
      // A conversion clears the limit; the pending edit becomes an ordinary
      // dirty buffer and the next flush writes it.
      fakeAsync((async) {
        final store = _RecordingStore();
        final c = _controller(store)..sizeLimitBytes = 10;
        c.openFile('a.md', 'short');
        c.edit('this is well over ten bytes');
        expect(c.status, SaveStatus.overLimit);

        c.sizeLimitBytes = null;
        expect(c.status, SaveStatus.dirty);
        c.flush();
        async.flushMicrotasks();

        expect(store.writes, ['a.md::this is well over ten bytes']);
        expect(c.status, SaveStatus.saved);
        c.dispose();
      });
    });

    test('lowering the limit under the buffer withholds it', () {
      fakeAsync((async) {
        final store = _RecordingStore();
        final c = _controller(store);
        c.openFile('a.md', '');
        c.edit('twenty-two characters!');
        expect(c.status, SaveStatus.dirty);

        c.sizeLimitBytes = 10;

        expect(c.status, SaveStatus.overLimit);
        async.elapse(const Duration(seconds: 60));
        async.flushMicrotasks();
        expect(store.writes, isEmpty);
        c.dispose();
      });
    });

    test('a limit set before any file is open does nothing yet', () {
      fakeAsync((async) {
        final store = _RecordingStore();
        final c = _controller(store);
        c.sizeLimitBytes = 10;
        expect(c.status, SaveStatus.saved);
        c.rollBack();
        expect(c.text, '');
        c.dispose();
      });
    });

    test(
      'a withheld buffer is reported to the registry, and resolved through it',
      () {
        fakeAsync((async) {
          final store = _RecordingStore();
          final saves = PendingSaves();
          final c = DocumentEditController(
            writer: DirectNoteWriter(store),
            observeLifecycle: false,
            pendingSaves: saves,
          )..sizeLimitBytes = 10;
          c.openFile('a.md', 'short');
          expect(saves.hasWithheld, isFalse);

          c.edit('this is well over ten bytes');
          expect(c.isWithheld, isTrue);
          expect(saves.hasWithheld, isTrue);

          // No resolver yet: it cannot be settled, so it cannot be left.
          var settled = false;
          saves.resolveWithheld().then((value) => settled = value);
          async.flushMicrotasks();
          expect(settled, isFalse);

          // The pane's resolver rolls back; the registry sees it settled.
          c.resolveWithheld = () async {
            c.rollBack();
            return true;
          };
          saves.resolveWithheld().then((value) => settled = value);
          async.flushMicrotasks();
          expect(settled, isTrue);
          expect(saves.hasWithheld, isFalse);
          c.dispose();
          expect(saves.length, 0);
        });
      },
    );

    test('the limit is measured in bytes on disk, not characters', () {
      fakeAsync((async) {
        final store = _RecordingStore();
        final c = _controller(store)..sizeLimitBytes = 10;
        c.openFile('a.md', '');
        c.edit('日本語語'); // 4 characters, 12 bytes
        expect(c.status, SaveStatus.overLimit);
        c.dispose();
      });
    });
  });

  group('lifecycle observer registration', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    test('registers on construct and unregisters on dispose', () {
      final store = _RecordingStore();
      // Default observeLifecycle: true exercises addObserver / removeObserver.
      final c = DocumentEditController(writer: DirectNoteWriter(store));
      c.dispose();
    });
  });

  group('exit-time flush registration', () {
    test(
      'an unwritten buffer is flushed when the app is asked to exit',
      () async {
        final store = _RecordingStore();
        final saves = PendingSaves();
        final c = DocumentEditController(
          writer: DirectNoteWriter(store),
          observeLifecycle: false,
          pendingSaves: saves,
        );
        await c.openFile('a.md', 'hi');
        c.edit('hi there'); // dirty, with the debounce still pending

        // Desktop exits without a lifecycle event; this is the hook that saves
        // the last keystroke (see PendingSaves).
        await saves.flushAll();

        expect(store.writes, ['a.md::hi there']);
        c.dispose();
      },
    );

    test('a disposed controller leaves nothing registered', () async {
      final saves = PendingSaves();
      final c = DocumentEditController(
        writer: DirectNoteWriter(_RecordingStore()),
        observeLifecycle: false,
        pendingSaves: saves,
      );
      expect(saves.length, 1);

      c.dispose();

      expect(saves.length, 0);
    });
  });

  group('what the save found on disk (the watcher design, Decision 5)', () {
    DocumentEditController scripted(_ScriptedWriter writer) =>
        DocumentEditController(writer: writer, observeLifecycle: false);

    test('the save passes the text the buffer grew from', () async {
      final writer = _ScriptedWriter();
      final c = scripted(writer);
      addTearDown(c.dispose);
      await c.openFile('a.md', 'one\n');

      c.edit('one!\n');
      await c.flush();
      c.edit('one!!\n');
      await c.flush();

      expect(writer.bases, ['one\n', 'one!\n']);
    });

    test('a merge the writer made becomes the buffer, clean', () async {
      final writer = _ScriptedWriter()
        ..respond = (text) => '${text}from outside\n';
      final c = scripted(writer);
      addTearDown(c.dispose);
      await c.openFile('a.md', 'one\n');
      var notified = 0;
      c.addListener(() => notified++);

      c.edit('one!\n');
      await c.flush();

      expect(c.text, 'one!\nfrom outside\n');
      expect(c.isDirty, isFalse);
      expect(c.status, SaveStatus.saved);
      expect(notified, greaterThan(0), reason: 'the field is rebuilt');
    });

    test('typing during the write is merged over what came back', () async {
      final gate = Completer<void>();
      final writer = _ScriptedWriter()
        ..gate = gate.future
        ..respond = (text) => '${text}from outside\n';
      final c = scripted(writer);
      addTearDown(c.dispose);
      await c.openFile('a.md', 'one\n');

      c.edit('one!\n');
      final saving = c.flush();
      c.edit('one!\ntyped meanwhile\n');
      gate.complete();
      await saving;

      expect(c.text, 'one!\nfrom outside\ntyped meanwhile\n');
      expect(c.isDirty, isTrue, reason: 'the late typing is not saved yet');
      expect(c.status, SaveStatus.dirty);
    });

    test('a merge too large to save is held over the limit', () async {
      final writer = _ScriptedWriter()
        ..error = const NoteMergeOverLimitException(
          path: 'a.md',
          merged: 'one!\nfrom outside, and far too long\n',
          onDisk: 'one\nfrom outside, and far too long\n',
        );
      final c = scripted(writer)..sizeLimitBytes = 30;
      addTearDown(c.dispose);
      await c.openFile('a.md', 'one\n');

      c.edit('one!\n');
      await c.flush();

      expect(c.text, 'one!\nfrom outside, and far too long\n');
      expect(c.status, SaveStatus.overLimit);
      expect(c.isWithheld, isTrue);
      // What the note holds is the external edit, so that is where a roll
      // back returns to — not the text from before it.
      c.rollBack();
      expect(c.text, 'one\nfrom outside, and far too long\n');
    });

    test(
      'with no limit to hold it under, a refused merge is an error',
      () async {
        final writer = _ScriptedWriter()
          ..error = const NoteMergeOverLimitException(
            path: 'a.md',
            merged: 'merged\n',
            onDisk: 'external\n',
          );
        final c = scripted(writer);
        addTearDown(c.dispose);
        await c.openFile('a.md', 'one\n');

        c.edit('one!\n');
        await c.flush();

        expect(c.text, 'merged\n');
        expect(c.status, SaveStatus.error);
      },
    );
  });
}

/// A writer that records the base of each save, and answers with a scripted
/// result or error — what the real writers return when the file had moved.
class _ScriptedWriter implements NoteWriter {
  final List<String?> bases = [];
  String Function(String text)? respond;
  Object? error;
  Future<void>? gate;

  @override
  Future<String> write(String path, String text, {String? base}) async {
    bases.add(base);
    await gate;
    final e = error;
    if (e != null) throw e;
    return respond?.call(text) ?? text;
  }
}
