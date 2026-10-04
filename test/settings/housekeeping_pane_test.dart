import 'dart:io';
import 'dart:typed_data';

import 'package:brainframe/engram/engram.dart';
import 'package:brainframe/engram/engram_repository.dart';
import 'package:brainframe/engram/engram_store.dart';
import 'package:brainframe/engram/fs/folder_access.dart';
import 'package:brainframe/engram/note_reconciler.dart';
import 'package:brainframe/engram/watch/engram_watcher.dart';
import 'package:brainframe/settings/housekeeping_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/localized_app.dart';

RegisteredEngram _engram(
  String id, {
  String name = 'Field Notebook',
  String path = '/home/user/notes',
  bool available = true,
  UnreachableReason reason = UnreachableReason.missing,
}) => RegisteredEngram(
  id: id,
  displayName: name,
  path: path,
  available: available,
  reason: reason,
);

void main() {
  /// A fake repository surface: [load] serves the current list; [forget] and
  /// [cleanUp] record the id and drop it, so a reload reflects the change — no
  /// filesystem. [cleanUpError], when set, makes [cleanUp] fail instead, the
  /// way a refused delete would, leaving the entry in place.
  late List<RegisteredEngram> engrams;
  late List<String> forgotten;
  late List<String> cleanedUp;
  Object? cleanUpError;

  Future<List<RegisteredEngram>> load() async => List.of(engrams);
  Future<void> forget(String id) async {
    forgotten.add(id);
    engrams.removeWhere((e) => e.id == id);
  }

  Future<void> cleanUp(String id) async {
    if (cleanUpError != null) throw cleanUpError!;
    cleanedUp.add(id);
    engrams.removeWhere((e) => e.id == id);
  }

  setUp(() {
    engrams = [];
    forgotten = [];
    cleanedUp = [];
    cleanUpError = null;
  });

  Widget host({
    Engram? engram,
    NoteReconciler? notes,
    ValueNotifier<EngramWatchUnavailable?>? liveUpdates,
    CeilingChanger? changeCeiling,
    void Function(Engram engram)? onCeilingChanged,
    void Function(String path)? onOpenNote,
  }) => localizedApp(
    home: Scaffold(
      body: HousekeepingPane(
        load: load,
        forget: forget,
        cleanUp: cleanUp,
        engram: engram,
        notes: notes,
        liveUpdates: liveUpdates,
        changeCeiling: changeCeiling,
        onCeilingChanged: onCeilingChanged,
        onOpenNote: onOpenNote,
        // Pinned, so whether a card's date carries its year does not depend
        // on the year the suite runs in.
        now: () => DateTime(2026, 9, 29, 12),
      ),
    ),
  );

  const emptyLedger = NoteLedger(
    peers: 1,
    minted: 0,
    adopted: 0,
    unclaimed: 0,
    tombstoned: 0,
  );

  final field = Engram(
    id: '01JAB2CD3EFGHJKMNPQRSTVWXY',
    displayName: 'Field Notebook',
    readOnly: false,
    store: _InertStore(),
  );

  /// The same engram, recording a ceiling below this build's capability.
  Engram at(int ceilingBytes) => field.withNoteSizeCeilingBytes(ceilingBytes);

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

  testWidgets('lost access is badged No access, never Missing', (tester) async {
    engrams = [
      _engram('a', available: false, reason: UnreachableReason.accessNeeded),
    ];

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.text('NO ACCESS'), findsOneWidget);
    expect(find.text('MISSING'), findsNothing);
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

  group('Clean up', () {
    Finder button() => find.widgetWithText(OutlinedButton, 'Clean up');

    testWidgets('sits beside Forget on every row', (tester) async {
      engrams = [_engram('a'), _engram('b', name: 'Second')];

      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      expect(button(), findsNWidgets(2));
      expect(find.widgetWithText(OutlinedButton, 'Forget'), findsNWidgets(2));
      expect(find.textContaining('switch to another engram'), findsNothing);
    });

    testWidgets('confirming calls cleanUp and drops the row', (tester) async {
      engrams = [_engram('a', name: 'Field Notebook', path: '/home/u/notes')];

      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      await tester.tap(button());
      await tester.pumpAndSettle();

      // The dialog says what goes and what stays, naming the folder.
      expect(find.text('Clean up “Field Notebook”?'), findsOneWidget);
      expect(
        find.textContaining('.brainframe folder inside /home/u/notes'),
        findsOneWidget,
      );
      expect(find.textContaining('Your notes are not touched'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'Clean up'));
      await tester.pumpAndSettle();

      expect(cleanedUp, ['a']);
      expect(forgotten, isEmpty);
      expect(find.text('Field Notebook'), findsNothing);
      expect(
        find.textContaining('Nothing to forget or clean up'),
        findsOneWidget,
      );
    });

    testWidgets('cancelling leaves it untouched', (tester) async {
      engrams = [_engram('a', name: 'Field Notebook')];

      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      await tester.tap(button());
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();

      expect(cleanedUp, isEmpty);
      expect(find.text('Field Notebook'), findsOneWidget);
    });

    testWidgets('is disabled for the open engram, with a hint; Forget is not', (
      tester,
    ) async {
      engrams = [_engram(field.id, name: 'Field Notebook'), _engram('b')];

      await tester.pumpWidget(host(engram: field));
      await tester.pumpAndSettle();

      final buttons = tester.widgetList<OutlinedButton>(button()).toList();
      expect(buttons, hasLength(2));
      expect(buttons.first.onPressed, isNull, reason: 'the open engram');
      expect(buttons.last.onPressed, isNotNull, reason: 'any other engram');
      expect(find.textContaining('switch to another engram'), findsOneWidget);
      for (final forget in tester.widgetList<OutlinedButton>(
        find.widgetWithText(OutlinedButton, 'Forget'),
      )) {
        expect(forget.onPressed, isNotNull);
      }

      // Tapping the disabled button opens nothing.
      await tester.tap(button().first, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.text('Clean up “Field Notebook”?'), findsNothing);
    });

    testWidgets('a failure is reported and the row stays for a retry', (
      tester,
    ) async {
      engrams = [_engram('a', name: 'Field Notebook')];
      cleanUpError = const FileSystemException('Permission denied', '/x');

      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      await tester.tap(button());
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Clean up'));
      await tester.pumpAndSettle();

      expect(find.text('Could not clean up “Field Notebook”'), findsOneWidget);
      expect(find.textContaining('Permission denied'), findsOneWidget);
      expect(find.textContaining('try again'), findsOneWidget);

      await tester.tap(find.widgetWithText(TextButton, 'OK'));
      await tester.pumpAndSettle();

      expect(find.text('Could not clean up “Field Notebook”'), findsNothing);
      expect(find.text('Field Notebook'), findsOneWidget);
      expect(button(), findsOneWidget);
    });

    testWidgets('lost file access is said in words, not the exception', (
      tester,
    ) async {
      engrams = [_engram('a', name: 'Field Notebook')];
      cleanUpError = const FolderAccessException(
        UnreachableReason.accessNeeded,
        'Broad storage access is not granted.',
      );

      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      await tester.tap(button());
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Clean up'));
      await tester.pumpAndSettle();

      expect(find.text('Could not clean up “Field Notebook”'), findsOneWidget);
      expect(
        find.textContaining('no longer has permission to reach this folder'),
        findsOneWidget,
      );
      expect(find.textContaining('FolderAccessException'), findsNothing);
      expect(find.textContaining('Broad storage access'), findsNothing);
      expect(find.textContaining('try again'), findsOneWidget);
    });

    testWidgets('the intro names both actions and what each deletes', (
      tester,
    ) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      expect(find.textContaining('Cleaning up also deletes'), findsOneWidget);
      expect(find.textContaining('leaving only your notes'), findsOneWidget);
    });
  });

  group('live updates (the filesystem watcher design, Decision 9)', () {
    testWidgets('nothing is said while they are on', (tester) async {
      await tester.pumpWidget(
        host(engram: field, liveUpdates: ValueNotifier(null)),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Live updates are off'), findsNothing);
    });

    for (final (kind, why) in [
      (WatchUnavailableKind.unsupported, 'this device cannot watch folders'),
      (WatchUnavailableKind.watchLimit, 'limit on watched folders is reached'),
      (WatchUnavailableKind.failed, 'watching the folder failed'),
    ]) {
      testWidgets('off because ${kind.name}: says so, why, and what still '
          'works', (tester) async {
        await tester.pumpWidget(
          host(
            engram: field,
            liveUpdates: ValueNotifier(EngramWatchUnavailable('x', kind: kind)),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.textContaining('Live updates are off'), findsOneWidget);
        expect(find.textContaining(why), findsOneWidget);
        expect(find.textContaining('still picked up'), findsOneWidget);
      });
    }

    testWidgets('a watch that dies while Settings is open is said at once', (
      tester,
    ) async {
      final status = ValueNotifier<EngramWatchUnavailable?>(null);
      await tester.pumpWidget(host(engram: field, liveUpdates: status));
      await tester.pumpAndSettle();

      status.value = const EngramWatchUnavailable('lost');
      await tester.pump();

      expect(find.textContaining('Live updates are off'), findsOneWidget);
    });
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
      expect(find.text('Sep 12, 2:30 PM · on resume'), findsOneWidget);
      expect(find.text('Sep 12, 9:05 AM · at open'), findsOneWidget);
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
        contains('Dismiss the scan from Sep 12, 2:30 PM'),
      );
      await tester.tap(dismiss);
      await tester.pumpAndSettle();

      expect(notes.dismissed, [7]);
      expect(find.text('1 created'), findsNothing);
      expect(find.textContaining('Nothing to show'), findsOneWidget);
    });

    testWidgets('Dismiss all dismisses up to the newest scan shown', (
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
        // Two cards from the same minute that read alike: the case that
        // made one-at-a-time dismissal look broken.
        scans: [
          ScanNotice(
            id: 9,
            at: DateTime(2026, 9, 12, 14, 30, 40),
            report: const DriftScanReport(reconciled: ['a.md']),
          ),
          ScanNotice(
            id: 8,
            at: DateTime(2026, 9, 12, 14, 30, 10),
            report: const DriftScanReport(reconciled: ['a.md']),
          ),
          ScanNotice(
            id: 3,
            at: DateTime(2026, 9, 12, 9, 5),
            report: const DriftScanReport(created: ['c.md']),
          ),
        ],
      );
      await tester.pumpWidget(host(engram: field, notes: notes));
      await tester.pumpAndSettle();
      expect(find.text('1 note updated from disk'), findsNWidgets(2));

      final all = find.widgetWithText(TextButton, 'Dismiss all');
      expect(
        tester.getSemantics(all).label,
        contains('Dismiss all 3 recent scans'),
      );
      await tester.tap(all);
      await tester.pumpAndSettle();

      expect(notes.dismissedThrough, [9]);
      expect(notes.dismissed, isEmpty);
      expect(find.text('1 note updated from disk'), findsNothing);
      expect(find.text('1 created'), findsNothing);
      expect(find.textContaining('Nothing to show'), findsOneWidget);
      expect(find.text('Dismiss all'), findsNothing);
    });

    testWidgets('Dismiss all is not offered for a single scan', (tester) async {
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
          // Never recorded, so there is nothing to dismiss it through.
          ScanNotice(
            at: DateTime(2026, 9, 12, 9, 5),
            report: const DriftScanReport(created: ['d.md']),
          ),
        ],
      );
      await tester.pumpWidget(host(engram: field, notes: notes));
      await tester.pumpAndSettle();

      expect(find.text('Dismiss'), findsOneWidget);
      expect(find.text('Dismiss all'), findsNothing);
    });

    testWidgets('a folded card spans its run, and Dismiss takes all of it', (
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
            id: 13,
            folded: const [12, 11, 10],
            since: DateTime(2026, 9, 28, 17, 16),
            at: DateTime(2026, 9, 28, 17, 24),
            trigger: ScanTrigger.watcher,
            report: const DriftScanReport(reconciled: ['a.md', 'b.md']),
          ),
        ],
      );
      await tester.pumpWidget(host(engram: field, notes: notes));
      await tester.pumpAndSettle();

      expect(
        find.text('Sep 28, 5:16 PM–5:24 PM · from the watcher'),
        findsOneWidget,
      );
      expect(find.text('2 notes updated from disk'), findsOneWidget);
      final dismiss = find.widgetWithText(TextButton, 'Dismiss');
      expect(
        tester.getSemantics(dismiss).label,
        contains('Dismiss the scan from Sep 28, 5:16 PM–5:24 PM'),
      );

      await tester.tap(dismiss);
      await tester.pumpAndSettle();
      expect(notes.dismissed, [13, 12, 11, 10]);
      expect(find.textContaining('Nothing to show'), findsOneWidget);
    });

    testWidgets('a run inside one minute shows that minute, not a range', (
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
            folded: const [1],
            since: DateTime(2026, 9, 28, 17, 16, 5),
            at: DateTime(2026, 9, 28, 17, 16, 50),
            trigger: ScanTrigger.note,
            report: const DriftScanReport(reconciled: ['a.md']),
          ),
        ],
      );
      await tester.pumpWidget(host(engram: field, notes: notes));
      await tester.pumpAndSettle();

      expect(
        find.text('Sep 28, 5:16 PM · when a note was opened or saved'),
        findsOneWidget,
      );
    });

    testWidgets('every card is dated; the year only when it is not this one', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final notes = _Notes.named(
        ledgerValue: emptyLedger,
        scans: [
          // Newest first, across days: the order reads right only with
          // the dates, since 9:19 PM sits above 9:38 PM.
          ScanNotice(
            id: 3,
            at: DateTime(2026, 9, 29, 21, 19),
            trigger: ScanTrigger.open,
            report: const DriftScanReport(adopted: ['a.md']),
          ),
          ScanNotice(
            id: 2,
            at: DateTime(2026, 9, 28, 21, 38),
            trigger: ScanTrigger.watcher,
            report: const DriftScanReport(reconciled: ['b.md']),
          ),
          // Kept past a year: a scan that lost history is never pruned.
          ScanNotice(
            id: 1,
            at: DateTime(2025, 3, 4, 8, 15),
            trigger: ScanTrigger.resume,
            report: const DriftScanReport(
              tombstoned: ['c.md'],
              created: ['d.md'],
            ),
          ),
        ],
      );
      await tester.pumpWidget(host(engram: field, notes: notes));
      await tester.pumpAndSettle();

      expect(find.text('Sep 29, 9:19 PM · at open'), findsOneWidget);
      expect(find.text('Sep 28, 9:38 PM · from the watcher'), findsOneWidget);
      expect(find.text('Mar 4, 2025, 8:15 AM · on resume'), findsOneWidget);
    });

    testWidgets('a run across midnight names both dates', (tester) async {
      final notes = _Notes.named(
        ledgerValue: emptyLedger,
        scans: [
          ScanNotice(
            id: 2,
            folded: const [1],
            since: DateTime(2026, 9, 28, 23, 58),
            at: DateTime(2026, 9, 29, 0, 2),
            trigger: ScanTrigger.watcher,
            report: const DriftScanReport(reconciled: ['a.md']),
          ),
        ],
      );
      await tester.pumpWidget(host(engram: field, notes: notes));
      await tester.pumpAndSettle();

      expect(
        find.text('Sep 28, 11:58 PM–Sep 29, 12:02 AM · from the watcher'),
        findsOneWidget,
      );
    });

    testWidgets('a long dated header fits a phone', (tester) async {
      // The header stacks when above what: side by side, a dated range and
      // its trigger overflowed a narrow card.
      tester.view.physicalSize = const Size(360, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final notes = _Notes.named(
        ledgerValue: emptyLedger,
        scans: [
          ScanNotice(
            id: 2,
            folded: const [1],
            since: DateTime(2026, 9, 28, 23, 58),
            at: DateTime(2026, 9, 29, 0, 2),
            trigger: ScanTrigger.note,
            report: const DriftScanReport(
              reconciled: ['a.md', 'b.md'],
              created: ['c.md'],
              moved: {'d.md': 'e.md'},
            ),
          ),
        ],
      );
      await tester.pumpWidget(host(engram: field, notes: notes));
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(find.text('Dismiss'), findsOneWidget);
    });

    testWidgets('a failed dismissal is said, and the cards stay', (
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
          ScanNotice(
            id: 6,
            at: DateTime(2026, 9, 12, 9, 5),
            report: const DriftScanReport(created: ['d.md']),
          ),
        ],
      );
      await tester.pumpWidget(host(engram: field, notes: notes));
      await tester.pumpAndSettle();
      notes.dismissError = StateError('database is locked');
      const said = 'Could not dismiss: Bad state: database is locked';

      await tester.tap(find.widgetWithText(TextButton, 'Dismiss').first);
      await tester.pumpAndSettle();
      expect(find.text(said), findsOneWidget);
      expect(find.text('1 created'), findsNWidgets(2));

      ScaffoldMessenger.of(
        tester.element(find.text('1 created').first),
      ).removeCurrentSnackBar();
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Dismiss all'));
      await tester.pumpAndSettle();
      expect(find.text(said), findsOneWidget);
      expect(find.text('1 created'), findsNWidgets(2));
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

    testWidgets('an oversized arrival is counted, explained, and listed', (
      tester,
    ) async {
      // Step 18: a text file over the ceiling was tracked as a plain file.
      // The card says how many, why, which, and what to do; the ledger
      // says how many notes are in that state overall.
      final notes = _Notes.named(
        ledgerValue: const NoteLedger(
          peers: 1,
          minted: 3,
          adopted: 0,
          unclaimed: 0,
          tombstoned: 0,
          plainFiles: 2,
        ),
        scans: [
          ScanNotice(
            at: DateTime(2026, 9, 12, 14, 30),
            report: const DriftScanReport(
              created: ['a.md'],
              oversized: ['journal/2025.md', 'exports/chat.md'],
            ),
          ),
        ],
      );
      await tester.pumpWidget(host(engram: field, notes: notes));
      await tester.pumpAndSettle();

      expect(
        find.text('1 created, 2 too large to keep history'),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'Larger than 131,072 bytes on arrival, so tracked as plain files '
          'with no history: journal/2025.md, exports/chat.md.',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          '2 notes are plain files: they were larger than '
          '131,072 bytes when they arrived',
        ),
        findsOneWidget,
      );
    });

    testWidgets('conversions here and elsewhere are each their own line', (
      tester,
    ) async {
      // Step 19. A conversion here is by request, so the line is plain; one
      // made elsewhere cost this device history, so that line is emphasised
      // and says how much.
      final notes = _Notes.named(
        ledgerValue: const NoteLedger(
          peers: 2,
          minted: 3,
          adopted: 1,
          unclaimed: 0,
          tombstoned: 0,
          plainFiles: 2,
        ),
        scans: [
          ScanNotice(
            at: DateTime(2026, 9, 12, 14, 30),
            trigger: ScanTrigger.manual,
            report: const DriftScanReport(converted: ['journal/2025.md']),
          ),
          ScanNotice(
            at: DateTime(2026, 9, 12, 9, 5),
            trigger: ScanTrigger.open,
            report: const DriftScanReport(
              convertedElsewhere: {'shared/big.md': 12, 'shared/other.md': 0},
            ),
          ),
        ],
      );
      await tester.pumpWidget(host(engram: field, notes: notes));
      await tester.pumpAndSettle();

      expect(find.text('1 made a plain file'), findsOneWidget);
      expect(
        find.text(
          'Made a plain file at your request, history dropped: '
          'journal/2025.md.',
        ),
        findsOneWidget,
      );
      expect(find.text('2 made plain files on another device'), findsOneWidget);
      expect(
        find.text(
          'shared/big.md: made a plain file on another device, so 12 '
          'edits of its history on this device are no longer reachable.',
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          'shared/other.md: made a plain file on another device, so '
          'it keeps no history here either.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a note awaiting a decision is listed with its two verbs', (
      tester,
    ) async {
      // Step 20. The card is the asking: what happened, what each choice
      // keeps and loses, and a button for each.
      final notes = _Notes.named(
        ledgerValue: const NoteLedger(
          peers: 1,
          minted: 2,
          adopted: 0,
          unclaimed: 0,
          tombstoned: 0,
        ),
        pending: [
          const PendingNote(path: 'journal/2025.md', sizeBytes: 140206),
        ],
      );
      await tester.pumpWidget(host(engram: field, notes: notes));
      await tester.pumpAndSettle();

      expect(find.text('Awaiting your decision'), findsOneWidget);
      expect(
        find.text(
          'journal/2025.md is now 140,206 bytes; the limit is 131,072.',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'keeps this larger file beside it as '
          '“2025 (oversized).md”',
        ),
        findsOneWidget,
      );
      final reconstruct = find.widgetWithText(FilledButton, 'Reconstruct');
      expect(
        tester.getSemantics(reconstruct).label,
        contains('Reconstruct journal/2025.md'),
      );
      final convert = find.widgetWithText(
        TextButton,
        'Convert to a plain file',
      );
      expect(
        tester.getSemantics(convert).label,
        contains('Convert journal/2025.md to a plain file'),
      );
    });

    testWidgets('Reconstruct and Convert act at once and reload', (
      tester,
    ) async {
      final notes = _Notes.named(
        ledgerValue: const NoteLedger(
          peers: 1,
          minted: 2,
          adopted: 0,
          unclaimed: 0,
          tombstoned: 0,
        ),
        pending: [
          const PendingNote(path: 'a.md', sizeBytes: 140000),
          const PendingNote(path: 'b.md', sizeBytes: 150000),
        ],
      );
      await tester.pumpWidget(host(engram: field, notes: notes));
      await tester.pumpAndSettle();
      expect(find.byType(FilledButton), findsNWidgets(2));

      await tester.tap(find.widgetWithText(FilledButton, 'Reconstruct').first);
      await tester.pumpAndSettle();

      expect(notes.reconstructed, ['a.md']);
      expect(find.byType(FilledButton), findsOneWidget, reason: 're-read');

      await tester.tap(
        find.widgetWithText(TextButton, 'Convert to a plain file'),
      );
      await tester.pumpAndSettle();

      expect(notes.converted, ['b.md']);
      expect(find.text('Awaiting your decision'), findsNothing);
    });

    testWidgets('a scan card says a note is waiting, and one was rebuilt', (
      tester,
    ) async {
      final notes = _Notes.named(
        ledgerValue: const NoteLedger(
          peers: 1,
          minted: 2,
          adopted: 0,
          unclaimed: 0,
          tombstoned: 0,
        ),
        scans: [
          ScanNotice(
            at: DateTime(2026, 9, 12, 14, 30),
            report: const DriftScanReport(
              awaitingDecision: ['journal/2025.md'],
            ),
          ),
          ScanNotice(
            at: DateTime(2026, 9, 12, 9, 5),
            trigger: ScanTrigger.manual,
            report: const DriftScanReport(
              reconstructed: {'journal/2025.md': 'journal/2025 (oversized).md'},
            ),
          ),
        ],
      );
      await tester.pumpWidget(host(engram: field, notes: notes));
      await tester.pumpAndSettle();

      expect(find.text('1 awaiting a decision'), findsOneWidget);
      expect(
        find.textContaining(
          'read-only until you decide, above: journal/2025.md.',
        ),
        findsOneWidget,
      );
      expect(find.text('1 reconstructed'), findsOneWidget);
      expect(
        find.text(
          'journal/2025.md was restored to the last version BrainFrame '
          'saved; the larger file is kept as journal/2025 (oversized).md.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('the ceiling card at the capability is a statement', (
      tester,
    ) async {
      // Step 23. What the limit means and what this build can open. At the
      // capability there is nothing to change to, so nothing is offered.
      final notes = _Notes.named(ledgerValue: emptyLedger);
      await tester.pumpWidget(
        host(engram: field, notes: notes, changeCeiling: (e, b) async => e),
      );
      await tester.pumpAndSettle();

      expect(find.text('Note size limit'), findsOneWidget);
      expect(
        find.textContaining(
          'Text notes up to 131,072 bytes keep their edit '
          'history on this engram',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('can open notes up to 131,072 bytes'),
        findsOneWidget,
      );
      expect(find.textContaining('Raise to'), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
    });

    testWidgets('below the capability, the card offers the one raise', (
      tester,
    ) async {
      final notes = _Notes.named(ledgerValue: emptyLedger);
      await tester.pumpWidget(
        host(engram: at(65536), notes: notes, changeCeiling: (e, b) async => e),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining(
          'Text notes up to 65,536 bytes keep their edit '
          'history on this engram',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('can open notes up to 131,072 bytes'),
        findsOneWidget,
      );
      expect(find.text('Raise to 131,072'), findsOneWidget);
      expect(find.byType(OutlinedButton), findsOneWidget, reason: 'no other');
      expect(
        tester.getSemantics(find.text('Raise to 131,072')).label,
        contains('Raise the note size limit to 131,072 bytes'),
      );
    });

    testWidgets('without a way to change it, there is no card', (tester) async {
      final notes = _Notes.named(ledgerValue: emptyLedger);
      await tester.pumpWidget(host(engram: at(65536), notes: notes));
      await tester.pumpAndSettle();
      expect(find.text('Note size limit'), findsNothing);
      expect(find.text('Raise to 131,072'), findsNothing);
    });

    testWidgets('raising is counted, confirmed, written, and enforced', (
      tester,
    ) async {
      // Two notes wait: one the raise frees, one that arrived larger than
      // the capability itself and stays where it is.
      final notes = _Notes.named(
        ledgerValue: emptyLedger,
        pending: const [
          PendingNote(path: 'daily/big.md', sizeBytes: 70000),
          PendingNote(path: 'daily/huge.md', sizeBytes: 140000),
        ],
      );
      final written = <int>[];
      Engram? pushed;
      await tester.pumpWidget(
        host(
          engram: at(65536),
          notes: notes,
          changeCeiling: (e, b) async {
            written.add(b);
            return e.withNoteSizeCeilingBytes(b);
          },
          onCeilingChanged: (e) => pushed = e,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Raise to 131,072'));
      await tester.pumpAndSettle();

      expect(find.text('Raise the limit to 131,072 bytes?'), findsOneWidget);
      expect(
        find.textContaining(
          '1 note waiting for your decision will be '
          'editable again. Every device that opens this engram will enforce '
          'the new limit; a device running a BrainFrame that cannot open '
          'notes this large will refuse to open the engram until it is '
          'updated.',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(written, isEmpty);
      expect(notes.ceilingsSet, isEmpty);
      expect(
        find.text('Raise to 131,072'),
        findsOneWidget,
        reason: 'unchanged',
      );

      await tester.tap(find.text('Raise to 131,072'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Raise the limit'));
      await tester.pumpAndSettle();

      expect(written, [131072]);
      expect(notes.ceilingsSet, [131072], reason: 'enforced at once');
      expect(pushed!.noteSizeCeilingBytes, 131072);
      expect(
        find.text('The note size limit is now 131,072 bytes.'),
        findsOneWidget,
      );
      // The card follows: at the capability, nothing is offered.
      expect(
        find.textContaining(
          'Text notes up to 131,072 bytes keep their edit '
          'history on this engram',
        ),
        findsOneWidget,
      );
      expect(find.text('Raise to 131,072'), findsNothing);
    });

    testWidgets('with nothing waiting, the raise states only the consequence', (
      tester,
    ) async {
      final notes = _Notes.named(ledgerValue: emptyLedger);
      await tester.pumpWidget(
        host(
          engram: at(65536),
          notes: notes,
          changeCeiling: (e, b) async => e.withNoteSizeCeilingBytes(b),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Raise to 131,072'));
      await tester.pumpAndSettle();

      expect(find.text('Raise the limit to 131,072 bytes?'), findsOneWidget);
      expect(
        find.text(
          'Every device that opens this engram will enforce the new '
          'limit. A device running a BrainFrame that cannot open notes this '
          'large will refuse to open the engram until it is updated.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('waiting for your decision'), findsNothing);
    });

    testWidgets('a failed write is reported and nothing is enforced', (
      tester,
    ) async {
      final notes = _Notes.named(ledgerValue: emptyLedger);
      await tester.pumpWidget(
        host(
          engram: at(65536),
          notes: notes,
          changeCeiling: (e, b) async => throw StateError('read-only disk'),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Raise to 131,072'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Raise the limit'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('The limit could not be changed:'),
        findsOneWidget,
      );
      expect(notes.ceilingsSet, isEmpty);
      expect(
        find.text('Raise to 131,072'),
        findsOneWidget,
        reason: 'unchanged',
      );
    });

    testWidgets('a notice\'s paths open the note, and a pending card\'s too', (
      tester,
    ) async {
      // Tall enough that every card is on screen: the ListView's children
      // are built lazily, so a scroll-into-view cannot reach an unbuilt one.
      tester.view.physicalSize = const Size(1000, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final opened = <String>[];
      final notes = _Notes.named(
        ledgerValue: emptyLedger,
        pending: [const PendingNote(path: 'grown.md', sizeBytes: 140000)],
        scans: [
          ScanNotice(
            at: DateTime(2026, 9, 12, 14, 30),
            report: const DriftScanReport(
              created: ['plain.md'],
              oversized: ['big.md'],
              reconstructed: {'fixed.md': 'fixed (oversized).md'},
            ),
          ),
        ],
      );
      await tester.pumpWidget(
        host(engram: field, notes: notes, onOpenNote: opened.add),
      );
      await tester.pumpAndSettle();

      expect(find.text('big.md'), findsOneWidget);
      expect(find.text('fixed.md'), findsOneWidget);
      expect(find.text('fixed (oversized).md'), findsOneWidget);
      expect(
        find.text('plain.md'),
        findsNothing,
        reason: 'created: not offered',
      );
      expect(
        tester.getSemantics(find.text('big.md')).label,
        contains('Open big.md'),
      );
      await tester.tap(find.text('big.md'));
      await tester.tap(find.text('grown.md'));
      expect(opened, ['big.md', 'grown.md']);
    });

    testWidgets('without an editor to open in, no Open buttons', (
      tester,
    ) async {
      final notes = _Notes.named(
        ledgerValue: emptyLedger,
        scans: [
          ScanNotice(
            at: DateTime(2026, 9, 12, 14, 30),
            report: const DriftScanReport(oversized: ['big.md']),
          ),
        ],
      );
      await tester.pumpWidget(host(engram: field, notes: notes));
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.open_in_new), findsNothing);
    });

    testWidgets('the ledger line states the engram\'s own ceiling', (
      tester,
    ) async {
      final notes = _Notes.named(
        ledgerValue: const NoteLedger(
          peers: 1,
          minted: 1,
          adopted: 0,
          unclaimed: 0,
          tombstoned: 0,
          plainFiles: 1,
        ),
      );
      await tester.pumpWidget(host(engram: at(65536), notes: notes));
      await tester.pumpAndSettle();

      expect(
        find.textContaining(
          '1 note is a plain file: it was larger than '
          '65,536 bytes when it arrived',
        ),
        findsOneWidget,
      );
    });

    testWidgets('no plain files, no line', (tester) async {
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

      expect(find.textContaining('plain file'), findsNothing);
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
  group('a card\'s Details (the device names design, Decision 5)', () {
    const self = 'aaaaaaaa-1111-4111-8111-111111111111';
    const pixel = 'bbbbbbbb-2222-4222-8222-222222222222';
    const silent = '5c1e09a2-3333-4333-8333-333333333333';
    const devices = [
      SeenDevice(peer: self, name: 'jdoe-desktop', isThisDevice: true),
      SeenDevice(peer: pixel, name: 'jdoe\'s Pixel'),
      SeenDevice(peer: silent),
    ];

    NoteLedger ledgerWith(List<SeenDevice> seen) => NoteLedger(
      peers: seen.length,
      minted: 0,
      adopted: 0,
      unclaimed: 0,
      tombstoned: 0,
      devices: seen,
    );

    /// A local wall-clock time on the card's day, as the details store it:
    /// UTC. Shown back in local time, so the suite's zone does not matter.
    DateTime at(int h, int m, int s) => DateTime(2026, 9, 29, h, m, s).toUtc();

    Future<void> show(
      WidgetTester tester,
      DriftScanReport report, {
      List<SeenDevice> seen = devices,
      DateTime? since,
      List<int> folded = const [],
      void Function(String path)? onOpenNote,
    }) async {
      // Tall enough that a card's whole Details are built: the pane is a
      // lazy list, and what is below the fold is not there to find.
      tester.view.physicalSize = const Size(1200, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final notes = _Notes.named(
        ledgerValue: ledgerWith(seen),
        scans: [
          ScanNotice(
            id: 9,
            at: DateTime(2026, 9, 29, 11, 55, 1),
            since: since,
            folded: folded,
            trigger: ScanTrigger.watcher,
            report: report,
          ),
        ],
      );
      await tester.pumpWidget(
        host(engram: field, notes: notes, onOpenNote: onOpenNote),
      );
      await tester.pumpAndSettle();
    }

    Future<void> open(WidgetTester tester) async {
      await tester.tap(find.text('Details'));
      // One frame, not a settle: the details appear at once, never by
      // animation — reduced motion and e-ink both rely on it.
      await tester.pump();
    }

    testWidgets('are closed by default, and open and close in one frame', (
      tester,
    ) async {
      await show(tester, const DriftScanReport(reconciled: ['a.md']));

      expect(find.text('Details'), findsOneWidget);
      expect(find.textContaining('Taken in by'), findsNothing);

      await open(tester);
      expect(
        find.text('Taken in by jdoe-desktop (this device).'),
        findsOneWidget,
      );

      await open(tester);
      expect(find.textContaining('Taken in by'), findsNothing);
    });

    testWidgets('the toggle is a button that says what it opens, and whether '
        'it is open', (tester) async {
      final handle = tester.ensureSemantics();
      await show(tester, const DriftScanReport(reconciled: ['a.md']));

      final label = 'Details for the scan at Sep 29, 11:55 AM';
      expect(
        tester.getSemantics(find.bySemanticsLabel(label)),
        matchesSemantics(
          label: label,
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          hasExpandedState: true,
          isExpanded: false,
          hasTapAction: true,
        ),
      );
      await open(tester);
      expect(
        tester.getSemantics(find.bySemanticsLabel(label)),
        matchesSemantics(
          label: label,
          isButton: true,
          hasEnabledState: true,
          isEnabled: true,
          hasExpandedState: true,
          isExpanded: true,
          hasTapAction: true,
        ),
      );
      handle.dispose();
    });

    testWidgets('a change found on disk was taken in here, never made here', (
      tester,
    ) async {
      await show(
        tester,
        const DriftScanReport(
          reconciled: ['a.md'],
          created: ['b.md'],
          moved: {'c.md': 'd.md'},
          tombstoned: ['e.md'],
        ),
      );
      await open(tester);

      expect(
        find.text('Taken in by jdoe-desktop (this device).'),
        findsOneWidget,
        reason: "once for the card, not once a kind",
      );
      expect(find.textContaining('made on'), findsNothing);
    });

    testWidgets('a card with no change found on disk attributes none', (
      tester,
    ) async {
      await show(tester, const DriftScanReport(adopted: ['p.md']));
      await open(tester);

      expect(find.textContaining('Taken in by'), findsNothing);
    });

    testWidgets('moves read from → to, with how they matched', (tester) async {
      await show(
        tester,
        const DriftScanReport(
          moved: {'old.md': 'new.md', 'a.md': 'b.md', 'x.md': 'y.md'},
          moveMatches: {
            'old.md': MoveDetail.identical(),
            'a.md': MoveDetail.similar(0.824),
          },
        ),
      );
      await open(tester);

      expect(find.text('old.md → new.md · identical'), findsOneWidget);
      expect(find.text('a.md → b.md · similar (82%)'), findsOneWidget);
      expect(find.text('x.md → y.md'), findsOneWidget, reason: 'no detail');
    });

    testWidgets('a retirement tells the whole story, with nothing lost', (
      tester,
    ) async {
      await show(
        tester,
        DriftScanReport(
          retired: const ['notes/plans.md'],
          retirements: {
            'notes/plans.md': Retirement(
              winner: 'W',
              winnerMint: Mint(peer: pixel, at: at(11, 54, 22)),
              loserMintedAt: at(11, 54, 33),
              loserChanges: 1,
            ),
          },
        ),
      );
      await open(tester);

      expect(
        find.textContaining(
          RegExp(
            r"^notes/plans\.md — jdoe's Pixel seeded this note first "
            r'\(11:54:22\W+AM, 11 seconds earlier\), so this device.s identity '
            r'for it was retired\.$',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.text(
          'Nothing was lost: it held only its first snapshot, and the file '
          'is unchanged.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a retirement that cost history says how much', (tester) async {
      await show(
        tester,
        DriftScanReport(
          retired: const ['a.md'],
          retirements: {
            'a.md': Retirement(
              winner: 'W',
              winnerMint: Mint(peer: silent, at: at(9, 0, 0)),
              loserMintedAt: at(8, 0, 0),
              loserChanges: 14,
            ),
          },
        ),
      );
      await open(tester);

      // Seeded later by the clock: the election is by identity, not time.
      expect(
        find.textContaining('device 5c1e09a2 also seeded this note'),
        findsOneWidget,
      );
      expect(
        find.textContaining('14 changes of its history stay with the retired'),
        findsOneWidget,
      );
    });

    testWidgets('an adoption, a conversion elsewhere, and the ceiling each '
        'say why', (tester) async {
      await show(
        tester,
        DriftScanReport(
          adopted: const ['p.md'],
          adoptedFrom: {'p.md': Mint(peer: pixel, at: at(11, 54, 22))},
          convertedElsewhere: const {'big.md': 3},
          convertedBy: const {'big.md': pixel},
          oversized: const ['huge.md'],
          awaitingDecision: const ['grown.md'],
          overCeiling: const {
            'huge.md': OverCeiling(sizeBytes: 200000, ceilingBytes: 131072),
            'grown.md': OverCeiling(sizeBytes: 140000, ceilingBytes: 131072),
          },
          converted: const ['long.md', 'short.md'],
          dropped: const {'long.md': 40, 'short.md': 1},
        ),
      );
      await open(tester);

      expect(
        find.textContaining(
          RegExp(r"^p\.md — took the identity jdoe's Pixel seeded at 11:54:22"),
        ),
        findsOneWidget,
      );
      expect(
        find.text("big.md — made a plain file by jdoe's Pixel."),
        findsOneWidget,
      );
      expect(
        find.text('huge.md — 200,000 bytes, over the 131,072-byte limit.'),
        findsOneWidget,
      );
      expect(
        find.text('grown.md — 140,000 bytes, over the 131,072-byte limit.'),
        findsOneWidget,
      );
      expect(
        find.text('long.md — 40 changes of its history were dropped.'),
        findsOneWidget,
      );
      expect(
        find.text(
          // Said, not reassured: the file may no longer hold that snapshot.
          'short.md — its one change, its first snapshot, was dropped.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('how much earlier reads in the largest unit that fits', (
      tester,
    ) async {
      Retirement won(DateTime winner, DateTime loser) => Retirement(
        winner: 'W',
        winnerMint: Mint(peer: pixel, at: winner),
        loserMintedAt: loser,
        loserChanges: 1,
      );
      await show(
        tester,
        DriftScanReport(
          retired: const ['m.md', 'h.md', 'd.md'],
          retirements: {
            'm.md': won(at(9, 0, 0), at(9, 3, 0)),
            'h.md': won(at(7, 0, 0), at(9, 0, 0)),
            'd.md': won(
              DateTime(2026, 9, 25, 9).toUtc(),
              DateTime(2026, 9, 29, 9).toUtc(),
            ),
          },
        ),
      );
      await open(tester);

      expect(find.textContaining('3 minutes earlier'), findsOneWidget);
      expect(find.textContaining('2 hours earlier'), findsOneWidget);
      expect(find.textContaining('4 days earlier'), findsOneWidget);
    });

    testWidgets('a retirement with no winner claim, a reconstruction, and a '
        'failure each list what they have', (tester) async {
      final opened = <String>[];
      final handle = tester.ensureSemantics();
      await show(
        tester,
        DriftScanReport(
          retired: const ['r.md'],
          retirements: const {
            'r.md': Retirement(
              winner: 'W',
              winnerMint: null,
              loserMintedAt: null,
              loserChanges: 3,
            ),
          },
          reconstructed: const {'big.md': 'big (oversized).md'},
          failed: {'bad.md': const FormatException('not UTF-8')},
        ),
        onOpenNote: opened.add,
      );
      await open(tester);

      expect(
        find.text(
          'r.md — another identity for this note won, so this device\'s was '
          'retired.',
        ),
        findsOneWidget,
      );
      expect(
        find.textContaining('3 changes of its history stay'),
        findsOneWidget,
      );
      expect(find.text('big.md → big (oversized).md'), findsOneWidget);
      // A failure is listed under its heading, with nothing to open.
      expect(find.text('1 failed'), findsWidgets);
      expect(find.bySemanticsLabel('Open bad.md'), findsNothing);
      // The reconstructed note's own Open, beside its line in the Details.
      final opens = find.bySemanticsLabel('Open big.md');
      await tester.tap(opens.last);
      expect(opened, ['big.md']);
      handle.dispose();
    });

    testWidgets('a screen reader opens and closes the Details', (tester) async {
      final handle = tester.ensureSemantics();
      await show(tester, const DriftScanReport(reconciled: ['a.md']));
      tester.semantics.tap(
        find.semantics.byLabel('Details for the scan at Sep 29, 11:55 AM'),
      );
      await tester.pump();

      expect(find.textContaining('Taken in by'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('Open goes where the note is now, as far as the card knows', (
      tester,
    ) async {
      // A folded card: a.md updated, and a.md moved to b.md with nothing
      // else touching either — certain, so the update opens b.md. g.md
      // updated and later deleted — gone, so no Open.
      final opened = <String>[];
      final handle = tester.ensureSemantics();
      await show(
        tester,
        const DriftScanReport(
          reconciled: ['a.md', 'g.md'],
          tombstoned: ['g.md'],
          moved: {'a.md': 'b.md'},
        ),
        onOpenNote: opened.add,
      );
      await open(tester);

      expect(find.text('a.md'), findsOneWidget, reason: 'listed as it was');
      expect(find.bySemanticsLabel('Open a.md'), findsNothing);
      expect(find.bySemanticsLabel('Open g.md'), findsNothing);
      await tester.tap(find.bySemanticsLabel('Open b.md').first);
      expect(opened, ['b.md']);
      handle.dispose();
    });

    testWidgets('where the order is lost, Open goes to the path as listed', (
      tester,
    ) async {
      // Each of these could have happened in either order, and the card
      // cannot say which: a chain (a.md → b.md beside b.md → c.md), a swap
      // (p.md ↔ q.md), and a note created and deleted (x.md).
      final handle = tester.ensureSemantics();
      await show(
        tester,
        const DriftScanReport(
          reconciled: ['a.md'],
          created: ['x.md'],
          tombstoned: ['x.md'],
          moved: {
            'a.md': 'b.md',
            'b.md': 'c.md',
            'p.md': 'q.md',
            'q.md': 'p.md',
          },
        ),
        onOpenNote: (_) {},
      );
      await open(tester);

      // Never followed along the chain to c.md from a.md's update.
      expect(find.bySemanticsLabel('Open a.md'), findsOneWidget);
      // The a.md → b.md line opens b.md as listed, not c.md beyond it.
      expect(find.bySemanticsLabel('Open b.md'), findsOneWidget);
      expect(find.bySemanticsLabel('Open c.md'), findsOneWidget);
      expect(find.bySemanticsLabel('Open x.md'), findsOneWidget);
      expect(find.bySemanticsLabel('Open p.md'), findsOneWidget);
      expect(find.bySemanticsLabel('Open q.md'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('a path a new note took after a rename opens that new note', (
      tester,
    ) async {
      // a.md renamed to b.md, then a different a.md created: the created
      // line must open a.md, never be sent after the renamed note.
      final opened = <String>[];
      final handle = tester.ensureSemantics();
      await show(
        tester,
        const DriftScanReport(created: ['a.md'], moved: {'a.md': 'b.md'}),
        onOpenNote: opened.add,
      );
      await open(tester);

      await tester.tap(find.bySemanticsLabel('Open a.md'));
      await tester.tap(find.bySemanticsLabel('Open b.md'));
      expect(opened, ['a.md', 'b.md']);
      handle.dispose();
    });

    testWidgets('open Details stay open when a card above is dismissed', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      ScanNotice card(int id, String path) => ScanNotice(
        id: id,
        at: DateTime(2026, 9, 29, 9 + id),
        trigger: ScanTrigger.resume,
        report: DriftScanReport(reconciled: [path]),
      );
      final notes = _Notes.named(
        ledgerValue: ledgerWith(devices),
        scans: [card(3, 'top.md'), card(2, 'middle.md'), card(1, 'low.md')],
      );
      await tester.pumpWidget(host(engram: field, notes: notes));
      await tester.pumpAndSettle();

      // Open the middle card's Details: the second toggle.
      await tester.tap(find.text('Details').at(1));
      await tester.pump();
      expect(find.text('middle.md'), findsOneWidget);

      // Dismiss the card above it; the list reloads around it.
      await tester.tap(find.text('Dismiss').first);
      await tester.pumpAndSettle();

      expect(find.text('top.md'), findsNothing);
      expect(
        find.text('middle.md'),
        findsOneWidget,
        reason: 'its Details still open, the card kept by its record',
      );
      expect(find.text('low.md'), findsNothing, reason: 'still closed');
    });

    testWidgets('a kind lists five paths, then how many more', (tester) async {
      await show(
        tester,
        DriftScanReport(reconciled: [for (var i = 0; i < 7; i++) 'n$i.md']),
      );
      await open(tester);

      for (var i = 0; i < 5; i++) {
        expect(find.text('n$i.md'), findsOneWidget);
      }
      expect(find.text('n5.md'), findsNothing);
      expect(find.text('2 more'), findsOneWidget);
    });

    testWidgets('a folded card says how many changes, to the second', (
      tester,
    ) async {
      await show(
        tester,
        const DriftScanReport(reconciled: ['a.md']),
        since: DateTime(2026, 9, 29, 11, 41, 7),
        folded: [8, 7, 6],
      );
      await open(tester);

      expect(
        find.textContaining(
          RegExp(r'^4 changes, 11:41:07\W+AM–11:55:01\W+AM$'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('a single card gives its time to the second', (tester) async {
      await show(tester, const DriftScanReport(reconciled: ['a.md']));
      await open(tester);

      expect(
        find.textContaining(RegExp(r'^Recorded at 11:55:01\W+AM\.$')),
        findsOneWidget,
      );
    });

    testWidgets('a record from before the details shows its paths', (
      tester,
    ) async {
      await show(
        tester,
        const DriftScanReport(
          adopted: ['p.md'],
          retired: ['r.md'],
          moved: {'a.md': 'b.md'},
        ),
      );
      await open(tester);

      expect(find.text('p.md'), findsOneWidget);
      expect(find.text('a.md → b.md'), findsOneWidget);
      expect(
        find.text(
          'r.md — another identity for this note won, so this '
          'device\'s was retired.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('before the ledger names anyone, nothing is attributed', (
      tester,
    ) async {
      await show(
        tester,
        DriftScanReport(
          adopted: const ['p.md'],
          adoptedFrom: {'p.md': Mint(peer: pixel, at: at(11, 54, 22))},
        ),
        seen: const [],
      );
      await open(tester);

      expect(find.textContaining('Taken in by'), findsNothing);
      expect(find.textContaining('device bbbbbbbb seeded'), findsOneWidget);
    });

    testWidgets('a path that can be opened has an Open; a deleted one not', (
      tester,
    ) async {
      final opened = <String>[];
      final handle = tester.ensureSemantics();
      await show(
        tester,
        const DriftScanReport(
          reconciled: ['a.md'],
          moved: {'old.md': 'new.md'},
          tombstoned: ['gone.md'],
        ),
        onOpenNote: opened.add,
      );
      await open(tester);

      await tester.tap(find.bySemanticsLabel('Open a.md'));
      await tester.tap(find.bySemanticsLabel('Open new.md'));
      expect(opened, ['a.md', 'new.md']);
      expect(find.bySemanticsLabel('Open old.md'), findsNothing);
      expect(find.bySemanticsLabel('Open gone.md'), findsNothing);
      handle.dispose();
    });
  });

  group(
    'the ledger names the devices (the device names design, Decision 2)',
    () {
      testWidgets('this device first, the unnamed by short ID', (tester) async {
        final notes = _Notes.named(
          ledgerValue: const NoteLedger(
            peers: 3,
            minted: 0,
            adopted: 0,
            unclaimed: 0,
            tombstoned: 0,
            devices: [
              SeenDevice(
                peer: 'aaaaaaaa-1111-4111-8111-111111111111',
                name: 'jdoe-desktop',
                isThisDevice: true,
              ),
              SeenDevice(
                peer: 'bbbbbbbb-2222-4222-8222-222222222222',
                name: 'jdoe\'s Pixel',
              ),
              SeenDevice(peer: '5c1e09a2-3333-4333-8333-333333333333'),
            ],
          ),
        );
        await tester.pumpWidget(host(engram: field, notes: notes));
        await tester.pumpAndSettle();

        expect(
          find.text(
            '3 devices have written to this engram, including this one: '
            'jdoe-desktop (this device), jdoe\'s Pixel and device 5c1e09a2.',
          ),
          findsOneWidget,
        );
      });

      testWidgets('past five, the rest are counted', (tester) async {
        final notes = _Notes.named(
          ledgerValue: NoteLedger(
            peers: 7,
            minted: 0,
            adopted: 0,
            unclaimed: 0,
            tombstoned: 0,
            devices: [
              const SeenDevice(peer: 'self', name: 'Here', isThisDevice: true),
              for (var i = 1; i < 7; i++) SeenDevice(peer: 'p$i', name: 'D$i'),
            ],
          ),
        );
        await tester.pumpWidget(host(engram: field, notes: notes));
        await tester.pumpAndSettle();

        expect(
          find.text(
            '7 devices have written to this engram, including this one: '
            'Here (this device), D1, D2, D3, D4 and 2 more.',
          ),
          findsOneWidget,
        );
      });

      testWidgets('one device alone is named too', (tester) async {
        final notes = _Notes.named(
          ledgerValue: const NoteLedger(
            peers: 1,
            minted: 0,
            adopted: 0,
            unclaimed: 0,
            tombstoned: 0,
            devices: [
              SeenDevice(
                peer: 'self',
                name: 'jdoe-desktop',
                isThisDevice: true,
              ),
            ],
          ),
        );
        await tester.pumpWidget(host(engram: field, notes: notes));
        await tester.pumpAndSettle();

        expect(
          find.text(
            'One device has written to this engram — this one: '
            'jdoe-desktop (this device).',
          ),
          findsOneWidget,
        );
      });
    },
  );
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
  _Notes.named({
    required this.ledgerValue,
    List<ScanNotice> scans = const [],
    List<PendingNote> pending = const [],
  }) : scans = List.of(scans),
       pending = List.of(pending);

  final NoteLedger ledgerValue;
  final List<ScanNotice> scans;
  final List<PendingNote> pending;

  /// Every ceiling handed to [setNoteSizeCeiling].
  final List<int> ceilingsSet = [];
  final List<int> dismissed = [];

  /// Every id handed to [dismissScansThrough].
  final List<int> dismissedThrough = [];

  /// When set, every dismissal throws it and changes nothing, and a read
  /// fails too — as both do while the database is locked.
  Object? dismissError;
  final List<String> reconstructed = [];
  final List<String> converted = [];

  @override
  Future<NoteLedger> ledger() async => ledgerValue;

  @override
  Future<List<ScanNotice>> recentScans({int limit = 20}) async {
    if (dismissError case final error?) throw error;
    return scans.take(limit).toList();
  }

  @override
  Future<void> dismissScans(List<int> ids) async {
    if (dismissError case final error?) throw error;
    dismissed.addAll(ids);
    scans.removeWhere((scan) => scan.ids.any(ids.contains));
  }

  @override
  Future<void> dismissScansThrough(int id) async {
    if (dismissError case final error?) throw error;
    dismissedThrough.add(id);
    scans.removeWhere((scan) => scan.id != null && scan.id! <= id);
  }

  @override
  Future<void> convertToPlainFile(String path) async {
    converted.add(path);
    pending.removeWhere((note) => note.path == path);
  }

  @override
  Future<List<PendingNote>> awaitingDecision() async => List.of(pending);

  @override
  Future<String> reconstruct(String path) async {
    reconstructed.add(path);
    pending.removeWhere((note) => note.path == path);
    return asidePathFor(path);
  }

  @override
  Future<bool> isPlainFile(String path) async => false;

  @override
  Future<void> setNoteSizeCeiling(int bytes) async => ceilingsSet.add(bytes);

  @override
  Future<DriftScanReport> scan({
    ScanTrigger trigger = ScanTrigger.manual,
  }) async => DriftScanReport.clean;

  @override
  Future<bool> reconcile(String path, {ScanTrigger? trigger}) async => false;

  @override
  Future<void> noteCreated(String path) async {}

  @override
  Future<void> noteMoved(String from, String to) async {}

  @override
  Future<void> noteDeleted(String path) async {}

  @override
  Stream<String> get reconciled => const Stream<String>.empty();

  @override
  Stream<DriftScanReport> get scanReports =>
      const Stream<DriftScanReport>.empty();

  @override
  Stream<AdoptionProgress?> get adoption =>
      const Stream<AdoptionProgress?>.empty();

  @override
  AdoptionProgress? get currentAdoption => null;
}
