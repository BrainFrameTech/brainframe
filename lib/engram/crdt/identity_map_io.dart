/// The identity map on disk: one small database per device, inside the engram.
///
/// `dart:io`-only, because these are SQLite files. Read
/// [identity_map.dart](identity_map.dart) for what a row means; this is where
/// the files live, how one is replaced atomically, and how every device's
/// file is read back as one set.
library;

import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:crdt_lf/crdt_lf.dart';
import 'package:sqlite3/sqlite3.dart' as sq;

import '../fs/fs_store_io.dart';
import 'catalog.dart';
import 'identity_map.dart';
import 'store_exceptions.dart';

/// The directory under the marker that holds every device's map file.
const String sharedDirectoryName = 'shared';

/// One device's identity-map file, and the reader over all of them.
///
/// The file is `<engram>/.brainframe/shared/<peerId>.db`, one per device
/// **ever**: a directory holding three files means three devices have written
/// to this engram.
///
/// **The peerID in the filename is authorship, not scope.** Every row in every
/// one of these files is shared state that every device reads. Nothing
/// peer-specific lives in them — that is `metadata.db`'s job. The name answers
/// "who wrote this file", never "who is this file for".
///
/// Sharding by author is what makes the map possible at all. A single
/// `engram.db` in a synced folder is not merged by a sync service; it picks a
/// winner and drops the loser, so two machines adopting one vault offline
/// would lose one machine's ULIDs and seed claims wholesale, with no merge
/// rule ever getting to run. One file per writer converts that into a union of
/// independent files.
class IdentityMap {
  const IdentityMap({required this.engramRoot, required this.peerId});

  /// The table holding the map, `bf_`-prefixed like every table BrainFrame
  /// creates.
  ///
  /// The columns are the design's row exactly: identity, location, policy,
  /// the deleted flag, the seed claim, and the stamp the merge rules resolve
  /// by. **No content hash, size, or mtime** — those describe this device's
  /// copy rather than the note, and Decision 5 spells out how sharing them
  /// turns drift detection into silent data loss.
  static const String createSchemaSql = '''
CREATE TABLE IF NOT EXISTS bf_identity_map (
  ulid         TEXT PRIMARY KEY,
  path         TEXT NOT NULL,
  merge_policy TEXT NOT NULL,
  deleted      INTEGER NOT NULL,
  seeded_by    TEXT,
  seed_hlc     TEXT,
  peer         TEXT NOT NULL,
  hlc          TEXT NOT NULL
);
''';

  /// Absolute path to the engram's root directory.
  final String engramRoot;

  /// This device's identity for this engram, which names its file.
  final PeerId peerId;

  /// The directory every device's map file lives in.
  String get directoryPath =>
      '$engramRoot/$markerDirectoryName/$sharedDirectoryName';

  /// This device's own file — the only one it may write.
  String get filePath => '$directoryPath/$peerId.db';

