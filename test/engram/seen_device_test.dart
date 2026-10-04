import 'package:brainframe/engram/note_reconciler.dart';
import 'package:flutter_test/flutter_test.dart';

/// The devices a ledger has seen, and the lookup a card names them by.
void main() {
  const self = SeenDevice(
    peer: 'aaaaaaaa-1111-4111-8111-111111111111',
    name: 'jdoe-desktop',
    isThisDevice: true,
  );
  const silent = SeenDevice(peer: '5c1e09a2-3333-4333-8333-333333333333');

  test('an unnamed device is known by the first block of its ID', () {
    expect(silent.shortId, '5c1e09a2');
  });

  test('the ledger finds a device by peer, or says it has not seen it', () {
    const ledger = NoteLedger(
      peers: 2,
      minted: 0,
      adopted: 0,
      unclaimed: 0,
      tombstoned: 0,
      devices: [self, silent],
    );

    expect(ledger.device(silent.peer), silent);
    expect(ledger.device('ffffffff-0000-4000-8000-000000000000'), isNull);
  });

  test('equal by every field, and says what it holds', () {
    expect(
      const SeenDevice(
        peer: 'aaaaaaaa-1111-4111-8111-111111111111',
        name: 'jdoe-desktop',
        isThisDevice: true,
      ),
      self,
    );
    expect(self, isNot(silent));
    expect({
      self.hashCode,
      silent.hashCode,
      const SeenDevice(peer: 'x').hashCode,
    }, hasLength(3));
    expect(self.toString(), contains('jdoe-desktop'));
    expect(self.toString(), contains('this'));
    expect(silent.toString(), contains('unnamed'));
  });
}
