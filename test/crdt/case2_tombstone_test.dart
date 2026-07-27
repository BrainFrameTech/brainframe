// Edge Case 2 — Delete then concurrent edit of the deleted region (tombstones).
//
// Sequence CRDTs leave tombstones so identities referenced by concurrent
// operations stay resolvable. This defends that machinery: referencing a
// deleted identity must resolve (never crash), and the reattachment rule must
// be deterministic and match the LOCKED semantic — insert-survives-at-boundary:
// an insert anchored BETWEEN two elements survives even if its neighbours are
// concurrently deleted, reattaching to the nearest living anchor.
//
// (The exact converged strings are confirm-then-pin: they pin crdt_lf's
// observed reattachment boundary as BrainFrame's expectation.)

import 'package:flutter_test/flutter_test.dart';

import 'support/convergence.dart';
import 'support/peer_ids.dart';

void main() {
  group('Edge Case 2 — delete vs concurrent edit (tombstones)', () {
    // A deletes the word "world"; B concurrently inserts "!" between "wor|ld" —
    // anchored between elements A is deleting. Per the locked semantic B's "!"
    // survives, reattached to the nearest living anchor → "hello !".
    // No crash / no dangling-identity error / insert not discarded.
    convergesTo(
      'insert between deleted elements survives at the boundary',
      peers: [peerA, peerB],
      base: 'hello world',
      edit: (r) {
        r[0].note.delete(6, 5); // A deletes "world"
        r[1].note.insert(9, '!'); // B: "hello wor!ld"
      },
      expected: 'hello !',
      confirmThenPin: true,
    );

    // Companion — edit STRICTLY INSIDE a single deleted element, with no
    // surviving between-neighbour anchor: B replaces the 'o' in "world" with
    // '0' (an update = delete-old + insert-new) while A deletes all of "world".
    //
    // Observed: the replacement '0' is DISCARDED (its entire anchoring run is
    // gone, so it has no living between-neighbour to reattach to) → "hello ".
    // The load-bearing assertions here are: deterministic convergence and NO
    // dangling-identity crash — both hold. That the replacement does not
    // survive (whereas the between-elements insert above does) is an observed
    // asymmetry surfaced to the human, not a silently-adopted rule.
    convergesTo(
      'update inside a fully-deleted run resolves deterministically, no crash',
      peers: [peerA, peerB],
      base: 'hello world',
      edit: (r) {
        r[0].note.delete(6, 5); // A deletes "world"
        r[1].note.update(7, '0'); // B: 'o' -> '0' inside "world"
      },
      expected: 'hello ',
      confirmThenPin: true,
    );
  });
}
