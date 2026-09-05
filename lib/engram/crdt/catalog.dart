/// The note catalog's value types: one typed row per note, and the enums that
/// row carries.
///
/// Deliberately free of `dart:io`, `sqlite3`, and `crdt_lf_sqlite`. These
/// describe a *row*, not where it is stored, and `crdt_lf` itself is pure Dart
/// — so the types compile everywhere even though the table cannot. The table
/// and its queries live in [catalog_io.dart](catalog_io.dart), which is
/// `dart:io`-only because SQLite is.
///
/// Parsing here raises [FormatException], the way `PeerId.parse` does. The
/// storage layer is what turns that into a `MetadataDatabaseException`, so the
/// device-local store's strictness stance is expressed in exactly one place.
library;

import 'dart:typed_data';

import 'package:crdt_lf/crdt_lf.dart';

/// How concurrent writes to one note are reconciled (design Decision 3).
///
/// **An open enum, not a boolean.** Vector ink — atomic, immutable,
/// add/delete-only strokes — is a third policy rather than a variation of
/// either of these, and lands as one when #49's deferred half does. Anything
/// switching on this value must stay correct when a third arrives.
///
/// Policy is a property of the *note*, not of the device: two devices that
/// disagreed would apply incompatible semantics to one op-log, which is
/// corruption rather than divergence. It therefore travels in the shared
/// identity map (design Decision 9), and the catalog holds this device's copy.
enum MergePolicy {
  /// The whole file is one `CRDTFugueTextHandler` sequence — the locked model.
  fugueText,

  /// The whole file is one opaque value; concurrent writes resolve by the
  /// locked tiebreak comparator.
  ///
  /// Stores a register, never the bytes: the op-log carries the content hash,
  /// size, and stamp the comparator needs, and the file stays in the engram as
  /// the ordinary file it already is.
  blobLww;

  /// Parses the stored spelling, which is the enum's own [name].
  ///
  /// Throws [FormatException] for anything else rather than falling back to a
  /// default — a value we do not recognise means the row was written by
  /// something that is not this build, and guessing at its semantics is how a
  /// PNG gets character-merged.
  static MergePolicy parse(String value) => values.firstWhere(
    (policy) => policy.name == value,
    orElse: () => throw FormatException('unknown merge policy: "$value"'),
  );
}

/// Extensions that get [MergePolicy.fugueText]; everything else is a blob.
///
/// Compared case-insensitively. Deliberately short: an extension belongs here
/// only once character-level merging of its contents is known to be
/// meaningful, and the cost of leaving one off is a lost concurrent edit that
/// still exists in the loser's history — recoverable, unlike the reverse.
const Set<String> fugueTextExtensions = {'md', 'markdown', 'txt', 'text'};

/// The policy [path] gets at creation, derived from its extension.
///
/// **Unrecognised extensions default to [MergePolicy.blobLww]**, and the
/// asymmetry is the point: character-merging two versions of a PNG produces a
/// corrupt file nobody can recover, while last-writer-wins on text loses one
/// edit that still exists in the loser's history. Default toward the
/// recoverable failure.
///
/// A name with no dot after its last separator — `LICENSE` — and a dotfile
/// with no further dot — `.gitignore` — both have no extension and are
/// therefore blobs. Derivation is v1's rule only: policy is fixed at note
/// creation, and the column's ability to change is reserved, not built.
MergePolicy mergePolicyForPath(String path) =>
    fugueTextExtensions.contains(_extensionOf(path))
    ? MergePolicy.fugueText
    : MergePolicy.blobLww;

/// The lowercase extension of [path] without its dot, or `''` if it has none.
String _extensionOf(String path) {
  final separator = path.lastIndexOf('/');
  final dot = path.lastIndexOf('.');
  // `> separator + 1` rather than `>=`: a leading dot names a hidden file, it
  // does not introduce an extension.
  if (dot <= separator + 1) return '';
  return path.substring(dot + 1).toLowerCase();
}

/// What this device currently believes about a note's existence.
enum NoteState {
  /// Present on disk, with an op-log this device can build on.
  live,

  /// The ULID was adopted from the identity map, but no op-log has arrived yet
  /// (design Decision 7).
  ///
  /// Readable and editable as an ordinary file — the one bounded exception to
  /// "only the materializer writes the file" — until a log lands over #67, at
  /// which point the local file reconciles against it as ordinary drift.
  historyPending,

