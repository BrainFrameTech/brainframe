import 'package:brainframe/engram/crdt/metadata_db_io.dart';
import 'package:brainframe/engram/note_reconciler.dart';
import 'package:flutter_test/flutter_test.dart';

/// The scan history's two tables: what a record round-trips, what the prune
/// rule keeps, and what a dismiss does.
void main() {
  late MetadataDatabase store;
  late ScanHistory history;

  setUp(() {
    store = MetadataDatabase.openInMemory();
    history = store.scans;
  });

  tearDown(() => store.close());

  final t0 = DateTime.utc(2026, 9, 12, 14, 30);

  int? record(
    DriftScanReport report, {
    DateTime? at,
    ScanTrigger trigger = ScanTrigger.manual,
    String? Function(ScanEventKind kind, String path)? ulidOf,
  }) => history.record(
    report,
    startedAt: (at ?? t0).subtract(const Duration(milliseconds: 800)),
    finishedAt: at ?? t0,
    trigger: trigger,
    ulidOf: ulidOf ?? (_, _) => null,
  );

  group('schema', () {
    test('both tables exist with the columns the plan names', () {
      List<String> columns(String table) => store.database
          .select('SELECT name FROM pragma_table_info(?) ORDER BY cid', [table])
          .map((row) => row['name'] as String)
          .toList();

      expect(columns('bf_scan'), [
        'id',
        'started_utc',
        'finished_utc',
        'trigger',
        'complete',
        'listing_error',
        'lost_history',
        'acknowledged_utc',
      ]);
      expect(columns('bf_scan_event'), [
        'scan_id',
        'kind',
        'path',
        'new_path',
        'ulid',
        'error',
      ]);
    });

    test('creating the schema twice is a no-op', () {
      ScanHistory.createSchema(store.database);
      expect(history.count(), 0);
    });
  });

  group('record', () {
    test('a clean report writes nothing', () {
      expect(record(DriftScanReport.clean), isNull);
      expect(history.count(), 0);
    });

    test('a report round-trips through the tables', () {
      final report = DriftScanReport(
        reconciled: const ['a.md', 'b.md'],
        created: const ['c.md'],
        adopted: const ['d.md'],
        moved: const {'old.md': 'new.md'},
        tombstoned: const ['gone.md'],
        retired: const ['lost.md'],
        failed: {'bad.md': const FormatException('not UTF-8')},
      );

      final id = record(
        report,
        trigger: ScanTrigger.resume,
        ulidOf: (kind, path) => 'ULID-${kind.name}-$path',
      )!;
      final back = history.byId(id)!;

      expect(back.id, id);
      expect(back.trigger, ScanTrigger.resume);
      expect(back.acknowledged, isFalse);
      expect(back.finishedAt.toUtc(), t0);
      expect(
        back.startedAt.toUtc(),
        t0.subtract(const Duration(milliseconds: 800)),
      );
      expect(back.report.reconciled, ['a.md', 'b.md']);
      expect(back.report.created, ['c.md']);
      expect(back.report.adopted, ['d.md']);
      expect(back.report.moved, {'old.md': 'new.md'});
      expect(back.report.tombstoned, ['gone.md']);
      expect(back.report.retired, ['lost.md']);
      expect(back.report.failed, {'bad.md': 'FormatException: not UTF-8'});
      expect(back.report.complete, isTrue);
      expect(back.lostHistory, isTrue);
      // A move's event resolves the note at its new path.
      final moved = store.database
          .select("SELECT ulid FROM bf_scan_event WHERE kind = 'moved'")
          .single;
      expect(moved['ulid'], 'ULID-moved-new.md');
    });

    test('a listing failure is kept as its text, and complete stays false', () {
      final id = record(
        DriftScanReport(
          reconciled: const ['a.md'],
          listingFailure: StateError('unmounted'),
        ),
      )!;

      final back = history.byId(id)!;
      expect(back.report.complete, isFalse);
      expect(back.report.listingFailure.toString(), contains('unmounted'));
    });

    test('a scan that failed everywhere is still a scan', () {
      final id = record(DriftScanReport(failed: {'x.md': StateError('boom')}))!;
      expect(history.byId(id)!.lostHistory, isFalse);
    });
  });

  group('recent', () {
    test('newest first, limited', () {
      for (var i = 0; i < 5; i++) {
        record(
          DriftScanReport(created: ['n$i.md']),
          at: t0.add(Duration(minutes: i)),
        );
      }

      expect(history.recent().map((r) => r.report.created.single), [
        'n4.md',
        'n3.md',
        'n2.md',
        'n1.md',
        'n0.md',
      ]);
      expect(history.recent(limit: 2).length, 2);
    });

    test('unacknowledgedOnly leaves out what was dismissed', () {
      final a = record(DriftScanReport(created: const ['a.md']))!;
      final b = record(
        DriftScanReport(created: const ['b.md']),
        at: t0.add(const Duration(minutes: 1)),
      )!;

      history.acknowledge(a, at: t0.add(const Duration(hours: 1)));

      expect(history.recent(unacknowledgedOnly: true).map((r) => r.id), [b]);
      expect(history.recent().map((r) => r.id), [b, a]);
      expect(history.byId(a)!.acknowledged, isTrue);
    });
  });

  group('prune', () {
    final now = DateTime.utc(2028, 1, 1);

    test(
      'drops ordinary scans older than the retention, with their events',
      () {
        final old = record(
          DriftScanReport(created: const ['old.md']),
          at: now.subtract(const Duration(days: 400)),
        )!;
        final recent = record(
          DriftScanReport(created: const ['recent.md']),
          at: now.subtract(const Duration(days: 300)),
        )!;

        expect(history.prune(now: now), 1);

        expect(history.byId(old), isNull);
        expect(history.byId(recent), isNotNull);
        expect(
          store.database.select(
            'SELECT COUNT(*) AS n FROM bf_scan_event WHERE scan_id = ?',
            [old],
          ).single['n'],
          0,
          reason: 'events go with their scan',
        );
      },
    );

    test('never drops a scan that lost history or failed', () {
      final lost = record(
        DriftScanReport(
          created: const ['new.md'],
          tombstoned: const ['old.md'],
        ),
        at: now.subtract(const Duration(days: 800)),
      )!;
      final failed = record(
        DriftScanReport(failed: {'bad.md': StateError('boom')}),
        at: now.subtract(const Duration(days: 800)),
      )!;

      expect(history.prune(now: now), 0);

      expect(history.byId(lost), isNotNull);
      expect(history.byId(failed), isNotNull);
    });
  });
}
