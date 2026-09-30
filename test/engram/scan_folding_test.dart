import 'package:brainframe/engram/note_reconciler.dart';
import 'package:brainframe/engram/scan_folding.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 9, 28, 17, 16);

  /// A record that finished [finishedMin] minutes (plus [plusMs]) after t0
  /// and took one second.
  ScannedRecord rec(
    int id,
    num finishedMin, {
    ScanTrigger trigger = ScanTrigger.watcher,
    DriftScanReport report = const DriftScanReport(reconciled: ['a.md']),
    int plusMs = 0,
  }) {
    final finished = t0.add(
      Duration(milliseconds: (finishedMin * 60000).round() + plusMs),
    );
    return (
      id: id,
      startedAt: finished.subtract(const Duration(seconds: 1)),
      finishedAt: finished,
      trigger: trigger,
      report: report,
    );
  }

  List<ScanNotice> fold(List<ScannedRecord> newestFirst) {
    final folder = ScanFolder();
    newestFirst.forEach(folder.add);
    return folder.finish();
  }

  group('what folds', () {
    test('an editing session is one card, each note counted once', () {
      final cards = fold([
        rec(13, 8),
        rec(12, 7),
        rec(11, 5.5),
        rec(10, 4),
        rec(9, 0),
      ]);

      final card = cards.single;
      expect(card.id, 13);
      expect(card.folded, [12, 11, 10, 9]);
      expect(card.ids, [13, 12, 11, 10, 9]);
      expect(card.at, t0.add(const Duration(minutes: 8)));
      expect(card.since, t0);
      expect(card.report.reconciled, ['a.md'], reason: 'once, not five times');
      expect(card.trigger, ScanTrigger.watcher);
    });

    test('a quiet of exactly the gap still folds; a moment more does not', () {
      // Each record starts a second before it finishes, so the quiet between
      // two is the difference of their finishes less that second.
      final gap = scanFoldGap + const Duration(seconds: 1);
      final atGap = fold([rec(2, gap.inMilliseconds / 60000), rec(1, 0)]);
      expect(atGap.single.ids, [2, 1]);

      final pastGap = fold([
        rec(2, gap.inMilliseconds / 60000, plusMs: 1),
        rec(1, 0),
      ]);
      expect(pastGap.map((c) => c.ids), [
        [2],
        [1],
      ]);
    });

    test('changes to different notes land in one card together', () {
      final card = fold([
        rec(3, 2, report: const DriftScanReport(reconciled: ['b.md'])),
        rec(
          2,
          1,
          report: const DriftScanReport(
            created: ['c.md'],
            moved: {'old.md': 'new.md'},
          ),
        ),
        rec(1, 0, report: const DriftScanReport(reconciled: ['a.md'])),
      ]).single;

      expect(card.report.reconciled, ['b.md', 'a.md']);
      expect(card.report.created, ['c.md']);
      expect(card.report.moved, {'old.md': 'new.md'});
    });

    test('a note checked before it opened or saved folds with the watcher', () {
      final mixed = fold([
        rec(2, 1, trigger: ScanTrigger.note),
        rec(1, 0),
      ]).single;
      expect(mixed.trigger, ScanTrigger.watcher);

      final notesOnly = fold([
        rec(2, 1, trigger: ScanTrigger.note),
        rec(1, 0, trigger: ScanTrigger.note),
      ]).single;
      expect(notesOnly.trigger, ScanTrigger.note);
    });

    test('a card standing alone keeps its report as it was', () {
      const report = DriftScanReport(reconciled: ['a.md']);
      final card = fold([rec(1, 0, report: report)]).single;
      expect(card.report, same(report));
      expect(card.folded, isEmpty);
      expect(card.since, isNull);
    });
  });

  group('what never folds', () {
    test('open, resume and manual scans each keep their own card', () {
      final cards = fold([
        rec(4, 3),
        rec(3, 2, trigger: ScanTrigger.resume),
        rec(2, 1, trigger: ScanTrigger.open),
        rec(1, 0, trigger: ScanTrigger.manual),
      ]);
      expect(cards.map((c) => c.ids), [
        [4],
        [3],
        [2],
        [1],
      ]);
    });

    for (final (name, report) in [
      (
        'a history lost to a rename past recognition',
        const DriftScanReport(tombstoned: ['a.md'], created: ['b.md']),
      ),
      ('a failure', DriftScanReport(failed: {'a.md': StateError('x')})),
      ('an unlisted folder', const DriftScanReport(listingFailure: 'EACCES')),
      ('a note over the limit', const DriftScanReport(oversized: ['big.md'])),
      (
        'a note awaiting a decision',
        const DriftScanReport(awaitingDecision: ['big.md']),
      ),
      ('a conversion', const DriftScanReport(converted: ['big.md'])),
      (
        'a conversion elsewhere',
        const DriftScanReport(convertedElsewhere: {'big.md': 3}),
      ),
      (
        'a reconstruction',
        const DriftScanReport(reconstructed: {'big.md': 'big (1).md'}),
      ),
      ('a retirement', const DriftScanReport(retired: ['a.md'])),
    ]) {
      test('$name keeps its own card, and splits the run around it', () {
        final cards = fold([rec(3, 2), rec(2, 1, report: report), rec(1, 0)]);
        expect(cards.map((c) => c.ids), [
          [3],
          [2],
          [1],
        ]);
        expect(cards[1].report, same(report));
      });
    }
  });

  test('a folded card never claims a lost history from two scans', () {
    // A note deleted, and later an unrelated one created: two ordinary
    // changes, each foldable, whose union alone would look like a rename
    // past recognition.
    final card = fold([
      rec(2, 1, report: const DriftScanReport(created: ['b.md'])),
      rec(1, 0, report: const DriftScanReport(tombstoned: ['a.md'])),
    ]).single;
    expect(card.report.tombstoned, ['a.md']);
    expect(card.report.created, ['b.md']);
    expect(card.lostHistory, isFalse);
  });

  test('closed holds only the cards no later record can change', () {
    final folder = ScanFolder()
      ..add(rec(3, 20))
      ..add(rec(2, 1));
    expect(folder.closed.map((c) => c.ids), [
      [3],
    ], reason: 'the run holding 2 may still grow');
    folder.add(rec(1, 0));
    expect(folder.closed.length, 1);
    expect(folder.finish().map((c) => c.ids), [
      [3],
      [2, 1],
    ]);
  });
}
