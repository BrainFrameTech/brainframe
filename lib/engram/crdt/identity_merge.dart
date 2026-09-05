/// Resolving every device's identity-map rows into one view, and deciding what
/// to do about a note as a result.
///
/// Platform-neutral: this is arithmetic over rows, with no storage anywhere in
/// it. The reader that produces those rows is
/// [identity_map_io.dart](identity_map_io.dart), which deliberately returns
/// contradictions unresolved so that resolving them happens here, once, where
/// it can be tested without a filesystem.
///
/// **Two rules answering different questions**, and they must not be confused
/// for one another:
///
/// 1. *Contradictions about one ULID* — two devices each holding a row for it —
///    resolve by the **locked tiebreak comparator**, HLC first and peerID
///    second, which is exactly `OperationId.compareTo`. Latest wins, the way a
///    last-writer-wins register does.
/// 2. *Two live ULIDs claiming one path* — both devices cold-minted for the
///    same file — elect the **lowest ULID**. This deliberately does not use the
///    comparator: it is an election between distinct identities rather than a
///    last-writer-wins over one value, and the answer that should survive is
///    the earliest mint rather than the latest claim. ULIDs are time-ordered,
///    so the lowest is the earliest.
library;

import 'package:crdt_lf/crdt_lf.dart';

import 'identity_map.dart';

/// Every device's claims, resolved into one view of the engram.
class MergedIdentity {
  const MergedIdentity({
    required this.byUlid,
    required this.pathOwners,
    required this.retired,
    required this.contestedSeeds,
  });

  /// The surviving row for each ULID anyone has a row for, including ULIDs
  /// that are deleted or that lost a path election. Identity outlives both.
  final Map<String, IdentityRow> byUlid;

  /// Which ULID owns each live path.
  ///
  /// Deleted rows own nothing: a path a tombstoned note used to occupy is a
  /// free path, and the next note created there is a new note. Without that,
  /// a path freed by a delete and reused later would adopt the dead note's
  /// ULID and resurrect its history under unrelated content.
  final Map<String, String> pathOwners;

  /// ULIDs that lost a path election and must be retired locally.
  ///
  /// A device holding one of these **adopts the winning ULID and retires its
  /// own document**; it does not re-key onto the winner. Re-keying looks free,
  /// since a `Change` never carries a document id and the id is only a column,
  /// but both documents were independently seeded — so re-pointing one at the
  /// other's id puts two disjoint element universes under one document, which
  /// is the duplication
  /// [independent_seed_duplication_test.dart](../../../test/crdt/independent_seed_duplication_test.dart)
  /// pins. Re-keying is safe only where nothing occupies the destination id,
  /// which is precisely what a contested path is not.
  final Set<String> retired;

  /// ULIDs whose seed was claimed by more than one device, mapped to the claim
  /// that won.
  ///
  /// The one remaining race: two devices both take an *unclaimed* seed while
  /// offline. A device that finds its own claim is not the winning one here
  /// must retract the elements it seeded — it knows exactly which they are —
  /// and reconcile its file against the winner's content as ordinary drift.
  final Map<String, OperationId> contestedSeeds;

  /// The row owning [path], or `null` if no live note claims it.
  IdentityRow? forPath(String path) {
    final ulid = pathOwners[path];
    return ulid == null ? null : byUlid[ulid];
  }

  /// The surviving row for [ulid], whatever its state.
  IdentityRow? forUlid(String ulid) => byUlid[ulid];
}

