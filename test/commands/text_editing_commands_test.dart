import 'package:brainframe/commands/text_editing_commands.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget app(Widget body) =>
      MaterialApp(home: Scaffold(body: Center(child: body)));

  testWidgets('nothing focused means nothing to act on', (tester) async {
    final commands = TextEditingCommands();
    addTearDown(commands.dispose);
    await tester.pumpWidget(app(const SizedBox()));
    await tester.pump();

    expect(commands.target, isNull);
    expect(commands.canCut, isFalse);
    expect(commands.canCopy, isFalse);
    expect(commands.canPaste, isFalse);
  });

  testWidgets('a focused field with a selection can be cut, copied and pasted '
      'into', (tester) async {
    final controller = TextEditingController(text: 'hello world');
    addTearDown(controller.dispose);
    final commands = TextEditingCommands();
    addTearDown(commands.dispose);
    await tester.pumpWidget(app(TextField(controller: controller)));

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
    await tester.pumpAndSettle();

    expect(commands.target, isNotNull);
    expect(commands.canCopy, isTrue);
    expect(commands.canCut, isTrue);
    expect(commands.canPaste, isTrue);
  });

  testWidgets('a read-only field can be copied from but not cut or pasted '
      'into', (tester) async {
    final controller = TextEditingController(text: 'hello world');
    addTearDown(controller.dispose);
    final commands = TextEditingCommands();
    addTearDown(commands.dispose);
    await tester.pumpWidget(
      app(TextField(controller: controller, readOnly: true)),
    );

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
    await tester.pumpAndSettle();

    expect(commands.canCopy, isTrue);
    expect(commands.canCut, isFalse);
    expect(commands.canPaste, isFalse);
  });

  testWidgets('an obscured field never offers its contents', (tester) async {
    final controller = TextEditingController(text: 'hunter2');
    addTearDown(controller.dispose);
    final commands = TextEditingCommands();
    addTearDown(commands.dispose);
    await tester.pumpWidget(
      app(TextField(controller: controller, obscureText: true)),
    );

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 7);
    await tester.pumpAndSettle();

    expect(commands.canCopy, isFalse);
    expect(commands.canCut, isFalse);
  });

  testWidgets('the field survives an open menu taking focus, and is dropped '
      'once the menu closes without it', (tester) async {
    final controller = TextEditingController(text: 'hello world');
    final elsewhere = FocusNode();
    addTearDown(controller.dispose);
    addTearDown(elsewhere.dispose);
    final commands = TextEditingCommands();
    addTearDown(commands.dispose);
    await tester.pumpWidget(
      app(
        Column(
          children: [
            TextField(controller: controller),
            Focus(focusNode: elsewhere, child: const SizedBox.square(dimension: 20)),
          ],
        ),
      ),
    );
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    controller.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
    await tester.pumpAndSettle();

    // The menu opens and takes the focus with it.
    commands.menuOpened();
    elsewhere.requestFocus();
    await tester.pumpAndSettle();
    expect(
      commands.canCopy,
      isTrue,
      reason: 'the menu holding focus is not the user leaving the field',
    );

    // The menu closes; focus is now genuinely elsewhere.
    commands.menuClosed();
    await tester.pumpAndSettle();
    expect(commands.canCopy, isFalse);
    expect(commands.target, isNull);
  });

  testWidgets('focus moving between fields follows the new one', (
    tester,
  ) async {
    final first = TextEditingController(text: 'first');
    final second = TextEditingController(text: 'second');
    addTearDown(first.dispose);
    addTearDown(second.dispose);
    final commands = TextEditingCommands();
    addTearDown(commands.dispose);
    await tester.pumpWidget(
      app(
        Column(
          children: [
            TextField(controller: first),
            TextField(controller: second),
          ],
        ),
      ),
    );

    await tester.tap(find.byType(TextField).last);
    await tester.pumpAndSettle();
    second.selection = const TextSelection(baseOffset: 0, extentOffset: 6);
    await tester.pumpAndSettle();

    expect(commands.target!.textEditingValue.text, 'second');
  });

  testWidgets('the commands are inert when they are not available', (
    tester,
  ) async {
    final controller = TextEditingController(text: 'hello world');
    addTearDown(controller.dispose);
    final commands = TextEditingCommands();
    addTearDown(commands.dispose);
    await tester.pumpWidget(app(TextField(controller: controller)));
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    controller.selection = const TextSelection.collapsed(offset: 2);
    await tester.pumpAndSettle();

    // Nothing selected: cut and copy must do nothing rather than clear the
    // clipboard or mangle the text.
    commands.cut();
    commands.copy();
    await tester.pumpAndSettle();

    expect(controller.text, 'hello world');
  });

  testWidgets('disposing stops it tracking focus', (tester) async {
    final controller = TextEditingController(text: 'hello');
    addTearDown(controller.dispose);
    final commands = TextEditingCommands();
    await tester.pumpWidget(app(TextField(controller: controller)));

    commands.dispose();

    // A focus change after disposal must not reach a dead notifier.
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
  });
}
