import 'dart:io';

import 'package:brainframe/engram/crdt/app_data_resolver.dart';
import 'package:brainframe/engram/id.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The resolver that decides where `metadata.db` lives.
///
/// [app_data_source_test.dart](app_data_source_test.dart) pins *which*
/// `path_provider` call each platform should make. This file pins that the
/// resolver actually makes it — otherwise the mapping is a decorative enum —
/// and that the store path is composed from the engram ULID and nothing else.
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

  /// Every `path_provider` method invoked since the last [setUp].
  late List<String> calls;

  setUp(() {
    calls = [];
    binding.defaultBinaryMessenger.setMockMethodCallHandler(pathProvider, (
      call,
    ) async {
      calls.add(call.method);
      return '/fake/${call.method}';
    });
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(pathProvider, null);
  });

  group('appDataRootResolver', () {
    test('Windows resolves through the LocalAppData call', () async {
      final resolve = appDataRootResolver(operatingSystem: 'windows');

      expect(await resolve(), '/fake/getApplicationCacheDirectory');
      expect(calls, [
        'getApplicationCacheDirectory',
      ], reason: 'getApplicationSupportDirectory is RoamingAppData on Windows');
    });

    test('Linux resolves through the application-support call', () async {
      final resolve = appDataRootResolver(operatingSystem: 'linux');

      expect(await resolve(), '/fake/getApplicationSupportDirectory');
      expect(calls, [
        'getApplicationSupportDirectory',
      ], reason: 'the Windows call is \$XDG_CACHE_HOME here');
    });

    test('macOS resolves through the application-support call', () async {
      final resolve = appDataRootResolver(operatingSystem: 'macos');

      expect(await resolve(), '/fake/getApplicationSupportDirectory');
    });

    test('defaults to this process\'s platform', () async {
      // No operatingSystem given: the tests run on Linux, so this must take
      // the application-support branch without being told to.
      expect(await appDataRootResolver()(), isNotEmpty);
      expect(calls, isNotEmpty);
    });

    test('an override short-circuits platform resolution', () async {
      // The Raspberry Pi's case: a library on a mounted volume whose path
      // comes from configuration, which path_provider cannot report.
      final resolve = appDataRootResolver(
        overridePath: '/mnt/library',
        operatingSystem: 'windows',
      );

      expect(await resolve(), '/mnt/library');
      expect(
        calls,
        isEmpty,
        reason: 'an override must not consult path_provider at all',
      );
    });
  });

  group('engramStorePath', () {
    test('is the engram ULID under the engrams directory', () async {
      final id = newUlid();

      expect(
        await engramStorePath(
          id,
          resolveRoot: appDataRootResolver(overridePath: '/root'),
        ),
        '/root/engrams/$id',
      );
    });

    test('uses the injected resolver rather than the platform', () async {
      await engramStorePath(
        newUlid(),
        resolveRoot: appDataRootResolver(overridePath: '/root'),
      );

      expect(calls, isEmpty);
    });

    test('falls back to the platform resolver when none is injected', () async {
      final id = newUlid();

      expect(
        await engramStorePath(id),
        '/fake/getApplicationSupportDirectory/engrams/$id',
      );
    });

    test('rejects anything that is not a canonical ULID', () async {
      // The ULID is a directory component, so a display name or a relative
      // path must never reach it.
      for (final bad in [
        'Field Notebook',
        '../../etc',
        'engrams/x',
        '',
        newUlid().toLowerCase(),
      ]) {
        await expectLater(
          engramStorePath(
            bad,
            resolveRoot: appDataRootResolver(overridePath: '/root'),
          ),
          throwsArgumentError,
          reason: '"$bad" must not become a directory name',
        );
      }
    });
  });

  group('deleteEngramStore', () {
    late Directory root;
    late AppDataRootResolver resolveRoot;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('engram_store_delete');
      resolveRoot = appDataRootResolver(overridePath: root.path);
    });

    tearDown(() {
      if (root.existsSync()) root.deleteSync(recursive: true);
    });

    test('deletes the store directory and everything in it', () async {
      final id = newUlid();
      final other = newUlid();
      final store = Directory('${root.path}/engrams/$id');
      // metadata.db plus whatever else lands beside it — a WAL, a later
      // index — goes as one; only this engram's directory, not a sibling's.
      await File('${store.path}/metadata.db').create(recursive: true);
      await File('${store.path}/metadata.db-wal').create();
      await File('${store.path}/index/search.db').create(recursive: true);
      await File(
        '${root.path}/engrams/$other/metadata.db',
      ).create(recursive: true);

      expect(await deleteEngramStore(id, resolveRoot: resolveRoot), isTrue);

      expect(store.existsSync(), isFalse);
      expect(
        File('${root.path}/engrams/$other/metadata.db').existsSync(),
        isTrue,
      );
    });

    test('a store that was never created is not an error', () async {
      // An engram adopted on this device but never opened here has no store;
      // the clean-up still has the folder's marker to remove.
      expect(
        await deleteEngramStore(newUlid(), resolveRoot: resolveRoot),
        isFalse,
      );
    });

    test('uses the injected resolver rather than the platform', () async {
      await deleteEngramStore(newUlid(), resolveRoot: resolveRoot);

      expect(calls, isEmpty);
    });

    test('rejects anything that is not a canonical ULID', () async {
      // The same guard as engramStorePath: a delete keyed on anything else
      // could name a directory that is not an engram store.
      await expectLater(
        deleteEngramStore('../engrams', resolveRoot: resolveRoot),
        throwsArgumentError,
      );
      expect(root.existsSync(), isTrue);
    });
  });
}
