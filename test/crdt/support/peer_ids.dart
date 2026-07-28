// Deterministic peerID fixture for the CRDT sync edge-case suite.
//
// Every tiebreak in the suite resolves on peerID (see the tiebreak comparator
// in the spec: HLC timestamp dominant, peerID breaking equal timestamps). If
// replicas were given random UUIDs the "assert the specific winner" cases would
// be meaningless, so replicas are always built from these fixed, ordered IDs.
//
// The IDs are human-auditable: each is a single fill letter repeated, so a
// reviewer reads `aaaa… < bbbb… < cccc…` and can confirm a pinned winner
// against the comparator by eye. The version nibble (`4`) and variant nibble
// (`8`) are fixed by RFC-4122 v4 and are the SAME across all peers — they are
// NOT the fill letter. `PeerId.parse` rejects an invalid variant, so the `8`
// must stay `8` for every peer (a "regularized" `a`/`b`/`c` variant nibble
// happens to stay valid, but keeping `8` makes all peers structurally uniform
// and unambiguously valid).
//
// The ordering assumption `peerA < peerB < peerC` is VERIFIED, not assumed, by
// the harness self-check (see peer_ordering_test.dart): crdt_lf's PeerId
// comparison is the library's, not this spec's, and a surprise there must fail
// loudly rather than silently invert an expected winner.

import 'package:crdt_lf/crdt_lf.dart';

/// Replica A's peerID — the lowest in the fixed total order.
final PeerId peerA = PeerId.parse('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa');

/// Replica B's peerID — ordered above [peerA], below [peerC].
final PeerId peerB = PeerId.parse('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb');

/// Replica C's peerID — the highest of the three named replicas.
final PeerId peerC = PeerId.parse('cccccccc-cccc-4ccc-8ccc-cccccccccccc');

/// The three named peerIDs in ascending comparator order.
final List<PeerId> orderedPeers = [peerA, peerB, peerC];

/// Author of shared base content.
///
/// Base text (e.g. `"the "`) is authored once by this peer and replicated into
/// every replica, so all replicas reach the base **symmetrically** (each
/// imports it; none creates it). That symmetry is what lets two replicas' first
/// divergent edits carry an identical HLC, so the tiebreak falls through to
/// peerID — the path the determinism cases mean to exercise.
///
/// Sorts below [peerA] (all-zero fill) so it never wins a contested position
/// against a named replica; base elements are never in contention anyway.
final PeerId seedPeer = PeerId.parse('00000000-0000-4000-8000-000000000000');
