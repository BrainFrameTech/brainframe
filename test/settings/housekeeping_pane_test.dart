import 'dart:typed_data';

import 'package:brainframe/engram/engram.dart';
import 'package:brainframe/engram/engram_repository.dart';
import 'package:brainframe/engram/engram_store.dart';
import 'package:brainframe/engram/note_reconciler.dart';
import 'package:brainframe/settings/housekeeping_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/localized_app.dart';

RegisteredEngram _engram(
  String id, {
  String name = 'Field Notebook',
  String path = '/home/user/notes',
  bool available = true,
}) => RegisteredEngram(
  id: id,
  displayName: name,
  path: path,
  available: available,
);

void main() {
  /// A fake repository surface: [load] serves the current list; [forget] records
  /// the id and drops it, so a reload reflects the change — no filesystem.
  late List<RegisteredEngram> engrams;
  late List<String> forgotten;

  Future<List<RegisteredEngram>> load() async => List.of(engrams);
  Future<void> forget(String id) async {
    forgotten.add(id);
    engrams.removeWhere((e) => e.id == id);
  }

  setUp(() {
    engrams = [];
    forgotten = [];
  });

  Widget host({Engram? engram, NoteReconciler? notes}) => localizedApp(
    home: Scaffold(
      body: HousekeepingPane(
        load: load,
        forget: forget,
        engram: engram,
        notes: notes,
      ),
    ),
  );

  final field = Engram(
    id: '01JAB2CD3EFGHJKMNPQRSTVWXY',
    displayName: 'Field Notebook',
    readOnly: false,
    store: _InertStore(),
  );

  testWidgets('lists an engram with its path and a Forget button', (
    tester,
  ) async {
    engrams = [_engram('a', name: 'Field Notebook', path: '/home/user/notes')];

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.text('Field Notebook'), findsOneWidget);
    expect(find.text('/home/user/notes'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Forget'), findsOneWidget);
  });

  testWidgets('shows the empty state when nothing is registered', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.textContaining('Nothing to forget'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Forget'), findsNothing);
  });

  testWidgets('a dangling entry (missing folder) is badged Missing', (
    tester,
  ) async {
    engrams = [_engram('a', available: false)];

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.text('MISSING'), findsOneWidget); // badge, uppercased
  });

  testWidgets('confirming Forget calls forget and drops it from the list', (
    tester,
  ) async {
    engrams = [_engram('a', name: 'Field Notebook')];

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Forget'));
    await tester.pumpAndSettle();

    // Confirmation dialog; confirm via its TextButton.
    await tester.tap(find.widgetWithText(TextButton, 'Forget'));
    await tester.pumpAndSettle();

    expect(forgotten, ['a']);
    expect(find.text('Field Notebook'), findsNothing);
    expect(find.textContaining('Nothing to forget'), findsOneWidget);
  });

  testWidgets('cancelling Forget leaves it untouched', (tester) async {
    engrams = [_engram('a', name: 'Field Notebook')];

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(OutlinedButton, 'Forget'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(forgotten, isEmpty);
    expect(find.text('Field Notebook'), findsOneWidget);
  });

  group('the ledger', () {
    testWidgets('is absent when no engram is open', (tester) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      expect(find.textContaining('Notes in'), findsNothing);
    });

    testWidgets('says so when the engram has no catalog', (tester) async {
      // A built-in, or a platform with no local database.
      await tester.pumpWidget(host(engram: field));
      await tester.pumpAndSettle();

      expect(find.text('Notes in “Field Notebook”'), findsOneWidget);
      expect(find.textContaining('has no note catalog'), findsOneWidget);
      expect(find.text('Recent scans'), findsNothing);
    });

    testWidgets('shows the counts, in words', (tester) async {
      final notes = _Notes.named(
        ledgerValue: const NoteLedger(
          peers: 2,
          minted: 312,
          adopted: 5,
          unclaimed: 2,
          tombstoned: 3,
        ),
      );
      await tester.pumpWidget(host(engram: field, notes: notes));
      await tester.pumpAndSettle();

      expect(
        find.text('2 devices have written to this engram, including this one.'),
        findsOneWidget,
      );
      expect(find.textContaining('312 notes were minted'), findsOneWidget);
      expect(find.textContaining('5 notes were adopted'), findsOneWidget);
      expect(find.text('2 of them have no history anywhere.'), findsOneWidget);
      expect(find.textContaining('3 deleted notes'), findsOneWidget);
      expect(find.text('Recent scans'), findsOneWidget);
      expect(find.textContaining('Nothing to show'), findsOneWidget);
    });

    testWidgets('says when the last scan ran, once one has', (tester) async {
      final notes = _Notes.named(
        ledgerValue: NoteLedger(
          peers: 1,
          minted: 0,
          adopted: 0,
          unclaimed: 0,
          tombstoned: 0,
          lastScanAt: DateTime(2026, 9, 12, 9, 27),
        ),
      );
      await tester.pumpWidget(host(engram: field, notes: notes));
      await tester.pumpAndSettle();

      expect(find.text('Last scan: 9:27 AM.'), findsOneWidget);
    });

    testWidgets('the singular and zero forms read as sentences', (
      tester,
    ) async {
      final notes = _Notes.named(
        ledgerValue: const NoteLedger(
          peers: 1,
          minted: 1,
          adopted: 0,
          unclaimed: 0,
          tombstoned: 0,
        ),
      );
      await tester.pumpWidget(host(engram: field, notes: notes));
      await tester.pumpAndSettle();

      expect(
        find.text('One device has written to this engram — this one.'),
        findsOneWidget,
      );
      expect(find.textContaining('1 note was minted'), findsOneWidget);
      expect(find.textContaining('No notes were adopted'), findsOneWidget);
      expect(find.textContaining('of them have no history'), findsNothing);
      expect(find.textContaining('No deleted notes'), findsOneWidget);
    });

    testWidgets('lists recent scans, newest first, with what each did', (
      tester,
    ) async {
      final notes = _Notes.named(
        ledgerValue: const NoteLedger(
          peers: 1,
          minted: 0,
          adopted: 0,
          unclaimed: 0,
          tombstoned: 0,
        ),
        scans: [
          ScanNotice(
            id: 2,
            at: DateTime(2026, 9, 12, 14, 30),
            trigger: ScanTrigger.resume,
            report: const DriftScanReport(
              reconciled: ['a.md', 'b.md'],
              moved: {'old.md': 'new.md'},
            ),
          ),
          ScanNotice(
            id: 1,
            at: DateTime(2026, 9, 12, 9, 5),
            trigger: ScanTrigger.open,
            report: const DriftScanReport(created: ['c.md'], adopted: ['d.md']),
          ),
        ],
      );
      await tester.pumpWidget(host(engram: field, notes: notes));
      await tester.pumpAndSettle();

      expect(find.text('2 notes updated from disk, 1 moved'), findsOneWidget);
      expect(find.text('1 created, 1 adopted'), findsOneWidget);
      expect(find.text('2:30 PM · on resume'), findsOneWidget);
      expect(find.text('9:05 AM · at open'), findsOneWidget);
      // Newest first: 14:30's card is above 09:05's.
      final later = tester.getTopLeft(
        find.text('2 notes updated from disk, 1 moved'),
      );
      final earlier = tester.getTopLeft(find.text('1 created, 1 adopted'));
      expect(later.dy, lessThan(earlier.dy));
    });

    testWidgets('Dismiss hides a recorded scan and tells the reconciler', (
      tester,
    ) async {
      final notes = _Notes.named(
        ledgerValue: const NoteLedger(
          peers: 1,
          minted: 0,
          adopted: 0,
          unclaimed: 0,
          tombstoned: 0,
        ),
        scans: [
          ScanNotice(
            id: 7,
            at: DateTime(2026, 9, 12, 14, 30),
            report: const DriftScanReport(created: ['c.md']),
          ),
        ],
      );
      await tester.pumpWidget(host(engram: field, notes: notes));
      await tester.pumpAndSettle();
      expect(find.text('1 created'), findsOneWidget);

      final dismiss = find.widgetWithText(TextButton, 'Dismiss');
      expect(
        tester.getSemantics(dismiss).label,
        contains('Dismiss the scan from 2:30 PM'),
      );
      await tester.tap(dismiss);
      await tester.pumpAndSettle();

      expect(notes.dismissed, [7]);
      expect(find.text('1 created'), findsNothing);
      expect(find.textContaining('Nothing to show'), findsOneWidget);
    });

    testWidgets('a notice that was never recorded has no Dismiss', (
      tester,
    ) async {
      final notes = _Notes.named(
        ledgerValue: const NoteLedger(
          peers: 1,
          minted: 0,
          adopted: 0,
          unclaimed: 0,
          tombstoned: 0,
        ),
        scans: [
          ScanNotice(
            at: DateTime(2026, 9, 12, 14, 30),
            report: const DriftScanReport(created: ['c.md']),
          ),
        ],
      );
      await tester.pumpWidget(host(engram: field, notes: notes));
      await tester.pumpAndSettle();

      expect(find.text('Dismiss'), findsNothing);
    });

    testWidgets('a history loss is spelled out, with the paths', (
      tester,
    ) async {
      final notes = _Notes.named(
        ledgerValue: const NoteLedger(
          peers: 1,
          minted: 0,
          adopted: 0,
          unclaimed: 0,
          tombstoned: 1,
        ),
        scans: [
          ScanNotice(
            at: DateTime(2026, 9, 12, 14, 30),
            report: const DriftScanReport(
              tombstoned: ['trails/old.md'],
              created: ['trails/rewritten.md'],
            ),
          ),
        ],
      );
      await tester.pumpWidget(host(engram: field, notes: notes));
      await tester.pumpAndSettle();

      expect(find.text('1 created, 1 deleted'), findsOneWidget);
      expect(
        find.textContaining(
          'Deleted: trails/old.md. Created: trails/rewritten.md.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('failures and an unlisted folder are each their own line', (
      tester,
    ) async {
      final notes = _Notes.named(
        ledgerValue: const NoteLedger(
          peers: 1,
          minted: 0,
          adopted: 0,
          unclaimed: 0,
          tombstoned: 0,
        ),
        scans: [
          ScanNotice(
            at: DateTime(2026, 9, 12, 14, 30),
            report: DriftScanReport(
              failed: {'bad.md': const FormatException('not UTF-8')},
              listingFailure: StateError('unmounted'),
            ),
          ),
        ],
      );
      await tester.pumpWidget(host(engram: field, notes: notes));
      await tester.pumpAndSettle();

      expect(find.text('1 failed'), findsOneWidget);
      expect(
        find.textContaining('Could not reconcile bad.md: FormatException'),
        findsOneWidget,
      );
      expect(
        find.textContaining('The folder could not be listed'),
        findsOneWidget,
      );
    });
  });
}

class _InertStore extends EngramStore {
  @override
  Future<List<String>> list() async => const [];

  @override
  Future<Uint8List> readBytes(String path) async => Uint8List(0);

  @override
  Future<void> writeBytes(String path, Uint8List bytes) async {}
}

/// A reconciler that only answers the two questions the pane asks.
class _Notes implements NoteReconciler {
  _Notes.named({required this.ledgerValue, List<ScanNotice> scans = const []})
      : scans = List.of(scans);

  final NoteLedger ledgerValue;
  final List<ScanNotice> scans;
  final List<int> dismissed = [];

  @override
  Future<NoteLedger> ledger() async => ledgerValue;

  @override
  Future<List<ScanNotice>> recentScans({int limit = 20}) async =>
      scans.take(limit).toList();

  @override
  Future<void> dismissScan(int id) async {
    dismissed.add(id);
    scans.removeWhere((scan) => scan.id == id);
  }

  @override
  Future<DriftScanReport> scan({ScanTrigger trigger = ScanTrigger.manual}) async => DriftScanReport.clean;

  @override
  Future<bool> reconcile(String path) async => false;

  @override
  Future<void> noteCreated(String path) async {}

  @override
  Future<void> noteMoved(String from, String to) async {}

  @override
  Future<void> noteDeleted(String path) async {}

  @override
  Stream<String> get reconciled => const Stream<String>.empty();

  @override
  Stream<AdoptionProgress?> get adoption =>
      const Stream<AdoptionProgress?>.empty();

  @override
  AdoptionProgress? get currentAdoption => null;
}
