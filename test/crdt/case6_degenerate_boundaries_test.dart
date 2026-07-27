// Edge Case 6 — Empty and degenerate boundaries.
//
// The trivial bases the headline cases stand on — empty documents, delete-to-
// empty, no-op merges, redundant re-delivery — are exactly where off-by-one and
// null-anchor bugs live. Each is cheap; collectively they cover a category the
// interesting cases assume away.

import 'package:flutter_test/flutter_test.dart';

import 'support/convergence.dart';
import 'support/peer_ids.dart';
import 'support/replica.dart';

void main() {
  group('Edge Case 6 — degenerate boundaries', () {
    // 6a — concurrent insert into an EMPTY document at position 0. Same
    // tiebreak rule as Case 1, degenerate base: contiguous, deterministic,
    // comparator order A("cat") < B("dog").
    convergesTo(
      '6a — concurrent insert into empty doc converges deterministically',
      peers: [peerA, peerB],
      edit: (r) {
        r[0].note.insert(0, 'cat');
        r[1].note.insert(0, 'dog');
      },
      expected: 'catdog',
      confirmThenPin: true,
    );

    // 6b — delete-to-empty then concurrent insert: A deletes all content while
    // B concurrently inserts into what A is emptying. B's insert survives at
    // the whole-document boundary; no dangling-anchor crash (Case 2's tombstone
    // machinery at the document edge).
    convergesTo(
      '6b — delete-to-empty vs concurrent insert, no dangling-anchor crash',
      peers: [peerA, peerB],
      base: 'hi',
      edit: (r) {
        r[0].note.delete(0, 2); // A empties the document
        r[1].note.insert(2, '!'); // B inserts into what A is emptying
      },
      expected: '!',
      confirmThenPin: true,
    );

    // 6c — one side makes NO changes. The no-op merge must be a clean identity:
    // B converges to A's state and A is unchanged — no divergence, no spurious
    // rewrite. Checked in both merge directions.
    test('6c — no-op merge is a clean identity in both directions', () {
      final a = Replica.named(peerA);
      final b = Replica.named(peerB); // makes zero operations
      a.note.insert(0, 'hello');

      final aChanges = a.exportChanges();
      final bChanges = b.exportChanges(); // empty

      // A -> B
      b.importChanges(aChanges);
      // B -> A (B contributed nothing)
      a.importChanges(bChanges);

      expect(b.text, 'hello', reason: 'B converges to A');
      expect(a.text, 'hello', reason: 'A is unchanged by the empty merge');
    });

    // 6d — idempotent re-merge of an already-merged op: delivering a fully-
    // merged operation a THIRD time must not change the converged state.
    test('6d — redundant re-delivery of a merged op changes nothing', () {
      final a = Replica.named(peerA);
      final b = Replica.named(peerB);
      a.note.insert(0, 'hi');
      final changes = a.exportChanges();

      final first = b.importChanges(changes); // 1st delivery — applies
      final second = b.importChanges(changes); // 2nd — already merged
      final third = b.importChanges(changes); // 3rd — redundant

      expect(first, greaterThan(0), reason: 'first delivery applies the op');
      expect(second, 0, reason: 'second delivery applies nothing new');
      expect(third, 0, reason: 'third delivery applies nothing new');
      expect(b.text, 'hi', reason: 'converged value is unchanged');
    });
  });
}
