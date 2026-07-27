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

    // Companion — edit STRICTLY INSIDE a single deleted element: B replaces the
    // 'o' in "world" with '0' (an update = delete-old + insert-new) while A
    // deletes all of "world".
    //
    // REQUIREMENT: the replacement must NOT be lost. Per the locked semantic a
    // plain insert in this exact position survives and reattaches (→ "hello 0",
    // verified), and update()'s internal insert must behave the same. Losing
    // typed input is the one failure the storage model calls unacceptable, so
    // this asserts survival, NOT the library's current output. It is not a
    // confirm-then-pin observation — data loss is never a value we accept.
    //
    // KNOWN-FAILING (skip): crdt_lf 3.4.2 ties update()'s replacement to the
    // liveness of the element it replaces, so under a concurrent delete the '0'
    // is silently dropped → "hello " (data loss). Minimal repro:
    // docs/testing/crdt_update_reattach_repro.dart. Un-skip when fixed upstream;
    // the assertion then validates the fix. Deterministic convergence and the
    // no-dangling-identity-crash guarantee both already hold regardless.
    convergesTo(
      'update inside a fully-deleted run preserves the replacement (no loss)',
      peers: [peerA, peerB],
      base: 'hello world',
      edit: (r) {
        r[0].note.delete(6, 5); // A deletes "world"
        r[1].note.update(7, '0'); // B: 'o' -> '0' inside "world"
      },
      expected: 'hello 0',
      skip: 'BLOCKED on crdt_lf update() data-loss bug — replacement dropped '
          'when its target is concurrently deleted. See '
          'docs/testing/crdt_update_reattach_repro.dart. Un-skip when fixed.',
    );
  });
}
