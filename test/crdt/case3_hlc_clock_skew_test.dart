// Edge Case 3 — Future-clock fairness skew (HLC max rule).
//
// HLC protects CAUSAL ordering unconditionally (3a, the load-bearing
// guarantee), but a badly-set physical clock skews the FAIRNESS of tiebreaks
// between genuinely-concurrent edits (3b, the documented wart). This case
// separates the guarantee from the wart.

import 'package:flutter_test/flutter_test.dart';

import 'support/peer_ids.dart';
import 'support/replica.dart';

void main() {
  group('Edge Case 3a — causality survives a broken clock (guarantee)', () {
    // NOTE: unlike every other case, 3a's "both delivery orders" IS the
    // assertion, not the commutativity wrapper. The point is that no delivery
    // order can make the dependent op sort before its dependency, so 3a is NOT
    // routed through convergesTo.
    //
    // Replica P runs 10 minutes fast. P inserts "X", then makes a second op
    // that causally depends on the first (deletes "X"). Delivered to a
    // correct-clock Q in BOTH orders and with duplication, the delete must
    // never sort before the insert — proven by Q converging to EMPTY (had the
    // delete sorted first it would no-op and "X" would survive).
    test('dependent op never sorts before its dependency', () {
      final p = Replica.named(peerA, clock: fastClock(kTenMinutesMs));
      p.note.insert(0, 'X');
      p.note.delete(0, 1); // causally depends on the insert
      final ops = p.exportChanges();

      // Each entry is a list of separate delivery batches to a fresh Q. Batch
      // order within a call is irrelevant (importChanges topologically sorts);
      // idempotence is a SECOND delivery call (a re-delivery deduped by the
      // store), not duplicates crammed into one batch.
      final deliveries = <String, List<List<dynamic>>>{
        'insert-before-delete': [ops],
        'delete-before-insert': [ops.reversed.toList()],
        'duplicated re-delivery': [ops, ops],
      };

      deliveries.forEach((label, batches) {
        final q = Replica.named(peerB); // honest clock
        // Must not throw on out-of-causal-order or re-delivery.
        for (final batch in batches) {
          q.importChanges(batch.cast());
        }
        expect(
          q.text,
          '',
          reason: 'causal order must hold under "$label": delete applies '
              'after insert, so Q is empty',
        );
      });
    });
  });

  group('Edge Case 3b — fairness skew observable, convergence holds', () {
    // P (10 min fast) and Q (correct clock) each make a genuinely-concurrent
    // insert at the same frontmatter anchor — the real-world shape of this
    // conflict under the locked storage model (frontmatter is text in the same
    // Fugue sequence).
    //
    // Load-bearing (must always hold): convergence to a single value, both runs
    // contiguous/intact, and Q's clock dragged forward to at least P's time.
    //
    // CONFIRM-THEN-PIN: the ordering DIRECTION is the library's, re-pinned at
    // crdt_lf 3.5.0. Under 3.4.2 the inflated run sorted LAST
    // ("status: wipdone"), which the spec recorded as a deviation from its own
    // prose. 3.5.0 made the replay order explicit (`compareChangeOrder`, the
    // `(hlc, author)` order changes are replayed in) and the direction now
    // matches the spec's original theory: P's inflated HLC sorts its run FIRST
    // → "status: donewip".
    //
    // Re-pinned consciously, not adapted to blindly. The flip was verified to
    // be a genuine ordering change and not a materialization artifact of
    // 3.5.0's new incremental-fold cache: both replicas converge on the same
    // string under both delivery orders, and a cold third replica replaying
    // every change from scratch (which never touches the cache) produces the
    // same "status: donewip". The load-bearing guarantees below — exact
    // convergence, runs intact, clock jump — held across the bump untouched;
    // only the confirm-then-pin direction moved.
    void runSkew(String label, bool deliverPtoQfirst) {
      final replicas = replicaSet(
        [peerA, peerB],
        base: 'status: ',
        clocks: [fastClock(kTenMinutesMs), null], // A(=P) fast, B(=Q) honest
      );
      final p = replicas[0];
      final q = replicas[1];
      p.note.insert(8, 'done'); // fast replica's run
      q.note.insert(8, 'wip'); // honest replica's run

      final pOpTime = p.hlc.l; // inflated logical time of P's op
      final pChanges = p.exportChanges();
      final qChanges = q.exportChanges();

      if (deliverPtoQfirst) {
        q.importChanges(pChanges);
        p.importChanges(qChanges);
        q.importChanges(pChanges); // duplicate delivery (idempotence)
      } else {
        p.importChanges(qChanges);
        q.importChanges(pChanges);
        p.importChanges(qChanges); // duplicate delivery (idempotence)
      }

      // Convergence — pin the exact value, never merely "p == q".
      expect(p.text, 'status: donewip', reason: '$label: P converged value');
      expect(q.text, 'status: donewip', reason: '$label: Q converged value');

      // Both runs remain contiguous and intact — skew changes which run wins
      // the ordering, never whether runs stay whole.
      expect(p.text.contains('done'), isTrue, reason: '$label: "done" intact');
      expect(p.text.contains('wip'), isTrue, reason: '$label: "wip" intact');

      // Q's clock jumped forward to at least P's inflated op time
      // (max-and-increment propagates the fast clock).
      expect(
        q.hlc.l,
        greaterThanOrEqualTo(pOpTime),
        reason: '$label: Q post-merge logical time >= P op time',
      );
    }

    test('converges + contiguous + clock jump (P->Q first)', () {
      runSkew('P->Q first', true);
    });
    test('converges + contiguous + clock jump (Q->P first)', () {
      runSkew('Q->P first', false);
    });
  });
}
