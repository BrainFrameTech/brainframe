import 'package:brainframe/engram/crdt/metadata_db_stub.dart';
import 'package:flutter_test/flutter_test.dart';

/// The web build must never reach SQLite: `crdt_lf_sqlite` rides on
/// `dart:ffi`, which does not exist there.
void main() {
  const id = '01JBQ9YQ7C8VF9YB0X5H3TQ2ZK';

  test('open is unsupported on the web stub', () {
    expect(() => MetadataDatabase.open(id), throwsUnsupportedError);
  });

  test('openInMemory is unsupported on the web stub', () {
    // Signature parity is not capability — there is no ffi to open even an
    // in-memory database through.
    expect(MetadataDatabase.openInMemory, throwsUnsupportedError);
  });

  test('relocateEngramStore is unsupported on the web stub', () {
    expect(
      () => relocateEngramStore(fromEngramId: id, toEngramId: id),
      throwsUnsupportedError,
    );
  });

  test('the exception types carry their message', () {
    // Constructible so the io and stub builds present one API; asserted here
    // because nothing else on this platform ever builds one.
    expect(
      const MetadataDatabaseException('bad schema').toString(),
      contains('bad schema'),
    );
    expect(
      const EngramStoreCollisionException('/store').toString(),
      contains('/store'),
    );
  });
}
