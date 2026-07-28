// Edge Case 5 — Convergence after snapshot / garbage collection.
//
// The highest-risk untested interaction: a peer that garbage-collected history
// reconciling with a peer that was behind. `takeSnapshot` is non-destructive,
// but `garbageCollect` strands any peer not in the VersionVector.intersection.
// This is a data-model convergence question (in scope) rather than a transport
// one, hence its place in this suite.

import 'package:flutter_test/flutter_test.dart';

import 'support/peer_ids.dart';
import 'support/replica.dart';

void main() {
  group('Edge Case 5a — snapshot is non-destructive to convergence', () {
    // Taking a snapshot (history retained) must not change the converged
    // result of a subsequent concurrent edit. Run the identical scenario with
    // and without an intervening snapshot; both must land on the same pinned
    // value.
    String runConcurrentEdit({required bool withSnapshot}) {
      final replicas = replicaSet([peerA, peerB], base: 'note: ');
      final a = replicas[0];
      final b = replicas[1];

      if (withSnapshot) {
        a.doc.takeSnapshot(pruneHistory: false); // history retained
      }

      a.note.insert(6, 'a'); // concurrent edits at the same anchor
      b.note.insert(6, 'b');

      final aChanges = a.exportChanges();
      final bChanges = b.exportChanges();
      a.importChanges(bChanges);
      b.importChanges(aChanges);
      b.importChanges(aChanges); // duplicate delivery (idempotence)

      expect(a.text, b.text, reason: 'replicas must converge');
      return a.text;
    }

    test('snapshot does not alter the converged value', () {
      final withoutSnapshot = runConcurrentEdit(withSnapshot: false);
      final withSnapshot = runConcurrentEdit(withSnapshot: true);

      // Pinned meaningful value (comparator order A('a') < B('b')).
      expect(withoutSnapshot, 'note: ab');
      // The load-bearing property: snapshotting changed nothing.
      expect(withSnapshot, withoutSnapshot);
    });
  });

  group('Edge Case 5b — GC strands a peer below the frontier', () {
    // A and B are synced; C has been offline and is behind the version-vector
    // frontier. A garbage-collects, pruning history C still needs. The stranded
    // condition must be DETECTED (not silent divergence, not a crash), and a
    // cold resync from A's snapshot must bring C to byte-identical convergence.
    test('stranding is detected and cold resync recovers C', () {
      final a = Replica.named(peerA);
      final b = Replica.named(peerB);
      final c = Replica.named(peerC);

      // Baseline shared by A and B only; C stays offline and behind.
      a.note.insert(0, 'base');
      final baseline = a.exportChanges();
      b.importChanges(baseline);

      // A and B advance together, then A snapshots and GCs to its own frontier
      // — a frontier that EXCLUDES the offline C.
      a.note.insert(4, ' more');
      b.importChanges(a.exportChanges());
      final snapshot = a.doc.takeSnapshot(); // pruneHistory: true (default)
      a.doc.garbageCollect(a.doc.getVersionVector());

      expect(a.text, 'base more');
      expect(b.text, 'base more');

      // --- Detection: C is provably behind A's GC frontier. ---
      // The operational signal an app uses to decide "C needs a cold resync":
      // A's snapshot version vector is strictly newer than everything C has.
      expect(
        snapshot.versionVector.isStrictlyNewerThan(c.doc.getVersionVector()),
        isTrue,
        reason: 'C is behind the snapshot frontier — stranding is detectable',
      );

      // Incremental sync is INSUFFICIENT: the history C needs was pruned, so
      // A has no incremental changes to offer and C stays diverged. Crucially,
      // this leaves C observably NOT converged (empty), rather than silently
      // "converged" to a wrong value or crashing.
      final incremental = a.exportChanges();
      for (final change in incremental) {
        c.doc.applyChange(change); // must not crash
      }
      expect(
        c.text,
        isNot('base more'),
        reason: 'incremental sync alone cannot recover a stranded peer',
      );

      // --- Recovery: cold resync from A's snapshot. ---
      final imported = c.doc.importSnapshot(snapshot);
      expect(imported, isTrue, reason: 'snapshot applies to the stranded peer');
      expect(c.text, 'base more', reason: 'C converges byte-identically');
      expect(c.text, a.text);
      expect(c.text, b.text);
    });
  });
}
