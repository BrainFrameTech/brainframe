/// The scan history: what each scan that changed something did, kept in
/// `metadata.db` so Housekeeping can show it after the fact — after the
/// session that ran it, and after the launch.
///
/// `dart:io`-only because SQLite is. Two tables over the connection
/// [MetadataDatabase] owns, so a scan's record commits with everything else
/// in one transaction boundary. Device-local like the rest of the file:
/// nothing here reaches the shared map, and nothing needs to — the facts the
/// records describe are already durable in the catalog; this is the narrative
/// of how they got there.
///
/// **Only a scan that changed something or failed gets a row.** Clean scans
/// are the overwhelming majority — every resume where nothing moved — and
/// carry no information beyond "a scan ran", which is one `bf_meta` key.
///
/// **Sized by measurement, not estimate.** SQLite stores an integer in as
/// many bytes as its value needs: a millisecond timestamp is 6, a 0/1 flag is
/// 0, a null is 0. On a real database with 10,000 scans and 100,000 events
/// after `VACUUM`, a scan row costs 48 bytes and an event row 86, indexes
/// included. A year of heavy external editing is around 2 MB, next to an
/// op-log that is ten times that for the same vault.
library;

import 'package:sqlite3/sqlite3.dart' as sq;

import '../note_reconciler.dart';
import 'catalog.dart';

/// One recorded scan, read back: the report as it was, plus what the record
/// adds — when, why, and whether the user has dismissed it.
class ScanRecord {
  const ScanRecord({
    required this.id,
    required this.startedAt,
    required this.finishedAt,
    required this.trigger,
    required this.acknowledged,
    required this.report,
  });

  /// The row id, which [ScanHistory.acknowledge] takes.
  final int id;

  final DateTime startedAt;
  final DateTime finishedAt;
  final ScanTrigger trigger;

  /// Whether the user dismissed this in Housekeeping.
  final bool acknowledged;

  /// The report rebuilt from the event rows. A failure's error comes back as
  /// its message, a string, since that is all that was kept.
  final DriftScanReport report;

  /// Whether this scan tombstoned and created in one pass: a rename past
  /// recognition, whose history stayed with the tombstone.
  bool get lostHistory =>
      report.tombstoned.isNotEmpty && report.created.isNotEmpty;

  /// The notice the panel shows, which is this record minus the id.
  ScanNotice get notice =>
      ScanNotice(at: finishedAt, report: report, id: id, trigger: trigger);
}

/// The two tables and their queries, over a connection someone else owns.
class ScanHistory {
  const ScanHistory(this.database);

  /// The scan itself: when, why, and the two facts the panel filters on —
  /// whether the folder was listed in full, and whether history was lost.
  static const String createScanSql = '''
CREATE TABLE IF NOT EXISTS bf_scan (
  id               INTEGER PRIMARY KEY,
  started_utc      INTEGER NOT NULL,
  finished_utc     INTEGER NOT NULL,
  trigger          TEXT    NOT NULL,
  complete         INTEGER NOT NULL,
  listing_error    TEXT,
  lost_history     INTEGER NOT NULL,
  acknowledged_utc INTEGER
);
''';

  /// What the scan did to each note. `kind` is the enum's name, never its
  /// ordinal, for the reason the catalog gives. `ulid` is what keeps a
  /// tombstone event meaningful after its path is reused.
  static const String createEventSql = '''
CREATE TABLE IF NOT EXISTS bf_scan_event (
  scan_id  INTEGER NOT NULL REFERENCES bf_scan(id) ON DELETE CASCADE,
  kind     TEXT    NOT NULL,
  path     TEXT    NOT NULL,
  new_path TEXT,
  ulid     TEXT,
  error    TEXT
);
''';

  static const String createIndexesSql = '''
CREATE INDEX IF NOT EXISTS bf_scan_event_scan ON bf_scan_event (scan_id);
CREATE INDEX IF NOT EXISTS bf_scan_finished ON bf_scan (finished_utc);
''';

  /// How long a scan that neither lost history nor failed is kept.
  static const Duration retention = Duration(days: 365);

  final sq.Database database;