  /// Replaces this device's file with exactly [rows].
  ///
  /// Written whole, never appended to. The map is measured in kilobytes, so
  /// rewriting it costs nothing — a discipline that would be ruinous applied
  /// to an op-log and is free here.
  ///
  /// The file is built in memory, copied out with `VACUUM INTO`, and renamed
  /// over the target. Three separate things make that sequence the right one,
  /// and each is easy to mistake for the others:
  ///
  /// - **The rename is what makes the write safe to observe.** It is atomic,
  ///   so a sync service watching the folder sees the old map or the new one
  ///   and never a half-written file. Neither the vacuum nor the in-memory
  ///   staging contributes to that.
  /// - **The temporary file is a sibling of its destination, never in the
  ///   system temp directory.** `Directory.systemTemp` is the obvious reach —
  ///   it is what `Directory.createTemp` defaults to and what most languages'
  ///   temp-file helpers give you — but `File.rename` cannot move a file
  ///   between filesystems, and the documented fallback is copy-then-delete,
  ///   which is exactly the non-atomic write this is avoiding. An engram lives
  ///   wherever the user put it: a synced folder, an external drive, a network
  ///   share. On Linux the system temp directory is routinely a different
  ///   filesystem from all three. So the temp goes in the destination's own
  ///   directory, and `Directory.createTemp` is used *there* rather than in
  ///   the system location, for a name the OS guarantees unique.
  /// - **The in-memory source buys one sequential write.** `VACUUM INTO`
  ///   streams a compact database out in a single pass, where inserting
  ///   straight into the destination file scatters page writes and leaves a
  ///   transient rollback journal beside it. That matters here specifically
  ///   because this directory is, by design, the one sitting in Dropbox,
  ///   iCloud, or on a network share.
  ///
  /// The cost is that every row is written twice — once into memory, once by
  /// the vacuum. It is invisible while the map is kilobytes, and it is the
  /// thing to revisit if this file ever grows enough that a whole rewrite
  /// stops being free: at that point, inserting directly into the temporary
  /// file and renaming it wins, and `VACUUM INTO` earns its keep for a
  /// different reason — reclaiming the free pages that in-place updates and
  /// deletes would start leaving behind. Rebuilding whole from a fresh
  /// database, as this does, never accumulates any.
  ///
  /// None of it does anything about two devices replacing one path. That is
  /// what the per-peer filename is for.
  Future<void> write(List<IdentityRow> rows) async {
    await Directory(directoryPath).create(recursive: true);

    // A unique directory beside the destination, so the name comes from the
    // OS rather than from a clock, and the rename below stays within one
    // filesystem. VACUUM INTO refuses a destination that already exists, so a
    // fresh name every time is also what stops one crashed write from blocking
    // every later one.
    final workspace = await Directory(directoryPath).createTemp('.write-');
    final temporaryPath = '${workspace.path}/map.db';

    final source = sq.sqlite3.openInMemory();
    try {
      source.execute(createSchemaSql);
      final statement = source.prepare(
        'INSERT INTO bf_identity_map '
        '(ulid, path, merge_policy, deleted, seeded_by, seed_hlc, peer, hlc) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      );
      try {
        // One transaction rather than a commit per row. The source is
        // discarded on any failure, so this is throughput, not durability.
        source.execute('BEGIN');
        for (final row in rows) {
          statement.execute([
            row.ulid,
            row.path,
            row.mergePolicy.name,
            row.deleted ? 1 : 0,
            row.seedClaim?.peerId.toString(),
            row.seedClaim?.hlc.toString(),
            row.recordedAt.peerId.toString(),
            row.recordedAt.hlc.toString(),
          ]);
        }
        source.execute('COMMIT');
      } finally {
        statement.close();
      }
      source.execute("VACUUM INTO '${_escape(temporaryPath)}'");
    } finally {
      source.close();
    }

    try {
      await File(temporaryPath).rename(filePath);
    } finally {
      // The map file has moved out; only the empty workspace is left. Removing
      // it matters more than usual because this directory is watched by a sync
      // service, which would otherwise ship one abandoned folder per write.
      await workspace.delete(recursive: true);
    }
  }

  /// Every row from every device's map file, including this one's.
  ///
  /// **Map files only** — the few-kilobyte `<peerId>.db` files under
  /// `.brainframe/shared/`, never a note. Named to say so, because a reader
  /// meeting a bare `readAll` beside the scan's per-note loop reasonably
  /// wondered whether it read the engram.
  ///
  /// A device reads the whole directory and unions it: peers appear as files,
  /// so nothing has to be discovered and no device list is kept anywhere.
  ///
  /// Returns rows exactly as written, with no merging — two files may each
  /// carry a row for one ULID, and reconciling that is the merge rules' job
  /// (step 6), not the reader's.
  ///
  /// A file that cannot be read is **skipped**, not fatal. These files arrive
  /// through a sync service, which may well be part-way through writing one:
  /// refusing to open the engram because another device's map is momentarily
  /// unreadable would be the wrong trade. The cost of skipping is bounded and
  /// already handled — an unseen row can let this device mint a second ULID
  /// for a path, which is precisely the collision Decision 9's lowest-ULID
  /// election resolves.
  Future<List<IdentityRow>> readEveryDevicesRows() async {
    final directory = Directory(directoryPath);
    if (!await directory.exists()) return const [];

    final files =
        (await directory.list(followLinks: false).toList())
            .whereType<File>()
            .where((file) => file.path.endsWith('.db'))
            .toList()
          ..sort((a, b) => a.path.compareTo(b.path));

    final rows = <IdentityRow>[];
    for (final file in files) {
      rows.addAll(_readFile(file.path));
    }
    return rows;
  }

  /// The devices that have written to this engram: one per map file in the
  /// shared directory, this one's included if it has written yet.
  ///
  /// A file counts whether or not it holds rows — a device that adopted
  /// everything and minted nothing still wrote its (empty) file. A file whose
  /// name is not a peer id is not a device and is skipped.
  Future<List<PeerId>> peersSeen() async {
    final directory = Directory(directoryPath);
    if (!await directory.exists()) return const [];
    final peers = <PeerId>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! File || !entity.path.endsWith('.db')) continue;
      final name = entity.uri.pathSegments.last;
      try {
        peers.add(PeerId.parse(name.substring(0, name.length - 3)));
      } on FormatException {
        // Not one of ours: a temp file, a stray copy. Not a device.
      }
    }
    return peers;
  }

  /// Every row this device itself last wrote.
  Future<List<IdentityRow>> readOurs() async =>
      File(filePath).existsSync() ? _readFile(filePath) : const [];

  List<IdentityRow> _readFile(String path) {
    sq.Database? database;
    try {
      database = sq.sqlite3.open(path, mode: sq.OpenMode.readOnly);
      return database
          .select('SELECT * FROM bf_identity_map')
          .map((row) => _rowFrom(row, path))
          .toList();
    } on sq.SqliteException catch (error) {
      // Unreadable or not yet fully arrived. Logged rather than silent: it is
      // expected transiently and suspicious permanently.
      developer.log(
        'Skipping unreadable identity map at $path: ${error.message}',
        name: 'brainframe.identity_map',
      );
      return const [];
    } finally {
      database?.close();
    }
  }

  IdentityRow _rowFrom(sq.Row row, String path) {
    final ulid = row['ulid'] as String;
    try {
      final seededBy = row['seeded_by'] as String?;
      final seedHlc = row['seed_hlc'] as String?;
      return IdentityRow(
        ulid: ulid,
        path: row['path'] as String,
        mergePolicy: MergePolicy.parse(row['merge_policy'] as String),
        recordedAt: OperationId.parse(
          '${row['peer'] as String}@${row['hlc'] as String}',
        ),
        deleted: (row['deleted'] as int) != 0,
        seedClaim: seededBy == null || seedHlc == null
            ? null
            : OperationId.parse('$seededBy@$seedHlc'),
      );
    } on FormatException catch (error) {
      // A row we cannot interpret, in a file we could otherwise open. Unlike
      // an unreadable file this is not a sync artefact, so it is surfaced the
      // way every other unreadable value in this design is.
      throw MetadataDatabaseException(
        'identity map row "$ulid" in $path is unreadable: ${error.message}',
      );
    }
  }

  static String _escape(String path) => path.replaceAll("'", "''");
}

