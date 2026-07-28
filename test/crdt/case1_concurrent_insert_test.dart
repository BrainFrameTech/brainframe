// Edge Case 1 — Concurrent same-position insert (interleaving).
//
// The headline case: the reason a sequence CRDT is required rather than
// block-level last-writer-wins. Two replicas insert different runs at what is,
// in offset terms, the same position. The runs must stay CONTIGUOUS and
// INTACT — never shredded character-by-character — and the two runs must land
// in the deterministic order the tiebreak comparator dictates.
//
// Determinism: all replicas share the fixed base clock (see [kBaseLogicalTime]),
// so the genuinely-concurrent inserts carry an identical HLC and the winner
// falls through to peerID. peerA < peerB < peerC (verified in
// peer_ordering_test.dart), so A's run precedes B's precedes C's.

import 'package:flutter_test/flutter_test.dart';

import 'support/convergence.dart';
import 'support/peer_ids.dart';

void main() {
  group('Edge Case 1 — concurrent same-position insert', () {
    // A appends "cat", B appends "dog" at the same end position of "the ".
    // Contiguous runs, ordered by peerID (equal HLC): "the catdog".
    // FAIL if interleaved (e.g. "the cdaotg"). Winner is confirm-then-pin.
    convergesTo(
      'two runs stay contiguous, ordered by the comparator',
      peers: [peerA, peerB],
      base: 'the ',
      edit: (r) {
        r[0].note.insert(4, 'cat'); // A
        r[1].note.insert(4, 'dog'); // B
      },
      expected: 'the catdog',
      confirmThenPin: true,
    );

    // Three replicas at the same anchor → all three runs intact and
    // contiguous, in comparator order A(cat) < B(dog) < C(fish).
    convergesTo(
      'three concurrent runs stay intact and contiguous',
      peers: [peerA, peerB, peerC],
      base: 'the ',
      edit: (r) {
        r[0].note.insert(4, 'cat');
        r[1].note.insert(4, 'dog');
        r[2].note.insert(4, 'fish');
      },
      expected: 'the catdogfish',
      confirmThenPin: true,
    );

    // Concurrent insert at the same INTERIOR position: base "ab", A inserts X
    // and B inserts Y between a and b → "aXYb" (comparator order), never
    // "aXbY"-style corruption of the surrounding text.
    convergesTo(
      'concurrent interior insert does not corrupt surrounding text',
      peers: [peerA, peerB],
      base: 'ab',
      edit: (r) {
        r[0].note.insert(1, 'X'); // between a and b
        r[1].note.insert(1, 'Y');
      },
      expected: 'aXYb',
      confirmThenPin: true,
    );
  });
}
