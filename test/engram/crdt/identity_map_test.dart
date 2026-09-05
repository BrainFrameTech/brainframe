import 'package:brainframe/engram/crdt/catalog.dart';
import 'package:brainframe/engram/crdt/identity_map.dart';
import 'package:crdt_lf/crdt_lf.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hlc_dart/hlc_dart.dart';

import '../../crdt/support/peer_ids.dart';

/// The identity map's row type, which is platform-neutral and holds no
/// storage.
void main() {
  OperationId stamp(PeerId peer, int millis) =>
      OperationId(peer, HybridLogicalClock(l: millis, c: 0));

  IdentityRow row({
    String ulid = '01JBQ9YQ7C8VF9YB0X5H3TQ2ZK',
    String path = 'inbox/today.md',
    MergePolicy mergePolicy = MergePolicy.fugueText,
    OperationId? recordedAt,
    bool deleted = false,
    OperationId? seedClaim,
  }) => IdentityRow(
    ulid: ulid,
    path: path,
    mergePolicy: mergePolicy,
    recordedAt: recordedAt ?? stamp(peerA, 100),
    deleted: deleted,
    seedClaim: seedClaim,
  );

  group('a row states who said what', () {
    test('the recording peer is the stamp\'s peer', () {
      expect(row(recordedAt: stamp(peerB, 5)).recordedBy, peerB);
    });

    test('a live row is not deleted by default', () {
      expect(row().deleted, isFalse);
    });

    test('no seed claim means no seeder', () {
      expect(row().seedClaim, isNull);
      expect(row().seededBy, isNull);
    });

    test('a seed claim exposes the peer that took it', () {
      expect(row(seedClaim: stamp(peerC, 7)).seededBy, peerC);
    });

    test('the recorder need not be the seeder', () {
      // A rename is performed by whichever device notices it, which is
      // frequently not the device that minted the ULID.
      final noticed = row(
        recordedAt: stamp(peerB, 200),
        seedClaim: stamp(peerA, 100),
      );

      expect(noticed.recordedBy, peerB);
      expect(noticed.seededBy, peerA);
    });
  });

  group('stamps order by the locked comparator', () {
    test('a later claim about one ULID wins on HLC', () {
      // Contradictions about one ULID resolve by HLC first, peerID second —
      // the library's ordering, reused rather than reimplemented here.
      final older = row(path: 'old.md', recordedAt: stamp(peerC, 100));
      final newer = row(path: 'new.md', recordedAt: stamp(peerA, 200));

      expect(older.recordedAt.compareTo(newer.recordedAt), lessThan(0));
    });

    test('equal clocks fall through to the peerID', () {
      final a = row(recordedAt: stamp(peerA, 100));
      final b = row(recordedAt: stamp(peerB, 100));

      expect(a.recordedAt.compareTo(b.recordedAt), lessThan(0));
    });
  });

  group('equality', () {
    test('rows with identical fields are equal', () {
      final a = row(deleted: true, seedClaim: stamp(peerA, 1));
      final b = row(deleted: true, seedClaim: stamp(peerA, 1));

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('each field participates', () {
      final base = row();

      expect(base, isNot(row(ulid: '01JBQ9YQ7C8VF9YB0X5H3TQ2ZL')));
      expect(base, isNot(row(path: 'inbox/other.md')));
      expect(base, isNot(row(mergePolicy: MergePolicy.blobLww)));
      expect(base, isNot(row(recordedAt: stamp(peerB, 100))));
      expect(base, isNot(row(deleted: true)));
      expect(base, isNot(row(seedClaim: stamp(peerA, 1))));
    });
  });

  test('toString names the note, its state, and who said so', () {
    final text = row(deleted: true, recordedAt: stamp(peerB, 100)).toString();

    expect(text, contains('01JBQ9YQ7C8VF9YB0X5H3TQ2ZK'));
    expect(text, contains('inbox/today.md'));
    expect(text, contains('fugueText'));
    expect(text, contains('deleted'));
    expect(text, contains(peerB.toString()));
  });
}
