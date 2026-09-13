import 'dart:async';

import 'package:brainframe/engram/note_reconciler.dart';
import 'package:brainframe/engram/ui/adoption_progress.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/localized_app.dart';

/// The sidebar's adoption progress bar: something while the scan is adopting,
/// nothing at all otherwise.
void main() {
  Widget host(NoteReconciler? reconciler) => localizedApp(
    home: Scaffold(
      body: Column(children: [AdoptionProgressBar(reconciler: reconciler)]),
    ),
  );

  testWidgets('renders nothing without a reconciler', (tester) async {
    await tester.pumpWidget(host(null));
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.getSize(find.byType(AdoptionProgressBar)), Size.zero);
  });

  testWidgets('renders nothing while no adoption is running', (tester) async {
    final reconciler = _Reconciler();
    await tester.pumpWidget(host(reconciler));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.getSize(find.byType(AdoptionProgressBar)), Size.zero);
  });

  testWidgets('shows the bar and caption while adopting, then clears', (
    tester,
  ) async {
    final reconciler = _Reconciler();
    await tester.pumpWidget(host(reconciler));

    reconciler.report(const AdoptionProgress(done: 120, total: 500));
    await tester.pump();

    expect(find.text('Adopting notes… 120 of 500'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, closeTo(0.24, 0.001));

    reconciler.report(const AdoptionProgress(done: 500, total: 500));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);

    reconciler.report(null);
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('steps in the middle are coalesced to one repaint per interval', (
    tester,
  ) async {
    // A frame per note would cost more than the seeding and slow the scan
    // itself; the first and last events paint at once, the rest at ticks.
    final reconciler = _Reconciler();
    await tester.pumpWidget(host(reconciler));

    reconciler.report(const AdoptionProgress(done: 1, total: 100));
    await tester.pump();
    expect(find.text('Adopting notes… 1 of 100'), findsOneWidget);

    for (var i = 2; i <= 40; i++) {
      reconciler.report(AdoptionProgress(done: i, total: 100));
    }
    await tester.pump();
    expect(
      find.text('Adopting notes… 1 of 100'),
      findsOneWidget,
      reason: 'not yet: the tick has not come',
    );

    await tester.pump(const Duration(milliseconds: 250));
    expect(
      find.text('Adopting notes… 40 of 100'),
      findsOneWidget,
      reason: 'the latest, not each one in turn',
    );

    reconciler.report(null);
    await tester.pump();
    expect(
      find.byType(LinearProgressIndicator),
      findsNothing,
      reason: 'the end paints at once',
    );
  });

  testWidgets('a new reconciler is listened to in place of the old', (
    tester,
  ) async {
    final first = _Reconciler()
      ..current = const AdoptionProgress(done: 1, total: 2);
    final second = _Reconciler();
    await tester.pumpWidget(host(first));
    expect(find.text('Adopting notes… 1 of 2'), findsOneWidget);

    await tester.pumpWidget(host(second));
    expect(find.byType(LinearProgressIndicator), findsNothing);

    first.report(const AdoptionProgress(done: 2, total: 3));
    second.report(const AdoptionProgress(done: 5, total: 9));
    await tester.pump();
    expect(find.text('Adopting notes… 5 of 9'), findsOneWidget);
    expect(find.text('Adopting notes… 2 of 3'), findsNothing);
  });

  testWidgets('a late subscriber sees the current progress', (tester) async {
    // The browser can mount mid-scan: on an engram switch, the scan is
    // already running by the time the sidebar builds.
    final reconciler = _Reconciler()
      ..current = const AdoptionProgress(done: 3, total: 9);
    await tester.pumpWidget(host(reconciler));

    expect(find.text('Adopting notes… 3 of 9'), findsOneWidget);
  });

  testWidgets('the caption is the bar\'s accessible label, announced live', (
    tester,
  ) async {
    final reconciler = _Reconciler()
      ..current = const AdoptionProgress(done: 1, total: 4);
    await tester.pumpWidget(host(reconciler));

    final semantics = tester.getSemantics(
      find.bySemanticsLabel('Adopting notes… 1 of 4'),
    );
    expect(semantics.flagsCollection.isLiveRegion, isTrue);
  });
}

class _Reconciler implements NoteReconciler {
  final StreamController<AdoptionProgress?> _adoption =
      StreamController<AdoptionProgress?>.broadcast(sync: true);
  AdoptionProgress? current;

  void report(AdoptionProgress? progress) {
    current = progress;
    _adoption.add(progress);
  }

  @override
  Stream<AdoptionProgress?> get adoption => _adoption.stream;

  @override
  AdoptionProgress? get currentAdoption => current;

  @override
  Future<DriftScanReport> scan() async => DriftScanReport.clean;

  @override
  Future<bool> reconcile(String path) async => false;

  @override
  Future<void> noteCreated(String path) async {}

  @override
  Future<void> noteMoved(String from, String to) async {}

  @override
  Future<void> noteDeleted(String path) async {}

  @override
  Future<NoteLedger> ledger() async => const NoteLedger(
    peers: 1,
    minted: 0,
    adopted: 0,
    unclaimed: 0,
    tombstoned: 0,
  );

  @override
  List<ScanNotice> get recentScans => const [];

  @override
  Stream<String> get reconciled => const Stream<String>.empty();
}
