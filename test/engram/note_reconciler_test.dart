import 'package:brainframe/engram/note_reconciler.dart';
import 'package:flutter_test/flutter_test.dart';

/// The pure half of the reconciliation seam: the scan report.
void main() {
  test('the clean report reconciled nothing and failed nothing', () {
    expect(DriftScanReport.clean.isClean, isTrue);
    expect(DriftScanReport.clean.reconciled, isEmpty);
    expect(DriftScanReport.clean.failed, isEmpty);
  });

  test('a reconciled path makes the report not clean', () {
    const report = DriftScanReport(reconciled: ['inbox/today.md']);
    expect(report.isClean, isFalse);
  });

  test('every kind of change makes the report not clean', () {
    const reports = [
      DriftScanReport(created: ['a.md']),
      DriftScanReport(adopted: ['a.md']),
      DriftScanReport(moved: {'a.md': 'b.md'}),
      DriftScanReport(tombstoned: ['a.md']),
      DriftScanReport(retired: ['a.md']),
    ];
    for (final report in reports) {
      expect(report.isClean, isFalse);
      expect(report.complete, isTrue);
    }
  });

  test('a listing failure makes the report incomplete and not clean', () {
    final report = DriftScanReport(listingFailure: StateError('unmounted'));
    expect(report.complete, isFalse);
    expect(report.isClean, isFalse);
  });

  test('a failure makes the report not clean', () {
    final report = DriftScanReport(
      failed: {'inbox/today.md': StateError('unreadable')},
    );
    expect(report.isClean, isFalse);
  });

  group('AdoptionProgress', () {
    test('is running until done reaches total', () {
      expect(const AdoptionProgress(done: 0, total: 3).isRunning, isTrue);
      expect(const AdoptionProgress(done: 2, total: 3).isRunning, isTrue);
      expect(const AdoptionProgress(done: 3, total: 3).isRunning, isFalse);
    });

    test('is a value', () {
      const a = AdoptionProgress(done: 1, total: 2);
      const b = AdoptionProgress(done: 1, total: 2);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(const AdoptionProgress(done: 2, total: 2)));
      expect(
        a,
        isNot(const AdoptionProgress(done: 1, total: 2, doneBytes: 1)),
        reason: 'the bytes are part of it: a step within a file is a step',
      );
      expect(a.toString(), 'AdoptionProgress(1 of 2, 0 of 0 bytes)');
    });

    test('its fraction follows bytes when there are any, else files', () {
      // The cost is in bytes: one large blob among many small notes is most
      // of the wait, so it is most of the bar.
      const byBytes = AdoptionProgress(
        done: 1,
        total: 10,
        doneBytes: 750,
        totalBytes: 1000,
      );
      expect(byBytes.fraction, 0.75);
      expect(byBytes.isRunning, isTrue, reason: 'files decide the end');

      const byFiles = AdoptionProgress(done: 1, total: 4);
      expect(byFiles.fraction, 0.25, reason: 'nothing had a size');

      const nothing = AdoptionProgress(done: 0, total: 0);
      expect(nothing.fraction, 1);
    });

    test('its fraction is clamped when a file grew after its stat', () {
      const over = AdoptionProgress(
        done: 2,
        total: 3,
        doneBytes: 1200,
        totalBytes: 1000,
      );
      expect(over.fraction, 1);
    });
  });
}
