/// The identity map's row type: what one device claims about one note.
///
/// Platform-neutral, like [catalog.dart](catalog.dart) — `crdt_lf` is pure
/// Dart, and this describes a row rather than where it is stored. The files
/// themselves live in [identity_map_io.dart](identity_map_io.dart).
///
/// **This is the only BrainFrame state that leaves the device.** Everything a
/// row carries is a property of the *note*; anything describing this install —
/// the content hash, the size and mtime beside it, scan state, the peerID
/// itself — stays in `metadata.db`, because Decision 5 shows that sharing a
/// hash converts drift detection into silent data loss.
library;

import 'package:crdt_lf/crdt_lf.dart';

import 'catalog.dart';

/// One device's claim about one note: its identity, where it lives, how it
/// merges, whether it is gone, and who may seed it.
///
/// **A writer writes the whole row, never a delta.** Resolution is per row,
/// not per field, so a device that changed only the path must still carry
/// forward the merge policy, the deleted flag, and the seed claim as it
/// currently understands them. Since every writer reads the directory before
/// writing, it always has a merged row to copy forward; a partial write would
/// silently blank whatever its author did not happen to know about.
class IdentityRow {
  const IdentityRow({
    required this.ulid,
    required this.path,
    required this.mergePolicy,
    required this.recordedAt,
    this.deleted = false,
    this.seedClaim,
  });

  /// The note's stable identity.
  final String ulid;

  /// Engram-relative path, `/`-separated. A rename is this field changing.
  final String path;

  /// How concurrent writes to this note are reconciled.
  ///
  /// Shared rather than derived per device: two devices that disagreed would
  /// apply incompatible semantics to one op-log — character-merging what the
  /// other treats as an opaque blob — which is corruption rather than
  /// divergence. In v1 both would usually derive the same answer from the
  /// extension, and "usually agree by accident" is a worse guarantee than one
  /// shared column.
  final MergePolicy mergePolicy;

  /// When this row was recorded, and by whom.
  ///
  /// The stamp the merge rules need: contradictions about one ULID resolve by
  /// the locked tiebreak comparator, which is exactly `OperationId.compareTo`
  /// (HLC first, peerID second).
  ///
  /// It is load-bearing rather than bookkeeping. A ULID is minted once, but
  /// the *row* about it changes, and not always by the minter: a device that
  /// notices a rename records it, and without a stamp there is no way to tell
  /// its newer claim from the minter's older one. Deletion has the same shape
  /// — with nowhere to record a retraction, a path freed by a delete and
  /// reused later adopts the dead note's ULID and resurrects its history under
  /// unrelated content.
  final OperationId recordedAt;

  /// Whether the note has been deleted. A deletion is an ordinary field
  /// update, needing no special case in the merge.
  final bool deleted;

  /// Who seeded this note's first history and when, or `null` for an
  /// **unclaimed** seed — a map that outlived every op-log backing it.
  ///
  /// Only the holder may seed. A device adopting **this ULID** — finding this
  /// row in another device's file — records the identity and does not seed;
  /// it may take an unclaimed seed on the user's first edit.
  ///
  /// Adopting a *folder* is the opposite case and is not restricted by this.
  /// A directory with no `.brainframe/` has no map to adopt from, so every
  /// file in it is a note nobody has minted: step 12 mints, seeds from the
  /// file's text, and takes the claim for each one. The two senses of "adopt"
  /// must not be run together — one never seeds, the other always does.
  final OperationId? seedClaim;

  /// The peer that recorded this row.
  PeerId get recordedBy => recordedAt.peerId;

  /// The peer that seeded this note, or `null` if the seed is unclaimed.
  PeerId? get seededBy => seedClaim?.peerId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is IdentityRow &&
          other.ulid == ulid &&
          other.path == path &&
          other.mergePolicy == mergePolicy &&
          other.recordedAt == recordedAt &&
          other.deleted == deleted &&
          other.seedClaim == seedClaim;

  @override
  int get hashCode =>
      Object.hash(ulid, path, mergePolicy, recordedAt, deleted, seedClaim);

  @override
  String toString() =>
      'IdentityRow($ulid, $path, ${mergePolicy.name}, '
      '${deleted ? 'deleted' : 'live'}, by $recordedBy)';
}
