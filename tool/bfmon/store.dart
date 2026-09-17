/// Read-only access to one device's `metadata.db`, for the monitor.
///
/// Deliberately not [MetadataDatabase]: that opens read-write, creates the
/// directory, and runs the schema, all of which a monitor watching a store
/// *another process owns* must never do. This opens the file read-only,
/// waits briefly on a lock rather than failing (the app's journal mode is
/// `delete`, so a commit in progress holds the file for a moment), and reads
/// the tables as they are — `bf_catalog`, `bf_scan`, `bf_scan_event`,
/// `bf_meta`, and `crdt_lf_sqlite`'s `changes`.
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:brainframe/engram/crdt/app_data_source.dart';
import 'package:brainframe/engram/crdt/catalog.dart';
import 'package:brainframe/engram/id.dart';
import 'package:crdt_lf/crdt_lf.dart';
import 'package:sqlite3/sqlite3.dart' as sq;

/// One row of `bf_catalog`, as the monitor sees it.
class CatalogEntry {
  const CatalogEntry({
    required this.ulid,
    required this.path,
    required this.mergePolicy,
    required this.state,
    required this.materializedHash,
    required this.seededBy,
    required this.seedHlc,
  });

  final String ulid;
  final String path;
  final String mergePolicy;
  final String state;
  final String? materializedHash;
  final String? seededBy;
  final String? seedHlc;

  /// The seed claim as the catalog spells it, `peer@hlc`, or null.
  String? get seedClaim =>
      seededBy == null || seedHlc == null ? null : '$seededBy@$seedHlc';
}

/// One recorded scan and what it did, from `bf_scan` and `bf_scan_event`.
class ScanRecord {
  const ScanRecord({
    required this.id,
    required this.trigger,
    required this.finishedUtc,
    required this.complete,
    required this.events,
  });

  final int id;
  final String trigger;
  final DateTime finishedUtc;
  final bool complete;

  /// `(kind, path, newPath)` per event, in insertion order.
  final List<(String, String, String?)> events;
}

/// One stored change: the raw [Change] and the document it belongs to.
class StoredChange {
  const StoredChange(this.documentId, this.change);

  final String documentId;
  final Change change;

  String get changeId => change.id.toString();
}

/// Turns what a user typed into the path of a `metadata.db`.
///
/// Accepts the file itself, the directory holding it, or an app-data home
/// such as `/tmp/deviceA` — the `XDG_DATA_HOME` of one instance — under
/// which `<app id>/engrams/<engram ULID>/metadata.db` is searched for. With
/// one engram under the home that one is taken; with several, [engramId]
/// picks, and without it the choice is refused with the candidates listed.
///
/// Throws [ArgumentError] with a message meant for the terminal.
String resolveStorePath(String argument, {String? engramId}) {
  final file = File(argument);
  if (file.existsSync()) {
    if (file.uri.pathSegments.last != metadataDatabaseFileName) {
      throw ArgumentError('$argument is not a $metadataDatabaseFileName');
    }
    return file.path;
  }
  final directory = Directory(argument);
  if (!directory.existsSync()) {
    throw ArgumentError('$argument does not exist');
  }
  final direct = File('${directory.path}/$metadataDatabaseFileName');
  if (direct.existsSync()) return direct.path;

  final found = <String>[];
  for (final entity in directory.listSync(recursive: true)) {
    if (entity is! File) continue;
    final segments = entity.uri.pathSegments;
    if (segments.last != metadataDatabaseFileName) continue;
    if (segments.length < 3 ||
        segments[segments.length - 3] != engramsDirectoryName) {
      continue;
    }
    found.add(entity.path);
  }
  if (found.isEmpty) {
    throw ArgumentError(
      'no $engramsDirectoryName/<ulid>/$metadataDatabaseFileName under '
      '$argument',
    );
  }
  if (engramId != null) {
    final match = found.where((path) => path.contains('/$engramId/'));
    if (match.length == 1) return match.single;
    throw ArgumentError('no store for engram $engramId under $argument');
  }
  if (found.length == 1) return found.single;
  throw ArgumentError(
    '$argument holds ${found.length} engram stores; pass --engram <ulid>:\n'
    '${found.map((path) => '  $path').join('\n')}',
  );
}

/// The engram folder a store belongs to, from the `path.txt` beside it —
/// null when the label was never written.
String? engramFolderOf(String storePath) {
  final label = File('${File(storePath).parent.path}/$engramPathFileName');
  if (!label.existsSync()) return null;
  final path = label.readAsStringSync().trim();
  return path.isEmpty ? null : path;
}

/// A read-only view of one `metadata.db`.
class StoreReader {
  StoreReader._(this.label, this.path, this._db);

  /// Opens [path] read-only. Throws if the file is missing or not a store.
  factory StoreReader.open(String path, {required String label}) {
    if (!File(path).existsSync()) {
      throw ArgumentError('$path does not exist');
    }
    final db = sq.sqlite3.open(path, mode: sq.OpenMode.readOnly);
    // A commit in progress in the owning app holds the file briefly; wait
    // for it rather than reporting a phantom failure.
    db.execute('PRAGMA busy_timeout = 500');
    try {
      db.select('SELECT 1 FROM bf_meta LIMIT 1');
    } on sq.SqliteException {
      db.close();
      throw ArgumentError(
        '$path is not a BrainFrame $metadataDatabaseFileName',
      );
    }
    return StoreReader._(label, path, db);
  }

