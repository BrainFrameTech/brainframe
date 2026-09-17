import 'package:brainframe/engram/fs/engram_container_stub.dart';
import 'package:flutter_test/flutter_test.dart';

/// The web build has no filesystem and so no container to point at.
void main() {
  test('applicationEngramContainerPath is unsupported on the web stub', () {
    expect(() => applicationEngramContainerPath(), throwsUnsupportedError);
  });

  test('ephemeralEngramContainerPath is unsupported on the web stub', () {
    expect(() => ephemeralEngramContainerPath(), throwsUnsupportedError);
  });
}
