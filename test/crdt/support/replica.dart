// The replica abstraction and controlled-order merge harness.
//
// A [Replica] is BrainFrame's locked storage model expressed against crdt_lf's
// public API directly: one `CRDTDocument` plus one `CRDTFugueTextHandler`
// holding the entire note (body + frontmatter) as a single Fugue sequence.
// There is exactly one handler type and one materialization primitive — read
// the handler's `value` as a string.
//
// This suite is pure in-memory unit testing of the data model. Replicas are
// plain in-process objects; operation exchange between them is direct,
// in-harness method calls (`exportChanges`/`importChanges`, or the binary /
// snapshot byte round-trips). Nothing here touches storage, transport, or the
// filesystem, by design.

import 'package:crdt_lf/crdt_lf.dart';
import 'package:hlc_dart/hlc_dart.dart';

import 'peer_ids.dart';

/// The documentId shared by all replicas of the same note.
const String kDocumentId = 'brainframe-note';

/// The single handler id for the whole-note Fugue sequence.
const String kHandlerId = 'note';

/// A fixed logical time used as every replica's base clock.
///
/// The public `insert`/`delete` path stamps each operation's HLC from
/// `DateTime.now()`, which would make "genuinely concurrent" edits depend on
/// wall-clock timing and turn deterministic tiebreak assertions flaky. Seeding
/// every replica's clock to the same large logical time makes that fixed value
/// dominate `max(localPhysical, localHlc, …)`, so genuinely-concurrent ops
/// carry an **identical HLC** and the tiebreak resolves on peerID — the
/// determinism mechanism the suite asserts.
///
/// Chosen to sit far above any real wall-clock millisecond (≈ year 5138) yet
/// well inside the HLC's 48-bit logical field (`< 2^48 ≈ 2.8e14`).
const int kBaseLogicalTime = 100000000000000; // 1e14

/// The 10-minute inflation used by the future-clock cases (Edge Case 3).
const int kTenMinutesMs = 10 * 60 * 1000;

/// A single CRDT replica of the shared note.
///
/// Wraps a live `CRDTDocument` + `CRDTFugueTextHandler`. Construct via
/// [Replica.named] (or the [replicaSet] helper) so the peerID and base clock
/// are fixed and known.
class Replica {
  Replica._(this.doc, this.note, this.label);

  /// Builds a replica with an explicit [peerId] and optional clock override.
  ///
  /// [clock] defaults to the shared [kBaseLogicalTime] base so concurrent
  /// edits tie on HLC; pass a custom clock (e.g. inflated) for the skew cases.
  factory Replica.named(
    PeerId peerId, {
    String label = '',
    HybridLogicalClock? clock,
  }) {
    final doc = CRDTDocument(
      peerId: peerId,
      documentId: kDocumentId,
      initialClock: clock ?? HybridLogicalClock(l: kBaseLogicalTime, c: 0),
    );
    final note = CRDTFugueTextHandler(doc, kHandlerId);
    return Replica._(doc, note, label.isEmpty ? peerId.toString() : label);
  }

  /// The underlying CRDT document.
  final CRDTDocument doc;

  /// The single whole-note Fugue text handler.
  final CRDTFugueTextHandler note;

  /// A short human-readable tag for assertion messages.
  final String label;

  /// The materialized note as a string — the suite's single assertion
  /// primitive. Under the locked storage model body and frontmatter are one
  /// sequence, so there is exactly one thing to read.
  String get text => note.value;

  /// This replica's current logical clock.
  HybridLogicalClock get hlc => doc.hlc;

  /// Exports every change this replica currently holds.
  List<Change> exportChanges() => doc.exportChanges();

  /// Imports [changes] (already-known changes are de-duplicated internally).
  /// Returns the number newly applied.
  int importChanges(List<Change> changes) => doc.importChanges(changes);
}

/// A clock inflated by [msFast] milliseconds over the shared base — the
/// "device with a fast physical clock" of Edge Case 3.
HybridLogicalClock fastClock(int msFast) =>
    HybridLogicalClock(l: kBaseLogicalTime + msFast, c: 0);

/// Builds `peers.length` fresh replicas, one per peerID, all sharing
/// [kDocumentId] and (unless [clocks] overrides) the shared base clock.
///
/// If [base] is given, that text is authored once by [seedPeer] and imported
/// into every replica, so all replicas reach the base symmetrically.
List<Replica> replicaSet(
  List<PeerId> peers, {
  String? base,
  List<HybridLogicalClock?>? clocks,
}) {
  final replicas = <Replica>[];
  for (var i = 0; i < peers.length; i++) {
    replicas.add(
      Replica.named(
        peers[i],
        label: String.fromCharCode('A'.codeUnitAt(0) + i),
        clock: clocks != null ? clocks[i] : null,
      ),
    );
  }
  if (base != null && base.isNotEmpty) {
    final baseChanges = seedBaseChanges(base);
    for (final r in replicas) {
      r.importChanges(baseChanges);
    }
  }
  return replicas;
}

/// Produces the changes for a shared [base] text authored by [seedPeer].
///
/// Generated on a throwaway seed replica so the base is owned by neither A, B
/// nor C; every real replica then imports it symmetrically.
List<Change> seedBaseChanges(String base) {
  final seed = Replica.named(seedPeer, label: 'seed');
  seed.note.insert(0, base);
  return seed.exportChanges();
}
