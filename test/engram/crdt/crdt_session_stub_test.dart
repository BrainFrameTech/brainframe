import 'package:brainframe/engram/asset_engram_store.dart';
import 'package:brainframe/engram/crdt/crdt_session_stub.dart';
import 'package:brainframe/engram/engram.dart';
import 'package:flutter_test/flutter_test.dart';

/// Web has no op-log and never will: `crdt_lf_sqlite` rides on `dart:ffi`.
void main() {
  final engram = Engram(
    id: '01JBQ9YQ7C8VF9YB0X5H3TQ2ZK',
    displayName: 'built-in',
    readOnly: true,
    store: AssetEngramStore(assetPrefix: 'assets/engrams/tutorial/'),
  );

  test('openFor is always null on the web stub', () async {
    // Null rather than a throw: web serves only the read-only built-ins, which
    // cannot be edited and cannot drift, so having no session is the correct
    // state rather than a missing capability.
    expect(await CrdtSession.openFor(engram), isNull);
  });

  test('a writable engram is still null there', () async {
    // Signature parity is not capability. Even if a writable engram somehow
    // existed on web, there is no ffi to open a log through.
    expect(
      await CrdtSession.openFor(
        Engram(
          id: engram.id,
          displayName: engram.displayName,
          readOnly: false,
          store: engram.store,
        ),
      ),
      isNull,
    );
  });
}
