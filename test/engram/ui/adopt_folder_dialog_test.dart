import 'dart:async';

import 'package:brainframe/engram/desktop_folder_adoption.dart';
import 'package:brainframe/engram/fs/fs_store.dart';
import 'package:brainframe/engram/ui/adopt_folder_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/localized_app.dart';

/// The adoption dialog, driven by hand: up while the folder is looked at,
/// the confirmation in place when the counts are in.
void main() {
  /// A pass the test advances itself: [progress] reports a file, [finish]
  /// ends it with a preview, [cancelled] asks what the dialog asked.
  late FolderPreviewProgress progress;
  late FolderPreviewCancelled cancelled;
  late Completer<FolderAdoptionPreview> pass;

  FolderPreviewing previewing() {
    pass = Completer<FolderAdoptionPreview>();
    return FolderPreviewing(
      name: 'Vault',
      run: ({onProgress, isCancelled}) {
        progress = onProgress!;
        cancelled = isCancelled!;
        return pass.future;
      },
    );
  }

  FolderAdoptionPreview preview({int crlf = 1, bool isEngram = false}) =>
      FolderAdoptionPreview(
        path: '/tmp/Vault',
        name: 'Vault',
        fileCount: 3,
        crlfCount: crlf,
        isEngram: isEngram,
      );

  /// Hosts a button that shows the dialog and records its answer.
  bool? answer;
  Widget host(FolderPreviewing previewing) => localizedApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            answer = await AdoptFolderDialog.show(context, previewing);
          },
          child: const Text('pick'),
        ),
      ),
    ),
  );

  /// Shows the dialog and lets its route finish opening. Not pumpAndSettle:
  /// the listing bar is indeterminate, so the tree never settles.
  Future<void> open(WidgetTester tester, FolderPreviewing p) async {
    answer = null;
    await tester.pumpWidget(host(p));
    await tester.tap(find.text('pick'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  testWidgets('is up at once, listing, with Cancel and no Adopt', (
    tester,
  ) async {
    await open(tester, previewing());

    expect(find.text('Looking at “Vault”…'), findsOneWidget);
    expect(find.text('Listing its files…'), findsOneWidget);
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, isNull, reason: 'no total yet');
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Adopt'), findsNothing);
    expect(find.text('Adopt this folder?'), findsNothing);
  });

  testWidgets('the first count paints at once; the rest are coalesced', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await open(tester, previewing());

    progress(0, 3000);
    await tester.pump();
    expect(find.text('0 of 3,000 files'), findsOneWidget);
    final semantics = tester.getSemantics(
      find.bySemanticsLabel('0 of 3,000 files'),
    );
    expect(
      semantics.flagsCollection.isLiveRegion,
      isTrue,
      reason: 'the caption is the accessible label, announced as it changes',
    );

    progress(1, 3000);
    progress(2, 3000);
    await tester.pump();
    expect(find.text('0 of 3,000 files'), findsOneWidget, reason: 'held');

    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('2 of 3,000 files'), findsOneWidget);
    expect(find.text('1 of 3,000 files'), findsNothing, reason: 'skipped');
    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, closeTo(2 / 3000, 1e-9));
    handle.dispose();
  });

  testWidgets('becomes the confirmation in place when the counts are in', (
    tester,
  ) async {
    await open(tester, previewing());
    progress(0, 3);
    progress(3, 3);
    await tester.pump();

    pass.complete(preview());
    await tester.pump();

    expect(find.text('Looking at “Vault”…'), findsNothing);
    expect(find.text('Adopt this folder?'), findsOneWidget);
    expect(
      find.textContaining('“Vault” will become an engram'),
      findsOneWidget,
    );
    expect(find.textContaining('3 files become notes'), findsOneWidget);
    expect(
      find.textContaining('One of them uses Windows line endings'),
      findsOneWidget,
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byType(AdoptFolderDialog), findsOneWidget, reason: 'the same one');

    await tester.tap(find.text('Adopt'));
    await tester.pumpAndSettle();
    expect(answer, isTrue);
    expect(cancelled(), isFalse);
  });

  testWidgets('a folder with no CRLF files says nothing about line endings', (
    tester,
  ) async {
    await open(tester, previewing());
    pass.complete(preview(crlf: 0));
    await tester.pump();

    expect(find.text('Adopt this folder?'), findsOneWidget);
    expect(find.textContaining('line endings'), findsNothing);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(answer, isFalse);
  });

  testWidgets('Cancel while looking stops the pass and answers no', (
    tester,
  ) async {
    final p = previewing();
    await open(tester, p);
    progress(0, 3000);
    progress(1, 3000);
    await tester.pump();

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(answer, isFalse);
    expect(cancelled(), isTrue, reason: 'the walk is told to stop');
    expect(p.cancelled, isTrue);
    // The pass ends afterwards with what it had; the dialog is gone and
    // nothing is shown or thrown.
    pass.complete(preview());
    await tester.pump();
    expect(find.byType(AdoptFolderDialog), findsNothing);
  });

  testWidgets('leaving by the barrier cancels the pass too', (tester) async {
    final p = previewing();
    await open(tester, p);

    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    expect(answer, isFalse);
    expect(p.cancelled, isTrue);
  });

  testWidgets('an existing engram asks nothing', (tester) async {
    await open(tester, previewing());
    pass.complete(preview(isEngram: true));
    await tester.pumpAndSettle();

    expect(find.byType(AdoptFolderDialog), findsNothing);
    expect(find.text('Adopt this folder?'), findsNothing);
    expect(answer, isTrue);
  });

  testWidgets('under Reduce Motion the listing bar does not sweep', (
    tester,
  ) async {
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(disableAnimations: true),
        child: host(previewing()),
      ),
    );
    await tester.tap(find.text('pick'));
    await tester.pumpAndSettle();

    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, 0.0, reason: 'still, not indeterminate');
  });

  testWidgets('an empty folder shows a full bar, not a division by zero', (
    tester,
  ) async {
    await open(tester, previewing());
    progress(0, 0);
    await tester.pump();

    final bar = tester.widget<LinearProgressIndicator>(
      find.byType(LinearProgressIndicator),
    );
    expect(bar.value, 1.0);
    expect(find.text('0 of 0 files'), findsOneWidget);
  });
}