  /// Deleted: the scan found the path gone with no move or rename candidate.
  tombstoned,

  /// The file should exist but cannot be read right now — an unmounted drive,
  /// a network engram that is offline, an iCloud placeholder not yet
  /// materialized.
  ///
  /// Distinct from [tombstoned] on purpose, mirroring the distinction the
  /// storage design already draws for whole engrams: a file missing because a
  /// drive is unmounted is not a deleted file, and tombstoning one would
  /// destroy a note that is merely out of reach.
  unavailable;

  /// Parses the stored spelling, which is the enum's own [name]. Throws
  /// [FormatException] for anything else.
  static NoteState parse(String value) => values.firstWhere(
    (state) => state.name == value,
    orElse: () => throw FormatException('unknown note state: "$value"'),
  );
}

/// One note, as this device currently understands it.
///
/// Mixes state that travels with the note ([ulid], [path], [mergePolicy], and
/// [seedClaim], all mirrored from the shared identity map) with state that is
/// **device-local and must never be shared** ([materializedHash], [size],
/// [mtimeUtc], [sketch]). Decision 5 explains why sharing the hash converts
/// drift detection into silent data loss; the size, mtime, and sketch beside
/// it describe this device's copy for the same reason.
class CatalogRow {
  const CatalogRow({
    required this.ulid,
    required this.path,
    required this.mergePolicy,
    required this.state,
    this.materializedHash,
    this.size,
    this.mtimeUtc,
    this.sketch,
    this.seedClaim,
  });

  /// The note's stable identity, minted once and never changed.
  final String ulid;

  /// Engram-relative path, `/`-separated.
  final String path;

  /// How concurrent writes to this note are reconciled.
  final MergePolicy mergePolicy;

  /// What this device believes about the note's existence.
  final NoteState state;

  /// Hash of the exact bytes the materializer last wrote, or `null` if this
  /// device has never written the file.
  ///
  /// Drift detection is one comparison against this value. It is **never**
  /// shared: it records what *this device's* materializer last wrote, and two
  /// devices legitimately hold different values at the same instant.
  final String? materializedHash;

  /// Size in bytes of the file as this device last saw it, or `null` if it has
  /// not seen it.
  final int? size;

  /// Modification time of the file as this device last saw it, in UTC.
  final DateTime? mtimeUtc;

  /// Content sketch — shingled MinHash or equivalent — used to re-associate a
  /// note renamed *and* edited in one offline window, or `null` if not yet
  /// computed.
  ///
  /// Device-local derived data: rebuilt by a scan, never shared. It exists to
  /// make the delete-plus-create cell of Decision 7 rare, not to eliminate it.
  final Uint8List? sketch;

  /// Who seeded this note's first history and when, or `null` for an
  /// **unclaimed** seed — a note the identity map knows but no surviving
  /// op-log ever backed.
  ///
  /// An [OperationId] is exactly the pair the design names `seeded_by` and
  /// `seed_hlc`, and its `compareTo` is exactly the locked tiebreak comparator
  /// (HLC first, peerID second) — so contested claims resolve through the
  /// library's ordering rather than a second one written here.
  ///
  /// Only the holder may seed. An adopting device does not; it may *take* an
  /// unclaimed seed on the user's first edit, recording the claim as it seeds.
  final OperationId? seedClaim;

  /// The peer that seeded this note, or `null` if the seed is unclaimed.
  PeerId? get seededBy => seedClaim?.peerId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CatalogRow &&
          other.ulid == ulid &&
          other.path == path &&
          other.mergePolicy == mergePolicy &&
          other.state == state &&
          other.materializedHash == materializedHash &&
          other.size == size &&
          other.mtimeUtc == mtimeUtc &&
          _sketchesEqual(other.sketch, sketch) &&
          other.seedClaim == seedClaim;

  @override
  int get hashCode => Object.hash(
    ulid,
    path,
    mergePolicy,
    state,
    materializedHash,
    size,
    mtimeUtc,
    sketch == null ? null : Object.hashAll(sketch!),
    seedClaim,
  );

  @override
  String toString() =>
      'CatalogRow($ulid, $path, ${mergePolicy.name}, ${state.name})';
}

/// Byte-wise sketch comparison. `Uint8List` equality is identity otherwise, so
/// a row read back from the database would never equal the one written.
bool _sketchesEqual(Uint8List? a, Uint8List? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null || a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
