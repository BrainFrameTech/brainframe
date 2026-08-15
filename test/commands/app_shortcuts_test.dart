import 'package:brainframe/commands/app_commands.dart';
import 'package:brainframe/commands/app_shortcuts.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('the accelerator table', () {
    test('Linux and Windows carry the accelerators on Control', () {
      for (final platform in [TargetPlatform.linux, TargetPlatform.windows]) {
        final shortcuts = AppShortcuts.forPlatform(platform);
        expect(
          shortcuts.newNote,
          const SingleActivator(LogicalKeyboardKey.keyN, control: true),
          reason: '$platform',
        );
        expect(
          shortcuts.newFolder,
          const SingleActivator(
            LogicalKeyboardKey.keyN,
            control: true,
            shift: true,
          ),
        );
        expect(
          shortcuts.quit,
          const SingleActivator(LogicalKeyboardKey.keyQ, control: true),
        );
        expect(
          shortcuts.copy,
          const SingleActivator(LogicalKeyboardKey.keyC, control: true),
        );
        expect(shortcuts.bindInApp, isTrue);
      }
    });

    test('macOS carries them on Command', () {
      final shortcuts = AppShortcuts.forPlatform(TargetPlatform.macOS);
      expect(
        shortcuts.newNote,
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true),
      );
      expect(
        shortcuts.newFolder,
        const SingleActivator(
          LogicalKeyboardKey.keyN,
          meta: true,
          shift: true,
        ),
      );
      expect(
        shortcuts.quit,
        const SingleActivator(LogicalKeyboardKey.keyQ, meta: true),
      );
      expect(
        shortcuts.preferences,
        const SingleActivator(LogicalKeyboardKey.comma, meta: true),
      );
    });

    test('macOS binds nothing in-app — its system menu bar owns the keys', () {
      final shortcuts = AppShortcuts.forPlatform(TargetPlatform.macOS);
      expect(shortcuts.bindInApp, isFalse);
      expect(shortcuts.bindings, isEmpty);
    });

    test('mobile gets no menu bar and no accelerators', () {
      for (final platform in [
        TargetPlatform.android,
        TargetPlatform.iOS,
        TargetPlatform.fuchsia,
      ]) {
        final shortcuts = AppShortcuts.forPlatform(platform);
        expect(shortcuts.newNote, isNull, reason: '$platform');
        expect(shortcuts.bindings, isEmpty, reason: '$platform');
      }
    });

    test('the clipboard keys are displayed but never bound — the framework '
        'already binds them inside a focused field', () {
      final shortcuts = AppShortcuts.forPlatform(TargetPlatform.linux);
      expect(shortcuts.cut, isNotNull);
      expect(shortcuts.copy, isNotNull);
      expect(shortcuts.paste, isNotNull);
      expect(shortcuts.bindings.keys, <ShortcutActivator>{
        const SingleActivator(LogicalKeyboardKey.keyN, control: true),
        const SingleActivator(
          LogicalKeyboardKey.keyN,
          control: true,
          shift: true,
        ),
        const SingleActivator(LogicalKeyboardKey.keyQ, control: true),
        const SingleActivator(LogicalKeyboardKey.comma, control: true),
      });
    });
  });

  group('the bound hotkeys', () {
    Widget harness(AppCommands commands, {TargetPlatform? platform}) =>
        AppCommandsScope(
          commands: commands,
          child: MaterialApp(
            theme: ThemeData(platform: platform ?? TargetPlatform.linux),
            home: const AppCommandShortcuts(
              child: Focus(autofocus: true, child: SizedBox.expand()),
            ),
          ),
        );

    testWidgets('Ctrl+N creates a note and Ctrl+Shift+N a folder', (
      tester,
    ) async {
      final commands = AppCommands();
      addTearDown(commands.dispose);
      var notes = 0;
      var folders = 0;
      commands.publish(newNote: () => notes++, newFolder: () => folders++);
      await tester.pumpWidget(harness(commands));
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(notes, 1);
      expect(folders, 0);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(notes, 1, reason: 'Shift makes it the folder command');
      expect(folders, 1);
    });

    testWidgets('Ctrl+, opens preferences', (tester) async {
      final commands = AppCommands();
      addTearDown(commands.dispose);
      var opened = 0;
      commands.publish(preferences: () => opened++);
      await tester.pumpWidget(harness(commands));
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.comma);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

      expect(opened, 1);
    });

    testWidgets('an unavailable command leaves its key unhandled rather than '
        'swallowing it', (tester) async {
      final commands = AppCommands();
      addTearDown(commands.dispose);
      // Nothing published: the browser has not mounted, or the engram is
      // read-only.
      final unhandled = <LogicalKeyboardKey>[];
      await tester.pumpWidget(
        AppCommandsScope(
          commands: commands,
          child: MaterialApp(
            theme: ThemeData(platform: TargetPlatform.linux),
            home: Focus(
              autofocus: true,
              onKeyEvent: (node, event) {
                // An ancestor of the shortcuts: it only sees keys the app-level
                // action did not handle.
                if (event is KeyDownEvent) unhandled.add(event.logicalKey);
                return KeyEventResult.ignored;
              },
              child: AppCommandShortcuts(
                child: const Focus(autofocus: true, child: SizedBox.expand()),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);

      expect(unhandled, contains(LogicalKeyboardKey.keyN));
    });

    testWidgets('macOS binds nothing in-app', (tester) async {
      final commands = AppCommands();
      addTearDown(commands.dispose);
      var notes = 0;
      commands.publish(newNote: () => notes++);
      await tester.pumpWidget(
        harness(commands, platform: TargetPlatform.macOS),
      );
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyN);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);

      expect(
        notes,
        0,
        reason: 'the system menu bar invokes it, so binding it here too '
            'would fire the command twice',
      );
    });
  });
}