/// Writes the identity map on the same debounce discipline the editor uses.
///
/// Deliberately the *shape* of `DocumentEditController`'s autosave rather than
/// a second timer discipline invented here: an idle delay so a burst of
/// renames costs one write, and a max-wait cap so an uninterrupted burst still
/// reaches disk. Two timers, both cancelled by a flush.
///
/// The map is written to a folder a sync service is watching, so write
/// amplification is not merely wasteful — every write is a file the service
/// must ship.
/// Takes the write itself rather than an [IdentityMap] — usually
/// `IdentityMap.write` — because what this class owns is *when* to write, not
/// where. That also lets its timer discipline be tested without touching a
/// filesystem, which matters: `fakeAsync` drives timers, never real I/O.
class DebouncedIdentityMapWriter {
  DebouncedIdentityMapWriter(
    this._write, {
    this.idleDebounce = const Duration(seconds: 5),
    this.maxWait = const Duration(seconds: 30),
  });

  final Future<void> Function(List<IdentityRow> rows) _write;
  final Duration idleDebounce;
  final Duration maxWait;

  List<IdentityRow>? _pending;
  Timer? _idleTimer;
  Timer? _maxWaitTimer;

  /// Whether a write is owed.
  bool get isDirty => _pending != null;

  /// Records [rows] as the next thing to write, and arms the timers.
  ///
  /// Supersedes anything not yet written — the map is always written whole, so
  /// only the latest set matters and an intermediate state has no value.
  void schedule(List<IdentityRow> rows) {
    _pending = rows;
    _idleTimer?.cancel();
    _idleTimer = Timer(idleDebounce, () => unawaited(flush()));
    _maxWaitTimer ??= Timer(maxWait, () => unawaited(flush()));
  }

  /// Writes immediately if anything is owed, and stands the timers down.
  Future<void> flush() async {
    final rows = _pending;
    _cancelTimers();
    _pending = null;
    if (rows == null) return;
    await _write(rows);
  }

  /// Drops any pending write without performing it.
  ///
  /// For teardown where the engram is going away — closing over an unwritten
  /// map is a lost rename, not a corrupted one, and the next scan recovers it.
  void dispose() {
    _cancelTimers();
    _pending = null;
  }

  void _cancelTimers() {
    _idleTimer?.cancel();
    _idleTimer = null;
    _maxWaitTimer?.cancel();
    _maxWaitTimer = null;
  }
}