  /// Creates the tables and indexes if they are not there. Idempotent, so it
  /// is safe on every open — which is how a database from before this step
  /// gains them, with no schema-version change.
  static void createSchema(sq.Database database) {
    database
      ..execute(createScanSql)
      ..execute(createEventSql)
      ..execute(createIndexesSql);
  }

  /// Records [report] as one scan, with its events, in one transaction.
  ///
  /// A clean report writes nothing here — the caller stamps `last_scan_utc`
  /// instead. [ulidOf] resolves a path to its note's ULID at recording time,
  /// given what the scan did to it — a tombstoned or retired note is no
  /// longer findable by path, so the caller looks among the tombstones for
  /// those; a path with no note (a failed creation, say) records null.
  ///
  /// Returns the new row id, or null when nothing was written.
  int? record(
    DriftScanReport report, {
    required DateTime startedAt,
    required DateTime finishedAt,
    required ScanTrigger trigger,
    required String? Function(ScanEventKind kind, String path) ulidOf,
  }) {
    if (report.isClean) return null;
    database.execute('BEGIN');
    try {
      database.execute(
        'INSERT INTO bf_scan '
        '(started_utc, finished_utc, trigger, complete, listing_error, '
        'lost_history, acknowledged_utc) '
        'VALUES (?, ?, ?, ?, ?, ?, NULL)',
        [
          startedAt.toUtc().millisecondsSinceEpoch,
          finishedAt.toUtc().millisecondsSinceEpoch,
          trigger.name,
          report.complete ? 1 : 0,
          report.listingFailure?.toString(),
          report.tombstoned.isNotEmpty && report.created.isNotEmpty ? 1 : 0,
        ],
      );
      final id = database.lastInsertRowId;
      final insert = database.prepare(
        'INSERT INTO bf_scan_event (scan_id, kind, path, new_path, ulid, error) '
        'VALUES (?, ?, ?, ?, ?, ?)',
      );
      try {
        void event(
          ScanEventKind kind,
          String path, {
          String? newPath,
          String? error,
        }) {
          insert.execute([
            id,
            kind.name,
            path,
            newPath,
            ulidOf(kind, newPath ?? path),
            error,
          ]);
        }

        for (final path in report.reconciled) {
          event(ScanEventKind.reconciled, path);
        }
        for (final path in report.created) {
          event(ScanEventKind.created, path);
        }
        for (final path in report.adopted) {
          event(ScanEventKind.adopted, path);
        }
        for (final move in report.moved.entries) {
          event(ScanEventKind.moved, move.key, newPath: move.value);
        }
        for (final path in report.tombstoned) {
          event(ScanEventKind.tombstoned, path);
        }
        for (final path in report.retired) {
          event(ScanEventKind.retired, path);
        }
        for (final failure in report.failed.entries) {
          event(
            ScanEventKind.failed,
            failure.key,
            error: failure.value.toString(),
          );
        }
      } finally {
        insert.close();
      }
      database.execute('COMMIT');
      return id;
    } on Object {
      database.execute('ROLLBACK');
      rethrow;
    }
  }

  /// The most recent scans, newest first, at most [limit]; with
  /// [unacknowledgedOnly], the ones the user has not dismissed.
  List<ScanRecord> recent({int limit = 20, bool unacknowledgedOnly = false}) {
    final where = unacknowledgedOnly ? 'WHERE acknowledged_utc IS NULL ' : '';
    final rows = database.select(
      'SELECT * FROM bf_scan ${where}ORDER BY finished_utc DESC, id DESC '
      'LIMIT ?',
      [limit],
    );
    return [for (final row in rows) _recordFrom(row)];
  }

  /// The one scan [id], or null.
  ScanRecord? byId(int id) {
    final rows = database.select('SELECT * FROM bf_scan WHERE id = ?', [id]);
    return rows.isEmpty ? null : _recordFrom(rows.first);
  }

  /// Marks [id] as dismissed by the user, now.
  void acknowledge(int id, {DateTime? at}) {
    database.execute('UPDATE bf_scan SET acknowledged_utc = ? WHERE id = ?', [
      (at ?? DateTime.now()).toUtc().millisecondsSinceEpoch,
      id,
    ]);
  }

