import 'dart:async';
import 'dart:io';

import 'package:brainframe/engram/desktop_folder_adoption.dart';
import 'package:brainframe/engram/engram_repository.dart';
import 'package:brainframe/engram/fs/fs_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempRoot;
  late String containerPath;
  late EngramRepository repository;

  EngramRepository repoWith() => EngramRepository(
        preferences: SharedPreferencesAsync(),
        containerPathResolver: () async => containerPath,
      );

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('desktop_adopt_test');
    containerPath = '${tempRoot.path}/container';
    await Directory(containerPath).create(recursive: true);
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    repository = repoWith();
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  group('isDesktopFolderAdoptionSupported', () {
    test('is true on desktop targets', () {
      for (final platform in [
        TargetPlatform.windows,
        TargetPlatform.linux,
        TargetPlatform.macOS,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(isDesktopFolderAdoptionSupported, isTrue, reason: '$platform');
      }
    });

    test('is false on mobile targets', () {
      for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(isDesktopFolderAdoptionSupported, isFalse, reason: '$platform');
      }
    });
  });

  group('pickAndAdoptFolder', () {
    test('adopts and registers the folder the picker returns', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final picked = '${tempRoot.path}/Chosen';
      await Directory(picked).create(recursive: true);

      final engram = await pickAndAdoptFolder(
        repository,
        picker: () async => picked,
      );

      expect(engram, isNotNull);
      expect(engram!.displayName, 'Chosen');
      expect(File('$picked/.brainframe/engram.json').existsSync(), isTrue);

      // A fresh repository over the same prefs still discovers it — it was
      // persisted as a registry root, not just returned.
      final discovery = await repoWith().discover();
      expect(discovery.available.any((e) => e.id == engram.id), isTrue);
    });

    test('returns null and registers nothing when the picker is cancelled',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

      final engram = await pickAndAdoptFolder(
        repository,
        picker: () async => null,
      );

      expect(engram, isNull);
      final discovery = await repository.discover();
      // Only the two built-ins; nothing was adopted.
      expect(discovery.available.every((e) => e.readOnly), isTrue);
    });

    test('asks before adopting a folder that is not an engram', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final picked = '${tempRoot.path}/Notes';
      await Directory('$picked/sub').create(recursive: true);
      await Directory('$picked/.obsidian').create(recursive: true);
      await File('$picked/a.md').writeAsString('a\r\n');
      await File('$picked/sub/b.md').writeAsString('b\n');
      await File('$picked/.obsidian/app.json').writeAsString('{}');
      FolderAdoptionPreview? asked;
      String? shown;
      final steps = <({int done, int total})>[];

      final engram = await pickAndAdoptFolder(
        repository,
        picker: () async => picked,
        confirm: (previewing) async {
          // Handed the folder the moment it is picked — its name known,
          // the pass under way — and asked once the preview is in.
          shown = previewing.name;
          previewing.progress.addListener(
            () => steps.add(previewing.progress.value!),
          );
          asked = await previewing.preview;
          expect(
            File('$picked/.brainframe/engram.json').existsSync(),
            isFalse,
            reason: 'asked before anything is written',
          );
          return true;
        },
      );

      expect(engram, isNotNull);
      expect(shown, 'Notes');
      expect(
        steps,
        [(done: 0, total: 2), (done: 1, total: 2), (done: 2, total: 2)],
        reason: 'every file one step, in order, ending at the total',
      );
      expect(asked!.name, 'Notes');
      expect(asked!.fileCount, 2, reason: 'the hidden file is not a note');
      expect(asked!.crlfCount, 1);
      expect(asked!.isEngram, isFalse);
      expect(File('$picked/.brainframe/engram.json').existsSync(), isTrue);
    });

    test('a cancelled pass adopts nothing, whatever was answered', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final picked = '${tempRoot.path}/Notes';
      await Directory(picked).create(recursive: true);
      for (final name in ['a.md', 'b.md', 'c.md']) {
        await File('$picked/$name').writeAsString('$name\r\n');
      }
      var stoppedAt = -1;

      final engram = await pickAndAdoptFolder(
        repository,
        picker: () async => picked,
        confirm: (previewing) async {
          // Cancel between the first and second file, as the dialog's
          // Cancel does, then answer as if the user had gone on.
          previewing.progress.addListener(() {
            if (previewing.progress.value!.done == 1) previewing.cancel();
          });
          final preview = await previewing.preview;
          stoppedAt = preview.crlfCount;
          return true;
        },
      );

      expect(engram, isNull);
      expect(stoppedAt, 1, reason: 'the walk stopped at the next file');
      expect(Directory('$picked/.brainframe').existsSync(), isFalse);
      final discovery = await repository.discover();
      expect(discovery.available.every((e) => e.readOnly), isTrue);
    });

    test('declining leaves the folder untouched and registers nothing',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final picked = '${tempRoot.path}/Notes';
      await Directory(picked).create(recursive: true);
      await File('$picked/a.md').writeAsString('a');

      final engram = await pickAndAdoptFolder(
        repository,
        picker: () async => picked,
        confirm: (_) async => false,
      );

      expect(engram, isNull);
      expect(Directory('$picked/.brainframe').existsSync(), isFalse);
      final discovery = await repository.discover();
      expect(discovery.available.every((e) => e.readOnly), isTrue);
    });

    test('declining before the pass has ended stops it, and the call waits',
        () async {
      // A confirmer that answers at once — as the dialog's Cancel does, or
      // a test's stub — leaves the walk running unless the flow stops it.
      // It must: a walk over thousands of files going on behind a decision
      // already made is wasted work, and if the folder goes from under it,
      // an error with nobody to catch it.
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final picked = '${tempRoot.path}/Notes';
      await Directory(picked).create(recursive: true);
      for (var i = 0; i < 20; i++) {
        await File('$picked/n$i.md').writeAsString('note $i\n');
      }
      FolderPreviewing? seen;

      final engram = await pickAndAdoptFolder(
        repository,
        picker: () async => picked,
        confirm: (previewing) async {
          seen = previewing;
          return false; // without cancelling, and without waiting
        },
      );

      expect(engram, isNull);
      expect(seen!.cancelled, isTrue, reason: 'stopped by the flow itself');
      // Already over when the call returned, not merely told to stop: a
      // callback on the preview runs on the next microtask, with no file
      // still being read in between.
      var ended = false;
      unawaited(
        seen!.preview.then<void>((_) => ended = true, onError: (_) {}),
      );
      await Future<void>.delayed(Duration.zero);
      expect(ended, isTrue);
    });

    test('an existing engram is shown as one, for the confirmer not to ask',
        () async {
      // Nothing new is written into a folder that already carries a marker,
      // so there is nothing to confirm: the preview says so, and the
      // confirmer answers without a question (the dialog's own test).
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final picked = '${tempRoot.path}/Existing';
      await Directory(picked).create(recursive: true);
      final created = await repository.adoptFolder(EngramLocation(picked));
      bool? isEngram;

      final engram = await pickAndAdoptFolder(
        repository,
        picker: () async => picked,
        confirm: (previewing) async {
          isEngram = (await previewing.preview).isEngram;
          return isEngram!;
        },
      );

      expect(isEngram, isTrue);
      expect(engram!.id, created.id);
    });

    test('throws off the desktop targets before invoking the picker', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      var pickerCalled = false;

      await expectLater(
        pickAndAdoptFolder(
          repository,
          picker: () async {
            pickerCalled = true;
            return null;
          },
        ),
        throwsUnsupportedError,
      );
      expect(pickerCalled, isFalse);
    });
  });
}