/// Resolves [rows] — the union of every device's map file — into one view.
///
/// Takes rows exactly as read, including several for one ULID and several
/// claiming one path, and applies the two rules in order: contradictions about
/// a ULID first, then the election between ULIDs that survive it.
MergedIdentity mergeIdentity(Iterable<IdentityRow> rows) {
  final byUlid = <String, IdentityRow>{};
  final seedClaims = <String, Set<OperationId>>{};

  // Rule 1, plus the seed contest. The seed is resolved separately from the
  // row: a device can record a newer row — noticing a rename, say — without
  // that making it the seeder, so carrying the winning row's claim blindly
  // could drop a claim that is still the real one.
  for (final row in rows) {
    final winner = byUlid[row.ulid];
    if (winner == null || row.recordedAt.compareTo(winner.recordedAt) > 0) {
      byUlid[row.ulid] = row;
    }
    final claim = row.seedClaim;
    if (claim != null) {
      (seedClaims[row.ulid] ??= <OperationId>{}).add(claim);
    }
  }

  final contestedSeeds = <String, OperationId>{};
  for (final entry in seedClaims.entries) {
    final claims = entry.value.toList()..sort();
    final winning = claims.last;
    final row = byUlid[entry.key]!;
    if (row.seedClaim != winning) {
      byUlid[entry.key] = IdentityRow(
        ulid: row.ulid,
        path: row.path,
        mergePolicy: row.mergePolicy,
        recordedAt: row.recordedAt,
        deleted: row.deleted,
        seedClaim: winning,
      );
    }
    if (claims.length > 1) contestedSeeds[entry.key] = winning;
  }

  // Rule 2. Only live rows contend for a path.
  final claimants = <String, List<String>>{};
  for (final row in byUlid.values) {
    if (row.deleted) continue;
    (claimants[row.path] ??= <String>[]).add(row.ulid);
  }

  final pathOwners = <String, String>{};
  final retired = <String>{};
  for (final entry in claimants.entries) {
    final ulids = entry.value..sort();
    pathOwners[entry.key] = ulids.first;
    retired.addAll(ulids.skip(1));
  }

  return MergedIdentity(
    byUlid: byUlid,
    pathOwners: pathOwners,
    retired: retired,
    contestedSeeds: contestedSeeds,
  );
}

/// What a device should do about one path, given the merged map.
///
/// **"Adopt" means two different things and they must not be run together.**
/// Adopting a *folder* is [mint] applied to every file in it, because a folder
/// with no marker has no map to adopt from. Adopting a *ULID* is the other
/// three, and none of them seeds on sight.
enum NoteDisposition {
  /// No live row claims this path: the user's own file, first open. Mint a
  /// ULID, seed from the file's text, and take the claim.
  mint,

  /// A row exists and its seed claim is held by another device. Record the
  /// ULID and **do not seed** — the note is history-pending until a log
  /// arrives. Seeding here is the duplication hazard: Fugue merges on element
  /// identity, so two independent seeds of identical text merge to doubled
  /// text rather than to identical text.
  adoptPending,

  /// A row exists with no seed claim at all — the map outlived every op-log
  /// that ever backed it. Record the ULID; seed and claim on the user's first
  /// *edit*, not on open.
  ///
  /// The deferral is what stops the race being provoked: two devices merely
  /// opening the engram offline would otherwise both stake a claim to a seed
  /// neither is using. The race stays handled if it happens anyway — the
  /// comparator picks a winner and the loser retracts — but it is not invited.
  adoptClaimable,

  /// A row exists and this device holds its seed claim: our own note, read
  /// back out of our own map file. Nothing to adopt and nothing to seed.
  alreadyOurs,
}

/// The disposition for [path] under [merged], for the device [self].
NoteDisposition dispositionForPath(
  MergedIdentity merged,
  String path, {
  required PeerId self,
}) {
  final row = merged.forPath(path);
  if (row == null) return NoteDisposition.mint;
  if (row.seedClaim == null) return NoteDisposition.adoptClaimable;
  return row.seededBy == self
      ? NoteDisposition.alreadyOurs
      : NoteDisposition.adoptPending;
}

/// Whether [self] lost a contested seed for [ulid] and must retract what it
/// seeded.
///
/// False when the seed was never contested, when this device never claimed it,
/// and when this device's claim is the winning one.
bool mustRetractSeed(
  MergedIdentity merged,
  String ulid, {
  required OperationId? ourClaim,
}) {
  final winning = merged.contestedSeeds[ulid];
  if (winning == null || ourClaim == null) return false;
  return ourClaim != winning;
}
