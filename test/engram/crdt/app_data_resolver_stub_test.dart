import 'package:brainframe/engram/crdt/app_data_resolver_stub.dart';
import 'package:flutter_test/flutter_test.dart';

/// The web build must never reach the device-local store: it has no filesystem
/// engrams, cannot load `crdt_lf_sqlite` (no `dart:ffi`), and serves only the
/// read-only built-ins, which cannot drift and cannot be edited.
void main() {
  test('appDataRootResolver is unsupported on the web stub', () {
    expect(() => appDataRootResolver(), throwsUnsupportedError);
  });

  test('an override does not make the web stub supported', () {
    // Signature parity is not capability — there is nowhere to put a database
    // regardless of what path the caller names.
    expect(
      () => appDataRootResolver(overridePath: '/anywhere'),
      throwsUnsupportedError,
    );
  });

  test('engramStorePath is unsupported on the web stub', () {
    expect(
      () => engramStorePath('01JBQ9YQ7C8VF9YB0X5H3TQ2ZK'),
      throwsUnsupportedError,
    );
  });
}
