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

import 'dart:async';
import 'dart:developer' as developer;

import 'package:crdt_lf/crdt_lf.dart';
import 'package:hlc_dart/hlc_dart.dart';

import 'catalog.dart';
import 'identity_map.dart';
import 'identity_map_io.dart';

/// This device's claims about notes, and where they go.
class AuthoredIdentity {
  AuthoredIdentity._(this.map, this._rows, this._name, this._loaded);

  /// The file, and the reader over every device's file beside it.
  final IdentityMap map;

  /// This device's claims: the file's, merged with this session's. Until
  /// the file has loaded, this session's alone.
  final Map<String, IdentityRow> _rows;
  late final DebouncedIdentityMapWriter _writer;

  /// What this device last published itself as. Loaded with the rows and
  /// written with them every time, so a rewrite for a claim never drops a
  /// name published earlier.
  PeerName? _name;

  /// Whether this session set [_name], rather than loading it: the newer of
  /// the two when the file is merged in late.
  bool _nameSetHere = false;

  /// Whether this device's own file has been read (the device names
  /// design, step 1.5). Until it has, **nothing is written**: the file is
  /// rewritten whole, so a write made without its claims would discard
  /// them — and among them are renames and deletions of notes another
  /// device made, which nothing else records.
  bool _loaded;

  /// Whether a write is owed but held back until the file loads.
  bool _owed = false;

  /// The read a change started, while it runs. Further changes share it
  /// rather than each reading the whole file again — a [repairFrom] over N
  /// rows would otherwise read it N times. A [flush] never shares it.
  Future<bool>? _changeRetry;

  /// Whether [dispose] has run. A read already under way then finishes
  /// without sending anything: a torn-down session writing late could land
  /// over the file of the session that reopened the engram.
  bool _disposed = false;

  /// The `dart:developer` log name for the map's own messages.
  static const String _logName = 'brainframe.identity_map';

  /// Loads what this device last wrote, so the next write carries every
  /// earlier claim forward. A device that started from an empty set would
  /// republish only its newest claim and silently retract the rest.
  ///
  /// [writer] overrides the debounced writer, so a test can drive its timers
  /// or capture its rows without a filesystem. One that writes with
  /// `map.write` alone writes no name; the default writes the name too.
  ///
  /// **A file that exists but cannot be read is not an empty one** (the
  /// device names design, step 1.5). The engram still opens, and claims and
  /// a name can still be recorded, but no write is made until the file has
  /// been read: each change, and each [flush], tries again. When it reads,
  /// its claims are merged under this session's — which are newer — and the
  /// owed write goes out. One that never reads is never written, which
  /// costs this session's claims (the next open rebuilds this device's own
  /// mints, [repairFrom]) rather than every claim the file held.
  static Future<AuthoredIdentity> load(
    IdentityMap map, {
    DebouncedIdentityMapWriter? writer,
  }) async {
    var rows = const <IdentityRow>[];
    PeerName? name;
    var loaded = true;
    try {
      final ours = await map.loadOurs();
      rows = ours.rows;
      name = ours.name;
    } on IdentityMapUnreadable catch (error) {
      developer.log(
        'this device\'s map file could not be read; holding every write '
        'until it can',
        name: _logName,
        error: error,
      );
      loaded = false;
    }
    final identity = AuthoredIdentity._(
      map,
      {for (final row in rows) row.ulid: row},
      name,
      loaded,
    );
    identity._writer =
        writer ??
        DebouncedIdentityMapWriter(
          (rows) => map.write(rows, self: identity._name),
        );
    return identity;
  }

  /// Whether this device's own file has been read. Until it has, [rows] is
  /// this session's claims alone, and nothing is written.
  bool get loaded => _loaded;

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
    _nameSetHere = true;
    _schedule();
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
    _schedule();
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
  ///
  /// A write held back because the file has not been read is tried again
  /// here: the session flushes on resume and on quit, so a file that was
  /// locked at open gets another chance at each.
  Future<void> flush() async {
    if (_owed) await _retryLoad();
    await _writer.flush();
  }

  /// Drops any pending write. For a session that is being torn down without
  /// a chance to flush. What was lost is this device's own claims, which the
  /// next open rebuilds from the catalog ([repairFrom]); a rename or a
  /// deletion of an adopted note is not rebuilt, which is why the session
  /// flushes on quit rather than disposing.
  void dispose() {
    _disposed = true;
    _owed = false;
    _writer.dispose();
  }

  /// Asks the writer for a write of the claims as they stand — or, while
  /// the file has not been read, records that one is owed and tries the
  /// read again.
  void _schedule() {
    if (_loaded) {
      _writer.schedule(_rows.values.toList());
      return;
    }
    _owed = true;
    _changeRetry ??= _retryLoad().whenComplete(() => _changeRetry = null);
    unawaited(_changeRetry);
  }

  /// Tries to read this device's file again, if it has not been read; on
  /// success merges it in and sends the owed write. Returns whether the
  /// file is now loaded.
  ///
  /// **Every call is a fresh attempt** — never one already under way. An
  /// attempt that began while the file was still unreadable fails; a flush
  /// that shared it would never see the file that has since come back.
  /// Two attempts at once are harmless: the second to succeed finds the
  /// file already merged, and stops.
  Future<bool> _retryLoad() async {
    if (_loaded) return true;
    final ({List<IdentityRow> rows, PeerName? name, bool found}) ours;
    try {
      ours = await map.loadOurs();
    } on IdentityMapUnreadable {
      return false; // still held; the next change or flush tries again
    }
    // Gone, after it was seen unreadable, is not "never written": a sync
    // service that replaces a file may delete it first, and a write in that
    // gap would land over the claims it is bringing back. Only a read
    // releases the hold; a file that stays gone costs this session's claims,
    // which the next open rebuilds.
    if (!ours.found) return false;
    if (_loaded) return true; // another attempt got there first
    if (_disposed) return false;
    // The file's claims first, then this session's over them: anything
    // recorded since the open is newer than what the file held.
    final session = Map.of(_rows);
    _rows
      ..clear()
      ..addAll({for (final row in ours.rows) row.ulid: row})
      ..addAll(session);
    if (!_nameSetHere) _name = ours.name;
    _loaded = true;
    if (_owed) {
      _owed = false;
      _writer.schedule(_rows.values.toList());
    }
    developer.log(
      'this device\'s map file read at last; '
      '${ours.rows.length} claim(s) kept',
      name: _logName,
    );
    return true;
  }
}
