/// The rows this device has authored in the shared identity map, and the one
/// file they are written to.
///
/// `dart:io`-only by way of [IdentityMap]. Decision 9's writing rule, made
/// into an object: a device writes rows only for notes it **authored** — those
/// it minted, and those whose path or deleted status it changed — and never
/// rewrites a row it merely learned by reading another device's file. This
/// class is the set of rows that rule admits, kept in memory for the life of
/// a session, loaded from this device's own file on open and rewritten whole
/// through the debounced writer whenever it changes.
///
/// It is the answer to step 11's "the write that keeps the map honest". A
/// rename that updates the catalog and stops there leaves the map saying the
/// old path, and a third device opening the engram cold then mints a fresh
/// ULID for the new one — exactly the mis-identification the map exists to
/// prevent, and unlike a bad adoption it never surfaces. So every catalog
/// change that is an identity claim passes through [record] as well.
library;

import 'package:crdt_lf/crdt_lf.dart';
import 'package:hlc_dart/hlc_dart.dart';

import 'catalog.dart';
import 'identity_map.dart';
import 'identity_map_io.dart';

/// This device's claims about notes, and where they go.
class AuthoredIdentity {
  AuthoredIdentity._(this.map, this._rows, this._name);

  /// The file, and the reader over every device's file beside it.
  final IdentityMap map;

  final Map<String, IdentityRow> _rows;
  late final DebouncedIdentityMapWriter _writer;

  /// What this device last published itself as. Loaded with the rows and
  /// written with them every time, so a rewrite for a claim never drops a
  /// name published earlier.
  PeerName? _name;

  /// Loads what this device last wrote, so the next write carries every
  /// earlier claim forward. A device that started from an empty set would
  /// republish only its newest claim and silently retract the rest.
  ///
  /// [writer] overrides the debounced writer, so a test can drive its timers
  /// or capture its rows without a filesystem. One that writes with
  /// `map.write` alone writes no name; the default writes the name too.
  static Future<AuthoredIdentity> load(
    IdentityMap map, {
    DebouncedIdentityMapWriter? writer,
  }) async {
    final rows = <String, IdentityRow>{
      for (final row in await map.readOurs()) row.ulid: row,
    };
    final identity = AuthoredIdentity._(map, rows, map.readOurName());
    identity._writer =
        writer ??
        DebouncedIdentityMapWriter(
          (rows) => map.write(rows, self: identity._name),
        );
    return identity;
  }

  /// What this device last published itself as, or null if it never has.
  PeerName? get name => _name;

  /// Publishes [name] — already resolved and normalized — as what this
  /// device is called in this engram, on [platform], and schedules the file
  /// to be rewritten. Returns whether anything changed.
  ///
  /// **Quiet when nothing did.** Every open publishes, and a file rewritten
  /// on every open is a file the sync service ships on every open; so a
  /// name and platform already published leave the file, and its stamp,
  /// alone.
  bool publishName(String name, {required String platform}) {
    final current = _name;
    if (current != null &&
        current.name == name &&
        current.platform == platform) {
      return false;
    }
    _name = PeerName(
      peer: map.peerId,
      name: name,
      platform: platform,
      setAt: HybridLogicalClock.now(),
    );
    _writer.schedule(_rows.values.toList());
    return true;
  }

  /// The rows this device has authored, by ULID.
  Map<String, IdentityRow> get rows => Map.unmodifiable(_rows);

  /// Records a claim about one note and schedules the file to be rewritten.
  ///
  /// **The whole row, never a delta.** The caller passes the row as it now
  /// understands it — path, policy, deleted flag, seed claim — because
  /// resolution across devices is per row, and a field the caller did not
  /// carry forward is a field it just blanked for everyone. The row is stamped
  /// with this device's peer and the current clock, which is what lets a
  /// later reader tell this claim from an older one about the same note.
  ///
  /// [deleted] is passed separately because the catalog's [NoteState] is
  /// richer than the map's flag: a tombstone is deleted, everything else is
  /// not, and the caller says which rather than this class guessing.
  void record(CatalogRow note, {required bool deleted}) {
    _rows[note.ulid] = IdentityRow(
      ulid: note.ulid,
      path: note.path,
      mergePolicy: note.mergePolicy,
      recordedAt: OperationId(map.peerId, HybridLogicalClock.now()),
      deleted: deleted,
      seedClaim: note.seedClaim,
    );
    _writer.schedule(_rows.values.toList());
  }

  /// Re-records every claim in [ours] — the catalog rows this device
  /// seeded, tombstones included — that the loaded file lacks or states
  /// differently. Returns how many were recorded.
  ///
  /// The file is written through a debounce, and a process can end inside
  /// that window: a device that opened an engram, minted every note in it,
  /// and quit within five seconds had claims in memory and nothing on disk.
  /// Before this, those claims were gone for good — [load] takes "ours" from
  /// the file, and nothing ever asked the catalog what the file should have
  /// said. So every other device kept minting its own identity for every
  /// note this one held, and no election could ever retire either side.
  ///
  /// The catalog is the truth for a device's own mints, so the file can be
  /// rebuilt from it: a row seeded by this peer is a claim this peer owes,
  /// with the path and policy the catalog holds now and "deleted" for a
  /// tombstone. What this does not cover is a claim about a note another
  /// device seeded — a rename, or a deletion, of an adopted note — which the
  /// catalog cannot distinguish from an unchanged adoption; those rely on
  /// the write reaching the disk, which is what the session's flush on quit
  /// is for.
  ///
  /// Idempotent and quiet: a row already stated the same way is left alone,
  /// so a healthy open schedules no write.
  int repairFrom(Iterable<CatalogRow> ours) {
    var repaired = 0;
    for (final note in ours) {
      if (note.seededBy != map.peerId) continue;
      final deleted = note.state == NoteState.tombstoned;
      final existing = _rows[note.ulid];
      if (existing != null &&
          existing.path == note.path &&
          existing.mergePolicy == note.mergePolicy &&
          existing.deleted == deleted &&
          existing.seedClaim == note.seedClaim) {
        continue;
      }
      record(note, deleted: deleted);
      repaired++;
    }
    return repaired;
  }

  /// Writes now if anything is owed. The session calls this on the way out,
  /// so closing an engram never strands a rename in the timers.
  Future<void> flush() => _writer.flush();

  /// Drops any pending write. For a session that is being torn down without
  /// a chance to flush. What was lost is this device's own claims, which the
  /// next open rebuilds from the catalog ([repairFrom]); a rename or a
  /// deletion of an adopted note is not rebuilt, which is why the session
  /// flushes on quit rather than disposing.
  void dispose() => _writer.dispose();
}
