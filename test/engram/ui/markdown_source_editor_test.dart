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

  group('find highlights', () {
    /// The spans the field actually paints, flattened to (text, hasBackground)
    /// pairs — what a reader sees, rather than how it is built.
    List<(String, bool)> paintedSpans(WidgetTester tester) {
      final editable = tester.widget<EditableText>(find.byType(EditableText));
      final span = editable.controller.buildTextSpan(
        context: tester.element(find.byType(EditableText)),
        withComposing: false,
      );
      final children = span.children;
      if (children == null) return [(span.text ?? '', false)];
      return [
        for (final child in children.cast<TextSpan>())
          (child.text ?? '', child.style?.backgroundColor != null),
      ];
    }

    testWidgets('paints every match, and only the active one differently', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const MarkdownSourceEditor(
            initialText: 'one two one',
            matches: [TextRange(start: 0, end: 3), TextRange(start: 8, end: 11)],
            activeMatch: 1,
          ),
        ),
      );

      expect(paintedSpans(tester), [
        ('one', true),
        (' two ', false),
        ('one', true),
      ]);

      final editable = tester.widget<EditableText>(find.byType(EditableText));
      final span = editable.controller.buildTextSpan(
        context: tester.element(find.byType(EditableText)),
        withComposing: false,
      );
      final spans = span.children!.cast<TextSpan>();
      expect(
        spans[0].style?.backgroundColor,
        isNot(spans[2].style?.backgroundColor),
        reason: 'the active match must stand out from the rest',
      );
    });

    testWidgets('no matches leaves the text as one plain span', (tester) async {
      await tester.pumpWidget(
        _host(const MarkdownSourceEditor(initialText: 'one two one')),
      );

      expect(paintedSpans(tester), [('one two one', false)]);
    });

    testWidgets('a stale range is clamped rather than thrown', (tester) async {
      await tester.pumpWidget(
        _host(
          const MarkdownSourceEditor(
            initialText: 'short',
            matches: [TextRange(start: 3, end: 99)],
            activeMatch: 0,
            key: ValueKey('slot'),
          ),
        ),
      );

      expect(paintedSpans(tester), [('sho', false), ('rt', true)]);
      expect(tester.takeException(), isNull);
    });

    testWidgets('an out-of-range active index highlights none of them', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const MarkdownSourceEditor(
            initialText: 'one two',
            matches: [TextRange(start: 0, end: 3)],
            activeMatch: 7,
          ),
        ),
      );

      expect(paintedSpans(tester), [('one', true), (' two', false)]);
      expect(tester.takeException(), isNull);
    });
  });

  group('the caret handle', () {
    testWidgets('selectRange selects the range and focuses the field', (
      tester,
    ) async {
      final controller = SourceEditorController();
      await tester.pumpWidget(
        _host(
          MarkdownSourceEditor(
            initialText: 'one two one',
            controller: controller,
          ),
        ),
      );
      expect(controller.isAttached, isTrue);

      controller.selectRange(const TextRange(start: 8, end: 11));
      await tester.pumpAndSettle();

      final editable = tester.widget<EditableText>(find.byType(EditableText));
      expect(
        editable.controller.selection,
        const TextSelection(baseOffset: 8, extentOffset: 11),
      );
      expect(editable.focusNode.hasFocus, isTrue);
    });

    testWidgets('a range past the end of the text is clamped, not thrown', (
      tester,
    ) async {
      final controller = SourceEditorController();
      await tester.pumpWidget(
        _host(MarkdownSourceEditor(initialText: 'abc', controller: controller)),
      );

      controller.selectRange(const TextRange(start: 2, end: 99));
      await tester.pumpAndSettle();

      final editable = tester.widget<EditableText>(find.byType(EditableText));
      expect(
        editable.controller.selection,
        const TextSelection(baseOffset: 2, extentOffset: 3),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('it detaches with the editor, and is a no-op after', (
      tester,
    ) async {
      final controller = SourceEditorController();
      await tester.pumpWidget(
        _host(MarkdownSourceEditor(initialText: 'abc', controller: controller)),
      );
      await tester.pumpWidget(_host(const SizedBox()));

      expect(controller.isAttached, isFalse);
      controller.selectRange(const TextRange(start: 0, end: 1));
      expect(tester.takeException(), isNull);
    });

    testWidgets('swapping the handle moves the attachment', (tester) async {
      final first = SourceEditorController();
      final second = SourceEditorController();
      await tester.pumpWidget(
        _host(
          MarkdownSourceEditor(
            initialText: 'abc',
            controller: first,
            key: const ValueKey('slot'),
          ),
        ),
      );
      await tester.pumpWidget(
        _host(
          MarkdownSourceEditor(
            initialText: 'abc',
            controller: second,
            key: const ValueKey('slot'),
          ),
        ),
      );

      expect(first.isAttached, isFalse);
      expect(second.isAttached, isTrue);
    });
  });
}
