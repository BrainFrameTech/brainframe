import 'dart:io';

import 'package:brainframe/engram/container_resolver.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The `--ignore-config` privacy guarantee, at the seam `main.dart` calls.
///
/// A session that ignores saved configuration must not see the user's real
/// engrams: discovery scans the container directly, so a container left
/// pointing at the documents directory names every private engram in the
/// switcher regardless of what the preference store holds.
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
      pathProvider,
      (call) async => call.method == 'getApplicationDocumentsDirectory'
          ? '/fake/docs'
          : null,
    );
  });

  tearDown(() {
    binding.defaultBinaryMessenger.setMockMethodCallHandler(pathProvider, null);
  });

  test('without --ignore-config, resolves the real app container', () async {
    final resolve = engramContainerResolver(ignoreConfig: false);
    expect(await resolve(), '/fake/docs');
  });

  test('with --ignore-config, resolves an empty throwaway container', () async {
    final resolve = engramContainerResolver(ignoreConfig: true);
    final path = await resolve();

    expect(path, isNot('/fake/docs'));
    final container = Directory(path);
    expect(await container.exists(), isTrue);
    expect(
      await container.list().isEmpty,
      isTrue,
      reason: 'an ignore-config session must discover no real engrams',
    );
  });

  test(
    'with --ignore-config, the container is stable across resolvers',
    () async {
      expect(
        await engramContainerResolver(ignoreConfig: true)(),
        await engramContainerResolver(ignoreConfig: true)(),
        reason:
            'discovery and creation must agree on one container per session',
      );
    },
  );
}
