// Harness self-check: the determinism substrate the whole suite stands on.
//
// Every "assert the specific winner" case resolves ties through the locked
// comparator (HLC timestamp dominant, then peerID). The peerID half of that is
// only meaningful if the peerID ordering is what this suite assumes. crdt_lf's
// PeerId comparison rule is the LIBRARY's, not this spec's, so we VERIFY it
// here and pin it as an explicit assertion: a surprise must fail loudly rather
// than silently invert an expected winner elsewhere.

import 'package:crdt_lf/crdt_lf.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/peer_ids.dart';
import 'support/replica.dart';

void main() {
  group('peerID fixture ordering (load-bearing)', () {
    test('peerA < peerB < peerC under crdt_lf PeerId comparison', () {
      // The dominant assumption behind every peerID tiebreak in the suite.
      expect(peerA.compareTo(peerB), lessThan(0), reason: 'A must sort below B');
      expect(peerB.compareTo(peerC), lessThan(0), reason: 'B must sort below C');
      expect(peerA.compareTo(peerC), lessThan(0), reason: 'A must sort below C');

      // Transitive spot check via a sort, mirroring how the library orders
      // concurrent operations of equal timestamp.
      final shuffled = [peerC, peerA, peerB]..sort();
      expect(shuffled, [peerA, peerB, peerC]);
    });

    test('the seed author sorts below every named replica', () {
      // Base elements are authored by seedPeer; it must never outrank a real
      // replica in a contested position.
      expect(seedPeer.compareTo(peerA), lessThan(0));
    });

    test('all four fixture IDs are valid, distinct RFC-4122 v4 peerIDs', () {
      final ids = {seedPeer, peerA, peerB, peerC};
      expect(ids.length, 4, reason: 'peerIDs must be distinct');
      // Round-trip through the byte form the library uses on the wire.
      for (final id in ids) {
        expect(PeerId.fromUint8List(id.toUint8List()), id);
      }
    });
  });

  group('replica harness sanity', () {
    test('replicas share a documentId but keep distinct peerIDs', () {
      final replicas = replicaSet(orderedPeers);
      expect(replicas.map((r) => r.doc.documentId).toSet(), {kDocumentId});
      expect(
        replicas.map((r) => r.doc.peerId).toList(),
        [peerA, peerB, peerC],
      );
    });

    test('a shared base is imported symmetrically into every replica', () {
      final replicas = replicaSet(orderedPeers, base: 'the ');
      for (final r in replicas) {
        expect(r.text, 'the ', reason: '${r.label} should hold the base');
      }
    });

    test('base clock is the fixed logical time, dominating wall-clock', () {
      final r = Replica.named(peerA);
      // Fresh replica, no ops yet: clock is exactly the seeded base.
      expect(r.hlc.l, kBaseLogicalTime);
      // After an edit the logical field stays pinned (fixed time still
      // dominates real wall-clock), so it never drifts run to run.
      r.note.insert(0, 'x');
      expect(r.hlc.l, kBaseLogicalTime);
    });
  });
}
