import 'dart:io';

import 'package:brainframe/engram/fs/engram_container.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The two container sources: the documents directory `path_provider`
/// reports, and the throwaway one `--ignore-config` substitutes for it.
void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  group('applicationEngramContainerPath', () {
    const channel = MethodChannel('plugins.flutter.io/path_provider');

    tearDown(() {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    });

    test('returns the documents directory from path_provider', () async {
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'getApplicationDocumentsDirectory'
            ? '/fake/docs'
            : null,
      );
      expect(await applicationEngramContainerPath(), '/fake/docs');
    });
  });

  group('ephemeralEngramContainerPath', () {
    test('is an existing, empty directory', () async {
      final path = await ephemeralEngramContainerPath();
      final directory = Directory(path);
      expect(await directory.exists(), isTrue);
      expect(await directory.list().isEmpty, isTrue);
    });

    test(
      'is the same container every call, so discovery and creation agree',
      () async {
        expect(
          await ephemeralEngramContainerPath(),
          await ephemeralEngramContainerPath(),
        );
      },
    );

    test('concurrent callers share one container rather than racing', () async {
      final paths = await Future.wait([
        ephemeralEngramContainerPath(),
        ephemeralEngramContainerPath(),
        ephemeralEngramContainerPath(),
      ]);
      expect(paths.toSet(), hasLength(1));
    });

    test('is not the real documents container', () async {
      const channel = MethodChannel('plugins.flutter.io/path_provider');
      binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        (call) async => call.method == 'getApplicationDocumentsDirectory'
            ? '/fake/docs'
            : null,
      );
      addTearDown(() {
        binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
      });
      expect(
        await ephemeralEngramContainerPath(),
        isNot(await applicationEngramContainerPath()),
      );
    });
  });
}
