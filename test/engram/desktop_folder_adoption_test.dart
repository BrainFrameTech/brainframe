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

      final engram = await pickAndAdoptFolder(
        repository,
        picker: () async => picked,
        confirm: (preview) async {
          asked = preview;
          expect(
            File('$picked/.brainframe/engram.json').existsSync(),
            isFalse,
            reason: 'asked before anything is written',
          );
          return true;
        },
      );

      expect(engram, isNotNull);
      expect(asked!.name, 'Notes');
      expect(asked!.fileCount, 2, reason: 'the hidden file is not a note');
      expect(asked!.crlfCount, 1);
      expect(asked!.isEngram, isFalse);
      expect(File('$picked/.brainframe/engram.json').existsSync(), isTrue);
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

    test('an existing engram is opened without asking', () async {
      // Nothing new is written into a folder that already carries a marker,
      // so there is nothing to confirm.
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      final picked = '${tempRoot.path}/Existing';
      await Directory(picked).create(recursive: true);
      final created = await repository.adoptFolder(EngramLocation(picked));
      var asked = false;

      final engram = await pickAndAdoptFolder(
        repository,
        picker: () async => picked,
        confirm: (_) async {
          asked = true;
          return false;
        },
      );

      expect(asked, isFalse);
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