  /// Drops scans older than [retention] that neither lost history nor failed.
  /// The ones that did are never pruned here: they are the ones the user
  /// needs to be able to find, and rare enough that "never" is bounded.
  ///
  /// Returns how many scans were dropped. Their events go with them.
  int prune({DateTime? now}) {
    final cutoff = (now ?? DateTime.now())
        .toUtc()
        .subtract(retention)
        .millisecondsSinceEpoch;
    // The events are deleted explicitly rather than by the REFERENCES
    // cascade: SQLite enforces foreign keys only when a connection asks it
    // to, and this connection is shared with the op-log's own schema, whose
    // pragmas are not ours to set. The clause on the table still documents
    // the relationship.
    const doomed =
        'SELECT id FROM bf_scan WHERE finished_utc < ? AND lost_history = 0 '
        'AND NOT EXISTS (SELECT 1 FROM bf_scan_event e '
        "WHERE e.scan_id = bf_scan.id AND e.kind = 'failed')";
    database.execute('BEGIN');
    try {
      database.execute('DELETE FROM bf_scan_event WHERE scan_id IN ($doomed)', [
        cutoff,
      ]);
      database.execute('DELETE FROM bf_scan WHERE id IN ($doomed)', [cutoff]);
      final dropped = database.updatedRows;
      database.execute('COMMIT');
      return dropped;
    } on Object {
      database.execute('ROLLBACK');
      rethrow;
    }
  }

  /// How many scans are recorded.
  int count() =>
      database.select('SELECT COUNT(*) AS n FROM bf_scan').first['n'] as int;

  ScanRecord _recordFrom(sq.Row row) {
    final id = row['id'] as int;
    final events = database.select(
      'SELECT kind, path, new_path, error FROM bf_scan_event '
      'WHERE scan_id = ? ORDER BY rowid',
      [id],
    );
    final reconciled = <String>[];
    final created = <String>[];
    final adopted = <String>[];
    final moved = <String, String>{};
    final tombstoned = <String>[];
    final retired = <String>[];
    final failed = <String, Object>{};
    for (final event in events) {
      final path = event['path'] as String;
      switch (ScanEventKind.parse(event['kind'] as String)) {
        case ScanEventKind.reconciled:
          reconciled.add(path);
        case ScanEventKind.created:
          created.add(path);
        case ScanEventKind.adopted:
          adopted.add(path);
        case ScanEventKind.moved:
          moved[path] = event['new_path'] as String;
        case ScanEventKind.tombstoned:
          tombstoned.add(path);
        case ScanEventKind.retired:
          retired.add(path);
        case ScanEventKind.failed:
          failed[path] = event['error'] as String? ?? '';
      }
    }
    final listingError = row['listing_error'] as String?;
    return ScanRecord(
      id: id,
      startedAt: DateTime.fromMillisecondsSinceEpoch(
        row['started_utc'] as int,
        isUtc: true,
      ).toLocal(),
      finishedAt: DateTime.fromMillisecondsSinceEpoch(
        row['finished_utc'] as int,
        isUtc: true,
      ).toLocal(),
      trigger: ScanTrigger.parse(row['trigger'] as String),
      acknowledged: row['acknowledged_utc'] != null,
      report: DriftScanReport(
        reconciled: reconciled,
        created: created,
        adopted: adopted,
        moved: moved,
        tombstoned: tombstoned,
        retired: retired,
        failed: failed,
        // A listing failure comes back as the text it was recorded as, which
        // is what the panel shows; that the folder was not listed in full is
        // the fact, and it is preserved either way.
        listingFailure: (row['complete'] as int) == 1
            ? null
            : (listingError ?? 'not listed'),
      ),
    );
  }
}

/// What a scan did to one note — the row kinds of `bf_scan_event`.
enum ScanEventKind {
  reconciled,
  created,
  adopted,
  moved,
  tombstoned,
  retired,
  failed;

  /// Parses the stored spelling, the enum's own name; throws
  /// [FormatException] for anything else, as [MergePolicy.parse] does.
  static ScanEventKind parse(String value) => values.firstWhere(
    (kind) => kind.name == value,
    orElse: () => throw FormatException('unknown scan event kind: "$value"'),
  );
}
