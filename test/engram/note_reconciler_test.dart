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
    const report = DriftScanReport(reconciled: ['inbox/today.md'], failed: {});
    expect(report.isClean, isFalse);
  });

  test('a failure makes the report not clean', () {
    final report = DriftScanReport(
      reconciled: const [],
      failed: {'inbox/today.md': StateError('unreadable')},
    );
    expect(report.isClean, isFalse);
  });
}
