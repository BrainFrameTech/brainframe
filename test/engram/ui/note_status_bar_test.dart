import 'package:brainframe/engram/crdt/catalog.dart';
import 'package:brainframe/engram/ui/note_status_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/localized_app.dart';

/// The editor's status bar (ceiling step 21): the three counts, the warning
/// at 90 %, and the plain-file line in its slot.
void main() {
  group('NoteCounts', () {
    test('counts bytes, words, and lines', () {
      final counts = NoteCounts.of('# Title\n\nTwo words here.\n');
      expect(counts.bytes, 25);
      expect(counts.words, 5);
      expect(counts.lines, 4, reason: 'three LFs, plus one');
    });

    test('nothing at all is zero of everything', () {
      expect(NoteCounts.of(''), const NoteCounts(bytes: 0, words: 0, lines: 0));
      expect(NoteCounts.of('').hashCode, NoteCounts.of('').hashCode);
      expect(
        NoteCounts.of('').toString(),
        'NoteCounts(0 bytes, 0 words, 0 lines)',
      );
    });

    test('a single line with no terminator is one line', () {
      expect(NoteCounts.of('one').lines, 1);
      expect(NoteCounts.of('one\n').lines, 2, reason: 'the empty line after');
    });

    test('bytes are UTF-8, so CJK weighs three per character', () {
      // Decision 1: the count the limit is stated in. And words are
      // whitespace runs, which for CJK is one — accepted and documented.
      final counts = NoteCounts.of('日本語のテキスト');
      expect(counts.bytes, 24);
      expect(counts.words, 1);
      expect(NoteCounts.of('日本語 の テキスト').words, 3);
    });

    test('words are runs of non-whitespace, whatever the whitespace', () {
      expect(NoteCounts.of('a  b\tc\nd\r\ne').words, 5);
      expect(NoteCounts.of('   ').words, 0);
      expect(NoteCounts.of('a-b c.d').words, 2);
    });

    test('agrees with the size helper the scan uses', () {
      const text = 'mixed: naïve 😀 日本';
      expect(NoteCounts.of(text).bytes, noteSizeInBytes(text));
    });
  });

  Widget host(Widget bar) => localizedApp(
    home: Scaffold(body: Column(children: [const Spacer(), bar])),
  );

  group('NoteStatusBar', () {
    testWidgets('shows the three counts, labeled, with separators', (
      tester,
    ) async {
      final text = List.filled(1500, 'word').join(' ');
      await tester.pumpWidget(
        host(NoteStatusBar(text: text, ceilingBytes: 131072)),
      );

      expect(
        find.text('Bytes: 7,499 · Words: 1,500 · Lines: 1'),
        findsOneWidget,
      );
      expect(
        find.byType(TextButton),
        findsNothing,
        reason: 'far from the limit',
      );
    });

    testWidgets('the warning appears at 90 % and not one byte before', (
      tester,
    ) async {
      const ceiling = 1000; // warning at 900
      await tester.pumpWidget(
        host(
          NoteStatusBar(
            text: 'a' * 899,
            ceilingBytes: ceiling,
            onWarningPressed: () {},
          ),
        ),
      );
      expect(find.text('Near the size limit'), findsNothing);
      expect(find.textContaining('of 1,000'), findsNothing);

      await tester.pumpWidget(
        host(
          NoteStatusBar(
            text: 'a' * 900,
            ceilingBytes: ceiling,
            onWarningPressed: () {},
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Near the size limit'), findsOneWidget);
      expect(
        find.text('Bytes: 900 of 1,000 · Words: 1 · Lines: 1'),
        findsOneWidget,
      );
    });

    testWidgets('at the real capability the warning is at 117,965', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          NoteStatusBar(
            text: 'a' * 117964,
            ceilingBytes: noteSizeCapabilityBytes,
            onWarningPressed: () {},
          ),
        ),
      );
      expect(find.text('Near the size limit'), findsNothing);

      await tester.pumpWidget(
        host(
          NoteStatusBar(
            text: 'a' * 117965,
            ceilingBytes: noteSizeCapabilityBytes,
            onWarningPressed: () {},
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text('Near the size limit'), findsOneWidget);
      expect(find.textContaining('117,965 of 131,072'), findsOneWidget);
    });

    testWidgets('the warning is a labeled button that opens the explanation', (
      tester,
    ) async {
      var pressed = 0;
      await tester.pumpWidget(
        host(
          NoteStatusBar(
            text: 'a' * 950,
            ceilingBytes: 1000,
            onWarningPressed: () => pressed++,
          ),
        ),
      );

      final button = find.text('Near the size limit');
      expect(
        tester.getSemantics(button).label,
        'Near the size limit: 950 of 1,000 bytes. Opens an explanation.',
      );
      await tester.tap(button);
      expect(pressed, 1);
    });

    testWidgets('a plain file gets the regime line and never a warning', (
      tester,
    ) async {
      await tester.pumpWidget(
        host(
          NoteStatusBar(
            text: 'a' * 5000,
            ceilingBytes: 1000,
            plainFile: true,
            onWarningPressed: () {},
          ),
        ),
      );

      expect(
        find.text('Plain file — edits are saved whole; no history or merging.'),
        findsOneWidget,
      );
      expect(find.text('Near the size limit'), findsNothing);
      expect(
        find.text('Bytes: 5,000 · Words: 1 · Lines: 1'),
        findsOneWidget,
        reason: 'no limit shown: a plain file has none',
      );
    });

    testWidgets('a burst of edits is one count, after the interval', (
      tester,
    ) async {
      // The bar coalesces: the first change arms a timer, later ones ride
      // on it, and the count that fires sees the latest text.
      Widget at(String text) => host(
        NoteStatusBar(
          text: text,
          ceilingBytes: 131072,
          repaintInterval: const Duration(milliseconds: 100),
        ),
      );
      await tester.pumpWidget(at('one'));
      expect(find.textContaining('Words: 1 ·'), findsOneWidget);

      await tester.pumpWidget(at('one two'));
      await tester.pumpWidget(at('one two three'));
      await tester.pump(const Duration(milliseconds: 50));
      expect(
        find.textContaining('Words: 1 ·'),
        findsOneWidget,
        reason: 'not yet',
      );

      await tester.pump(const Duration(milliseconds: 60));
      expect(find.textContaining('Words: 3 ·'), findsOneWidget);
    });

    testWidgets('the same text again counts nothing', (tester) async {
      await tester.pumpWidget(
        host(const NoteStatusBar(text: 'same', ceilingBytes: 131072)),
      );
      await tester.pumpWidget(
        host(const NoteStatusBar(text: 'same', ceilingBytes: 131072)),
      );
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.textContaining('Bytes: 4 ·'), findsOneWidget);
    });
  });
}
