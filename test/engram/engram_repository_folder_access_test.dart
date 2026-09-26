import 'dart:convert';
import 'dart:io';

import 'package:brainframe/engram/engram_repository.dart';
import 'package:brainframe/engram/fs/folder_access.dart';
import 'package:brainframe/engram/fs/fs_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import '../support/fake_folder_access.dart';

/// Registry rows reached through a [FolderAccess]: bookmarks stored, resolved,
/// and refreshed, and unreachable rows told apart by why (the sandboxed folder
/// adoption design, Decisions 3 and 6).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const registryKey = 'engram.registry.v1';

  late Directory tempRoot;
  late String containerPath;
  late String dataRoot;
  late SharedPreferencesAsync prefs;

  EngramRepository repoWith(FolderAccess access) => EngramRepository(
    preferences: prefs,
    containerPathResolver: () async => containerPath,
    dataRootResolver: () async => dataRoot,
    folderAccess: access,
  );

  Future<List<Map<String, dynamic>>> rows() async => [
    for (final line in await prefs.getStringList(registryKey) ?? <String>[])
      jsonDecode(line) as Map<String, dynamic>,
  ];

  Future<String> folder(String name) async {
    final path = '${tempRoot.path}/$name';
    await Directory(path).create(recursive: true);
    return path;
  }

  setUp(() async {
    tempRoot = await Directory.systemTemp.createTemp('repo_folder_access');
    containerPath = '${tempRoot.path}/container';
    dataRoot = '${tempRoot.path}/appdata';
    await Directory(containerPath).create(recursive: true);
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    prefs = SharedPreferencesAsync();
  });

  tearDown(() async {
    if (tempRoot.existsSync()) tempRoot.deleteSync(recursive: true);
  });

  group('stored rows', () {
    test('a row from before bookmarks resolves as its plain path, and is '
        'written back unchanged', () async {
      final path = await folder('Legacy');
      final engram = await repoWith(FakeFolderAccess()).adoptFolder(
        EngramLocation(path),
      );
      final legacy = jsonEncode({
        'id': engram.id,
        'displayName': 'Legacy',
        'path': path,
      });
      await prefs.setStringList(registryKey, [legacy]);
      final access = FakeFolderAccess();

      final discovery = await repoWith(access).discover();

      expect(discovery.available.map((e) => e.id), contains(engram.id));
      expect(access.resolved, [(path: path, bookmark: null)]);
      expect(await prefs.getStringList(registryKey), [legacy]);
    });

    test('a bookmark given at adoption is stored and resolved with', () async {
      final path = await folder('Picked');
      final access = FakeFolderAccess();
      final repo = repoWith(access);

      await repo.adoptFolder(EngramLocation(path), bookmark: 'bm-1');
      await repo.discover();

      expect((await rows()).single['bookmark'], 'bm-1');
      expect(access.resolved, [(path: path, bookmark: 'bm-1')]);
    });

    test('a row with no bookmark stores none, not a null', () async {
      await repoWith(FakeFolderAccess()).adoptFolder(
        EngramLocation(await folder('Plain')),
      );
      expect((await rows()).single.containsKey('bookmark'), isFalse);
    });

    test('renaming keeps the bookmark', () async {
      final path = await folder('Named');
      final repo = repoWith(FakeFolderAccess());
      final engram = await repo.adoptFolder(
        EngramLocation(path),
        bookmark: 'bm-keep',
      );

      await repo.rename(engram, 'Renamed');

      final row = (await rows()).single;
      expect(row['displayName'], 'Renamed');
      expect(row['bookmark'], 'bm-keep');
    });
  });

  group('refresh on resolve', () {
    test('a folder that moved: the row follows it, bookmark and path',
        () async {
      final before = await folder('Before');
      final engram = await repoWith(FakeFolderAccess()).adoptFolder(
        EngramLocation(before),
        bookmark: 'bm-old',
      );
      final after = '${tempRoot.path}/After';
      await Directory(before).rename(after);
      final access = FakeFolderAccess(
        onResolve: (path, bookmark) =>
            ResolvedFolder(after, refreshedBookmark: 'bm-new'),
      );
      final repo = repoWith(access);

      final discovery = await repo.discover();

      expect(discovery.available.map((e) => e.id), contains(engram.id));
      final row = (await rows()).single;
      expect(row['path'], after);
      expect(row['bookmark'], 'bm-new');
      final registered = await repo.registeredEngrams();
      expect(registered.single.path, after);
      expect(registered.single.available, isTrue);
    });

    test('a stale bookmark alone is replaced, the path kept', () async {
      final path = await folder('Stale');
      await repoWith(FakeFolderAccess()).adoptFolder(
        EngramLocation(path),
        bookmark: 'bm-stale',
      );
      final access = FakeFolderAccess(
        onResolve: (path, bookmark) =>
            ResolvedFolder(path, refreshedBookmark: 'bm-fresh'),
      );

      await repoWith(access).discover();

      final row = (await rows()).single;
      expect(row['path'], path);
      expect(row['bookmark'], 'bm-fresh');
    });

    test('a row that resolves as stored keeps its bookmark', () async {
      final path = await folder('Same');
      final repo = repoWith(FakeFolderAccess());
      await repo.adoptFolder(EngramLocation(path), bookmark: 'bm-same');

      await repo.discover();

      expect((await rows()).single['bookmark'], 'bm-same');
    });
  });

  group('why a row is unreachable', () {
    Future<UnavailableEngram> unavailableWith(
      ResolvedFolder Function(String path, String? bookmark)? onResolve, {
      bool deleteFolder = false,
    }) async {
      final path = await folder('Target');
      final engram = await repoWith(FakeFolderAccess()).adoptFolder(
        EngramLocation(path),
      );
      if (deleteFolder) await Directory(path).delete(recursive: true);

      final discovery = await repoWith(
        FakeFolderAccess(onResolve: onResolve),
      ).discover();

      expect(discovery.available.map((e) => e.id), isNot(contains(engram.id)));
      return discovery.unavailable.singleWhere((e) => e.id == engram.id);
    }

    test('a folder that is gone is missing', () async {
      final unavailable = await unavailableWith(null, deleteFolder: true);
      expect(unavailable.reason, UnreachableReason.missing);
    });

    test('lost permission is accessNeeded, though the folder is there',
        () async {
      final unavailable = await unavailableWith(
        (_, _) => throw const FolderAccessException(
          UnreachableReason.accessNeeded,
        ),
      );
      expect(unavailable.reason, UnreachableReason.accessNeeded);
      expect(unavailable.displayName, 'Target');
    });

    test('a bookmark that no longer resolves is bookmarkInvalid', () async {
      final unavailable = await unavailableWith(
        (_, _) => throw const FolderAccessException(
          UnreachableReason.bookmarkInvalid,
          'volume not mounted',
        ),
      );
      expect(unavailable.reason, UnreachableReason.bookmarkInvalid);
    });

    test('the exception names its reason and message', () {
      expect(
        const FolderAccessException(UnreachableReason.accessNeeded).toString(),
        'FolderAccessException(accessNeeded)',
      );
      expect(
        const FolderAccessException(
          UnreachableReason.bookmarkInvalid,
          'gone',
        ).toString(),
        'FolderAccessException(bookmarkInvalid: gone)',
      );
    });
  });

  group('cleanUp through access', () {
    Future<({String path, String id, Directory store})> adopted() async {
      final path = await folder('Cleaned');
      final engram = await repoWith(FakeFolderAccess()).adoptFolder(
        EngramLocation(path),
        bookmark: 'bm',
      );
      final store = Directory('$dataRoot/engrams/${engram.id}');
      await store.create(recursive: true);
      return (path: path, id: engram.id, store: store);
    }

    test('removes the marker where the bookmark resolves now', () async {
      final a = await adopted();
      final moved = '${tempRoot.path}/Moved';
      await Directory(a.path).rename(moved);

      await repoWith(
        FakeFolderAccess(onResolve: (_, _) => ResolvedFolder(moved)),
      ).cleanUp(a.id);

      expect(Directory('$moved/.brainframe').existsSync(), isFalse);
      expect(a.store.existsSync(), isFalse);
      expect(await rows(), isEmpty);
    });

    test('a dead bookmark still lets the store and the row go', () async {
      final a = await adopted();

      await repoWith(
        FakeFolderAccess(
          onResolve: (_, _) => throw const FolderAccessException(
            UnreachableReason.bookmarkInvalid,
          ),
        ),
      ).cleanUp(a.id);

      expect(a.store.existsSync(), isFalse);
      expect(await rows(), isEmpty);
      expect(
        Directory('${a.path}/.brainframe').existsSync(),
        isTrue,
        reason: 'the folder could not be reached, so it was not touched',
      );
    });

    test('lost permission throws and leaves everything for a retry', () async {
      final a = await adopted();

      await expectLater(
        repoWith(
          FakeFolderAccess(
            onResolve: (_, _) => throw const FolderAccessException(
              UnreachableReason.accessNeeded,
            ),
          ),
        ).cleanUp(a.id),
        throwsA(isA<FolderAccessException>()),
      );

      expect(Directory('${a.path}/.brainframe').existsSync(), isTrue);
      expect(a.store.existsSync(), isTrue);
      expect(await rows(), hasLength(1));
    });
  });
}