  /// How the monitor names this store in its output: `A`, `B`, …
  final String label;

  /// The `metadata.db` file.
  final String path;

  final sq.Database _db;

  /// This device's peer ID, as stamped on every operation it authors.
  String get peerId => _meta('peer_id') ?? '?';

  /// The finish time of the latest scan, clean or not — the only trace a
  /// clean scan leaves.
  DateTime? get lastScan {
    final value = _meta('last_scan_utc');
    if (value == null) return null;
    final millis = int.tryParse(value);
    return millis == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
  }

  /// SQLite's `data_version`: changes whenever another connection commits,
  /// which is exactly "the app wrote something since last time".
  int get dataVersion =>
      _db.select('PRAGMA data_version').single.columnAt(0) as int;

  String? _meta(String key) {
    final rows = _db.select('SELECT value FROM bf_meta WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.single['value'] as String;
  }

  /// Every catalog row, by ULID.
  Map<String, CatalogEntry> catalog() {
    final rows = _db.select(
      'SELECT ulid, path, merge_policy, state, materialized_hash, seeded_by, '
      'seed_hlc FROM bf_catalog',
    );
    return {
      for (final row in rows)
        row['ulid'] as String: CatalogEntry(
          ulid: row['ulid'] as String,
          path: row['path'] as String,
          mergePolicy: row['merge_policy'] as String,
          state: row['state'] as String,
          materializedHash: row['materialized_hash'] as String?,
          seededBy: row['seeded_by'] as String?,
          seedHlc: row['seed_hlc'] as String?,
        ),
    };
  }

  /// The catalog row at [path], live or otherwise findable, or null.
  CatalogEntry? entryAt(String path) {
    for (final entry in catalog().values) {
      if (entry.path == path && entry.state != NoteState.tombstoned.name) {
        return entry;
      }
    }
    return null;
  }

  /// The catalog row for [ulid], or null.
  CatalogEntry? entryFor(String ulid) => catalog()[ulid];

  /// The row [argument] names — a ULID, or an engram-relative path.
  CatalogEntry? entryNamed(String argument) =>
      isCanonicalUlid(argument) ? entryFor(argument) : entryAt(argument);

  /// The highest `bf_scan.id`, or 0 with none recorded.
  int get latestScanId =>
      (_db.select('SELECT COALESCE(MAX(id), 0) FROM bf_scan').single.columnAt(0)
          as int);

  /// Recorded scans with an id above [afterId], oldest first.
  List<ScanRecord> scansAfter(int afterId) {
    final scans = _db.select(
      'SELECT id, trigger, finished_utc, complete FROM bf_scan '
      'WHERE id > ? ORDER BY id',
      [afterId],
    );
    return [
      for (final scan in scans)
        ScanRecord(
          id: scan['id'] as int,
          trigger: scan['trigger'] as String,
          finishedUtc: DateTime.fromMillisecondsSinceEpoch(
            scan['finished_utc'] as int,
            isUtc: true,
          ),
          complete: (scan['complete'] as int) != 0,
          events: [
            for (final event in _db.select(
              'SELECT kind, path, new_path FROM bf_scan_event '
              'WHERE scan_id = ? ORDER BY rowid',
              [scan['id']],
            ))
              (
                event['kind'] as String,
                event['path'] as String,
                event['new_path'] as String?,
              ),
          ],
        ),
    ];
  }

  /// Every change id in the op-log, by document — the cheap query the
  /// watcher diffs between polls.
  Map<String, Set<String>> changeIds() {
    final result = <String, Set<String>>{};
    for (final row in _db.select(
      'SELECT document_id, change_id FROM changes',
    )) {
      result
          .putIfAbsent(row['document_id'] as String, () => <String>{})
          .add(row['change_id'] as String);
    }
    return result;
  }

  /// The number of stored changes per document.
  Map<String, int> changeCounts() => {
    for (final row in _db.select(
      'SELECT document_id, COUNT(*) AS n FROM changes GROUP BY document_id',
    ))
      row['document_id'] as String: row['n'] as int,
  };

  /// Every stored change for [documentId], decoded, in HLC order — a valid
  /// causal order, since a change's dependencies always carry earlier
  /// clocks. Ties, which only two peers can produce, break on peer id.
  List<StoredChange> changesFor(String documentId) {
    final rows = _db.select(
      'SELECT change_id, bytes FROM changes WHERE document_id = ?',
      [documentId],
    );
    final changes = [
      for (final row in rows)
        StoredChange(
          documentId,
          Change.fromBytes(Uint8List.fromList(row['bytes'] as List<int>)),
        ),
    ]..sort(compareChanges);
    return changes;
  }

  /// [changesFor], restricted to [ids].
  List<StoredChange> changesNamed(String documentId, Set<String> ids) => [
    for (final stored in changesFor(documentId))
      if (ids.contains(stored.changeId)) stored,
  ];

  void close() => _db.close();
}

/// HLC order, then peer id: the order a log is replayed in.
int compareChanges(StoredChange a, StoredChange b) {
  final byClock = a.change.hlc.compareTo(b.change.hlc);
  if (byClock != 0) return byClock;
  return a.change.author.toString().compareTo(b.change.author.toString());
}
