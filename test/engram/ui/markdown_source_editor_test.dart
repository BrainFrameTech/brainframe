import 'package:brainframe/engram/ui/markdown_source_editor.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/localized_app.dart';

Widget _host(Widget child) =>
    localizedApp(home: Scaffold(body: SizedBox(height: 400, child: child)));

/// Presses and holds over the editor's first word with [kind] — the way a
/// desktop user asks for the context menu without a right button.
Future<void> _pressAndHold(WidgetTester tester, PointerDeviceKind kind) async {
  // Over the text itself, not the empty space past it: a hold on blank canvas
  // selects no word and the menu offers only Select all.
  final gesture = await tester.startGesture(
    tester.getTopLeft(find.byType(EditableText)) + const Offset(12, 8),
    kind: kind,
  );
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 100));
  await gesture.up();
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows the initial text', (tester) async {
    await tester
        .pumpWidget(_host(const MarkdownSourceEditor(initialText: '# Hello')));
    expect(find.text('# Hello'), findsOneWidget);
  });

  testWidgets('propagates edits through onChanged', (tester) async {
    final changes = <String>[];
    await tester.pumpWidget(_host(
      MarkdownSourceEditor(initialText: '', onChanged: changes.add),
    ));

    await tester.enterText(find.byType(TextField), '# Edited');

    expect(changes, ['# Edited']);
  });

  testWidgets('exposes an explicit, localized Markdown-editor label',
      (tester) async {
    await tester.pumpWidget(_host(const MarkdownSourceEditor(initialText: '')));

    // The label is sourced from AppLocalizations (English here), never a raw
    // string literal.
    expect(find.bySemanticsLabel('Markdown editor'), findsOneWidget);
  });

  testWidgets('adopts new initialText when a different file loads',
      (tester) async {
    await tester.pumpWidget(_host(
      const MarkdownSourceEditor(initialText: 'first', key: ValueKey('slot')),
    ));
    expect(find.text('first'), findsOneWidget);

    // Same widget slot (same key) — exercises didUpdateWidget, not a rebuild.
    await tester.pumpWidget(_host(
      const MarkdownSourceEditor(initialText: 'second', key: ValueKey('slot')),
    ));

    expect(find.text('second'), findsOneWidget);
    expect(find.text('first'), findsNothing);
  });

  testWidgets('keeps an in-progress edit that already matches the new text',
      (tester) async {
    final changes = <String>[];
    await tester.pumpWidget(_host(
      MarkdownSourceEditor(
        initialText: 'start',
        onChanged: changes.add,
        key: const ValueKey('slot'),
      ),
    ));
    await tester.enterText(find.byType(TextField), 'typed');

    // A rebuild whose initialText matches the buffer must not reset the caret
    // or content.
    await tester.pumpWidget(_host(
      MarkdownSourceEditor(
        initialText: 'typed',
        onChanged: changes.add,
        key: const ValueKey('slot'),
      ),
    ));

    expect(find.text('typed'), findsOneWidget);
  });

  testWidgets('disables the animated cursor under Reduce Motion',
      (tester) async {
    await tester.pumpWidget(localizedApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: const Scaffold(
            body: SizedBox(
              height: 400,
              child: MarkdownSourceEditor(initialText: ''),
            ),
          ),
        ),
      ),
    ));

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.cursorOpacityAnimates, isFalse);
  });

  testWidgets('animates the cursor when Reduce Motion is off', (tester) async {
    await tester.pumpWidget(_host(const MarkdownSourceEditor(initialText: '')));

    final field = tester.widget<TextField>(find.byType(TextField));
    expect(field.cursorOpacityAnimates, isTrue);
  });

  group('press-and-hold opens the clipboard menu', () {
    setUp(() {
      // Paste only appears when the clipboard holds something.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (call) async {
            switch (call.method) {
              case 'Clipboard.getData':
                return <String, Object?>{'text': 'clip'};
              case 'Clipboard.hasStrings':
                return <String, Object?>{'value': true};
            }
            return null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null);
    });

    testWidgets('with a mouse — the case Flutter does not cover', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(const MarkdownSourceEditor(initialText: 'hello world')),
      );

      await _pressAndHold(tester, PointerDeviceKind.mouse);

      expect(find.text('Cut'), findsOneWidget);
      expect(find.text('Copy'), findsOneWidget);
      expect(find.text('Paste'), findsOneWidget);
      expect(find.text('Select all'), findsOneWidget);
    });

    testWidgets('with a stylus, which the framework leaves out too', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(const MarkdownSourceEditor(initialText: 'hello world')),
      );

      await _pressAndHold(tester, PointerDeviceKind.stylus);

      expect(find.text('Copy'), findsOneWidget);
    });

    testWidgets('on a field that already has focus', (tester) async {
      await tester.pumpWidget(
        _host(const MarkdownSourceEditor(initialText: 'hello world')),
      );
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();

      await _pressAndHold(tester, PointerDeviceKind.mouse);

      expect(find.text('Copy'), findsOneWidget);
    });

    testWidgets('it selects the word under the pointer, so Copy has something '
        'to take', (tester) async {
      await tester.pumpWidget(
        _host(const MarkdownSourceEditor(initialText: 'hello world')),
      );

      await _pressAndHold(tester, PointerDeviceKind.mouse);

      final editable = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      final selection = editable.textEditingValue.selection;
      expect(selection.isCollapsed, isFalse);
      expect(
        editable.textEditingValue.text.substring(
          selection.start,
          selection.end,
        ),
        isNotEmpty,
      );
    });

    testWidgets('a touch long-press is left to the framework, so a finger '
        'never opens two menus', (tester) async {
      await tester.pumpWidget(
        _host(const MarkdownSourceEditor(initialText: 'hello world')),
      );

      await _pressAndHold(tester, PointerDeviceKind.touch);

      // Flutter's own gesture handled it — exactly one menu, not two.
      expect(find.text('Copy'), findsOneWidget);
    });

    testWidgets('a quick click still just places the caret', (tester) async {
      await tester.pumpWidget(
        _host(const MarkdownSourceEditor(initialText: 'hello world')),
      );

      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();

      expect(find.text('Copy'), findsNothing);
    });

    testWidgets('it works when the host owns the focus node', (tester) async {
      final focusNode = FocusNode();
      addTearDown(focusNode.dispose);
      await tester.pumpWidget(
        _host(
          MarkdownSourceEditor(
            initialText: 'hello world',
            focusNode: focusNode,
          ),
        ),
      );

      await _pressAndHold(tester, PointerDeviceKind.mouse);

      expect(focusNode.hasFocus, isTrue);
      expect(find.text('Copy'), findsOneWidget);
    });
  });
}
