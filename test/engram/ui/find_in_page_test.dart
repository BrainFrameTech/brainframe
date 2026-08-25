import 'package:brainframe/engram/ui/find_in_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/localized_app.dart';

/// Records what the bar asked its host to do.
class _Log {
  final List<String> events = [];
}

Widget _host(
  _Log log, {
  required TextEditingController controller,
  required FocusNode focusNode,
  int matchCount = 0,
  int activeMatch = -1,
}) => localizedApp(
  home: Scaffold(
    body: FindInPageBar(
      controller: controller,
      focusNode: focusNode,
      matchCount: matchCount,
      activeMatch: activeMatch,
      onChanged: (q) => log.events.add('changed:$q'),
      onNext: () => log.events.add('next'),
      onPrevious: () => log.events.add('previous'),
      onClose: () => log.events.add('close'),
    ),
  ),
);

void main() {
  group('findMatches', () {
    test('finds every occurrence, in document order', () {
      expect(findMatches('one two one', 'one'), [
        const TextRange(start: 0, end: 3),
        const TextRange(start: 8, end: 11),
      ]);
    });

    test('is case-insensitive by default and case-sensitive on request', () {
      expect(findMatches('Note note NOTE', 'note').length, 3);
      expect(findMatches('Note note NOTE', 'note', caseSensitive: true), [
        const TextRange(start: 5, end: 9),
      ]);
    });

    test('never overlaps: the scan resumes past the match it took', () {
      expect(findMatches('aaaa', 'aa'), [
        const TextRange(start: 0, end: 2),
        const TextRange(start: 2, end: 4),
      ]);
    });

    test('an empty query or an empty document matches nothing', () {
      expect(findMatches('some text', ''), isEmpty);
      expect(findMatches('', 'text'), isEmpty);
    });

    test(
      'matches multi-line and punctuation runs literally, not as a regexp',
      () {
        expect(findMatches('a.b\nc.d', '.'), [
          const TextRange(start: 1, end: 2),
          const TextRange(start: 5, end: 6),
        ]);
        expect(findMatches('line\nline', 'e\nl'), [
          const TextRange(start: 3, end: 6),
        ]);
      },
    );

    test('case folding never slews the offsets it reports', () {
      // The offsets come from the folded text but are used against the original,
      // so a fold that moved a character would highlight the wrong one.
      const text = 'Éé ÜBER straße';
      for (final query in ['é', 'ü', 'STRASSE', 'ß']) {
        for (final match in findMatches(text, query)) {
          expect(
            text.substring(match.start, match.end).toLowerCase(),
            query.toLowerCase(),
            reason: 'match of "$query" must cover exactly that text',
          );
        }
      }
      expect(findMatches(text, 'é').length, 2);
    });
  });

  group('the find bar', () {
    testWidgets('counts the matches, and says so when there are none', (
      tester,
    ) async {
      final log = _Log();
      final controller = TextEditingController(text: 'note');
      addTearDown(controller.dispose);
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(
        _host(
          log,
          controller: controller,
          focusNode: focusNode,
          matchCount: 12,
          activeMatch: 2,
        ),
      );
      expect(find.text('3 of 12'), findsOneWidget);

      await tester.pumpWidget(
        _host(log, controller: controller, focusNode: focusNode),
      );
      expect(find.text('No results'), findsOneWidget);
    });

    testWidgets('an empty query has not failed to find anything yet', (
      tester,
    ) async {
      final log = _Log();
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(
        _host(log, controller: controller, focusNode: focusNode),
      );

      expect(find.text('No results'), findsNothing);
      expect(find.text('0 of 0'), findsNothing);
    });

    testWidgets('the steppers are disabled without matches and call back with '
        'them', (tester) async {
      final log = _Log();
      final controller = TextEditingController(text: 'note');
      addTearDown(controller.dispose);
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(
        _host(log, controller: controller, focusNode: focusNode),
      );
      IconButton button(IconData icon) =>
          tester.widget<IconButton>(find.widgetWithIcon(IconButton, icon));

      expect(button(Icons.keyboard_arrow_down).onPressed, isNull);
      expect(button(Icons.keyboard_arrow_up).onPressed, isNull);

      await tester.pumpWidget(
        _host(
          log,
          controller: controller,
          focusNode: focusNode,
          matchCount: 2,
          activeMatch: 0,
        ),
      );
      await tester.tap(find.byTooltip('Next match'));
      await tester.tap(find.byTooltip('Previous match'));
      await tester.tap(find.byTooltip('Close find'));

      expect(log.events, ['next', 'previous', 'close']);
    });

    testWidgets('Enter steps forward, Shift+Enter back, Escape closes', (
      tester,
    ) async {
      final log = _Log();
      final controller = TextEditingController(text: 'note');
      addTearDown(controller.dispose);
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(
        _host(
          log,
          controller: controller,
          focusNode: focusNode,
          matchCount: 2,
          activeMatch: 0,
        ),
      );
      await tester.tap(find.byType(TextField));
      await tester.pump();

      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(log.events, ['next', 'previous', 'close']);
    });

    testWidgets('typing reports the query to its host', (tester) async {
      final log = _Log();
      final controller = TextEditingController();
      addTearDown(controller.dispose);
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);

      await tester.pumpWidget(
        _host(log, controller: controller, focusNode: focusNode),
      );
      await tester.enterText(find.byType(TextField), 'engram');

      expect(log.events, ['changed:engram']);
    });
  });
}
