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
}
