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

    // Control — the SAME edit done by hand: B removes the 'o' and reinserts '0'
    // via delete+insert (exactly update()'s own delete-old + insert-new recipe)
    // while A concurrently deletes "world". The replacement SURVIVES (→
    // "hello 0"), which proves survival is the correct outcome and isolates the
    // companion's data loss to update() itself — not to editing a deleted run.
    // It also guards the safe primitive path that change() (diff-based bulk
    // edit) compiles to. This is the in-suite foil for the skipped companion.
    convergesTo(
      'manual delete+insert survives a concurrent delete (the update-safe path)',
      peers: [peerA, peerB],
      base: 'hello world',
      edit: (r) {
        r[0].note.delete(6, 5); // A deletes "world"
        r[1].note.delete(7, 1); // B removes the 'o'...
        r[1].note.insert(7, '0'); // ...and reinserts '0' by hand
      },
      expected: 'hello 0',
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
    // is silently dropped → "hello " (data loss) — even though the equivalent
    // hand-written delete+insert (the control test above) survives. Reported
    // upstream as MattiaPispisa/crdt#113. Un-skip when fixed upstream; the
    // assertion then validates the fix. Deterministic convergence and the
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
      skip: 'BLOCKED on crdt_lf update() data-loss bug (MattiaPispisa/crdt#113) '
          '— the replacement is dropped when its target is concurrently '
          'deleted, though the equivalent manual delete+insert (control test '
          'above) survives. Un-skip when fixed upstream.',
    );
  });
}
