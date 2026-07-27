// Convergence assertion + the automatic commutativity/idempotence wrapper.
//
// The cross-cutting requirements (order independence, idempotence, pin-the-
// value) are enforced structurally here so individual cases cannot skip them:
// a case is expressed once and run through [convergesTo], which replays it
// under multiple merge orderings AND with duplicate delivery, asserting the
// SAME pinned string every time.
//
// Convergence is necessary but not sufficient: two identically-corrupted
// replicas are equal. So the wrapper never asserts merely "A == B" — it asserts
// every replica equals an exact expected string (spec instruction 5).

import 'package:flutter_test/flutter_test.dart';

import 'replica.dart';

/// One merge ordering to exercise: [order] is a permutation of source-replica
/// indices, delivered to every replica in that sequence; [duplicate] re-delivers
/// each source a second time to prove idempotence.
class MergeScenario {
  const MergeScenario(this.label, this.order, {this.duplicate = false});

  /// Human-readable tag surfaced in failure messages.
  final String label;

  /// The order in which each source replica's changes are broadcast.
  final List<int> order;

  /// Whether each delivery is made twice (idempotence).
  final bool duplicate;
}

/// The standard scenario matrix for [n] replicas: forward and reverse delivery
/// orders (commutativity), plus forward-with-duplication (idempotence). For two
/// replicas this is exactly the spec's "A→B and B→A, plus duplicate delivery".
List<MergeScenario> standardScenarios(int n) {
  final forward = [for (var i = 0; i < n; i++) i];
  final reverse = forward.reversed.toList();
  return [
    MergeScenario('forward $forward', forward),
    MergeScenario('reverse $reverse', reverse),
    MergeScenario('forward+dup $forward', forward, duplicate: true),
  ];
}

/// Delivers every replica's **offline** change-set to every replica, in the
/// [scenario]'s order and duplication.
///
/// Each replica's pre-merge export is captured once up front, so the scenario
/// varies only the delivery order/duplication of a fixed set of changes — that
/// is what isolates commutativity and idempotence. Delivering a source to
/// itself is a de-dup no-op (an extra idempotence touch).
void applyMerge(List<Replica> replicas, MergeScenario scenario) {
  final offline = [for (final r in replicas) r.exportChanges()];
  for (final source in scenario.order) {
    for (final target in replicas) {
      target.importChanges(offline[source]);
      if (scenario.duplicate) {
        target.importChanges(offline[source]);
      }
    }
  }
}

/// The high-level convergence wrapper.
///
/// Registers a single [test] that, for every scenario in [standardScenarios],
/// builds fresh replicas (optionally over a shared [base]), applies the offline
/// [edit]s, merges, and asserts every replica materializes exactly [expected].
///
/// [peers] fixes the replica peerIDs (and thus every tiebreak). [clocks], if
/// given, overrides per-replica base clocks (used by the skew cases).
///
/// [confirmThenPin] marks cases whose [expected] value is crdt_lf's *observed*
/// boundary behavior pinned as BrainFrame's expectation (not a load-bearing
/// guarantee). If such a case goes red after a library bump it may be a
/// deliberate change to absorb, not necessarily a bug — see the spec's
/// "two kinds of pinned value".
void convergesTo(
  String description, {
  required List<dynamic> peers,
  required void Function(List<Replica> replicas) edit,
  required String expected,
  String? base,
  List<dynamic>? clocks,
  bool confirmThenPin = false,
}) {
  test(description, () {
    for (final scenario in standardScenarios(peers.length)) {
      final replicas = replicaSet(
        peers.cast(),
        base: base,
        clocks: clocks?.cast(),
      );
      edit(replicas);
      applyMerge(replicas, scenario);

      for (final r in replicas) {
        expect(
          r.text,
          expected,
          reason: 'replica ${r.label} under "${scenario.label}"'
              '${confirmThenPin ? ' [confirm-then-pin]' : ''}',
        );
      }
    }
  });
}
