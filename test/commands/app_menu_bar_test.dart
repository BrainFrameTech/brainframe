import 'package:brainframe/commands/app_commands.dart';
import 'package:brainframe/commands/app_menu_bar.dart';
import 'package:brainframe/commands/app_shortcuts.dart';
import 'package:brainframe/l10n/gen/app_localizations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Map<String, Object?> clipboard;
  late List<String> windowCalls;

  setUp(() {
    clipboard = <String, Object?>{};
    windowCalls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          switch (call.method) {
            case 'Clipboard.setData':
              clipboard['text'] = (call.arguments as Map)['text'];
              return null;
            case 'Clipboard.getData':
              return <String, Object?>{'text': clipboard['text']};
            case 'Clipboard.hasStrings':
              return <String, Object?>{'value': clipboard['text'] != null};
          }
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), (
          call,
        ) async {
          windowCalls.add(call.method);
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(SystemChannels.platform, null)
      ..setMockMethodCallHandler(const MethodChannel('window_manager'), null);
  });

  Widget harness(
    AppCommands commands, {
    required TargetPlatform platform,
    Widget? home,
  }) => AppCommandsScope(
    commands: commands,
    child: MaterialApp(
      theme: ThemeData(platform: platform),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) =>
          AppCommandShortcuts(child: AppMenuBar(child: child!)),
      home: home ?? const Scaffold(body: SizedBox.expand()),
    ),
  );

  AppCommands publishedCommands({
    VoidCallback? newNote,
    VoidCallback? newFolder,
    VoidCallback? preferences,
    VoidCallback? help,
    VoidCallback? about,
  }) {
    final commands = AppCommands()
      ..publish(
        newNote: newNote,
        newFolder: newFolder,
        preferences: preferences,
        help: help,
        about: about,
      );
    addTearDown(commands.dispose);
    return commands;
  }

  MenuItemButton itemNamed(WidgetTester tester, String label) =>
      tester.widget<MenuItemButton>(
        find.widgetWithText(MenuItemButton, label).first,
      );

  group('which menu bar each platform gets', () {
    testWidgets('Linux and Windows get the in-app strip', (tester) async {
      for (final platform in [TargetPlatform.linux, TargetPlatform.windows]) {
        await tester.pumpWidget(
          harness(publishedCommands(newNote: () {}), platform: platform),
        );
        await tester.pumpAndSettle();

        expect(find.byType(MenuBar), findsOneWidget, reason: '$platform');
        expect(find.byType(PlatformMenuBar), findsNothing);
        expect(find.text('File'), findsOneWidget);
        expect(find.text('Edit'), findsOneWidget);
        expect(find.text('Help'), findsOneWidget);
      }
    });

    testWidgets('macOS gets the system menu bar, not an in-app strip', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(
          publishedCommands(newNote: () {}),
          platform: TargetPlatform.macOS,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(PlatformMenuBar), findsOneWidget);
      expect(find.byType(MenuBar), findsNothing);
    });

    testWidgets('phones and the e-ink panel get no menu bar at all', (
      tester,
    ) async {
      for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
        await tester.pumpWidget(
          harness(publishedCommands(newNote: () {}), platform: platform),
        );
        await tester.pumpAndSettle();

        expect(find.byType(MenuBar), findsNothing, reason: '$platform');
        expect(find.byType(PlatformMenuBar), findsNothing);
      }
    });
  });

  group('the File menu', () {
    testWidgets('New note and New folder invoke the published commands', (
      tester,
    ) async {
      var notes = 0;
      var folders = 0;
      await tester.pumpWidget(
        harness(
          publishedCommands(
            newNote: () => notes++,
            newFolder: () => folders++,
          ),
          platform: TargetPlatform.linux,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('File'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New note'));
      await tester.pumpAndSettle();
      expect(notes, 1);

      await tester.tap(find.text('File'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New folder'));
      await tester.pumpAndSettle();
      expect(folders, 1);
    });

    testWidgets('they grey out for a read-only engram, which publishes '
        'neither', (tester) async {
      await tester.pumpWidget(
        harness(publishedCommands(), platform: TargetPlatform.linux),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('File'));
      await tester.pumpAndSettle();

      expect(itemNamed(tester, 'New note').onPressed, isNull);
      expect(itemNamed(tester, 'New folder').onPressed, isNull);
      // Quit is never withheld — it is the app's, not the engram's.
      expect(itemNamed(tester, 'Quit').onPressed, isNotNull);
    });

    testWidgets('Quit closes the window, which is what flushes and saves', (
      tester,
    ) async {
      // requestAppQuit only acts where there is an OS window, which it decides
      // from the ambient platform. Reset inside the body: the framework checks
      // for stray debug overrides before tearDowns run.
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      try {
        await tester.pumpWidget(
          harness(publishedCommands(), platform: TargetPlatform.linux),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('File'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Quit'));
        await tester.pumpAndSettle();

        expect(windowCalls, contains('close'));
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('the items display their accelerators', (tester) async {
      await tester.pumpWidget(
        harness(
          publishedCommands(newNote: () {}),
          platform: TargetPlatform.linux,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('File'));
      await tester.pumpAndSettle();

      expect(
        itemNamed(tester, 'New note').shortcut,
        AppShortcuts.forPlatform(TargetPlatform.linux).newNote,
      );
      expect(
        itemNamed(tester, 'Quit').shortcut,
        AppShortcuts.forPlatform(TargetPlatform.linux).quit,
      );
    });
  });

  group('the Edit menu', () {
    Widget withField(AppCommands commands, TextEditingController controller) =>
        harness(
          commands,
          platform: TargetPlatform.linux,
          home: Scaffold(body: TextField(controller: controller)),
        );

    testWidgets('the clipboard items grey out when no field has focus', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(publishedCommands(), platform: TargetPlatform.linux),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();

      expect(itemNamed(tester, 'Cut').onPressed, isNull);
      expect(itemNamed(tester, 'Copy').onPressed, isNull);
      expect(itemNamed(tester, 'Paste').onPressed, isNull);
    });

    testWidgets('Copy copies the focused field\'s selection', (tester) async {
      final controller = TextEditingController(text: 'hello world');
      addTearDown(controller.dispose);
      await tester.pumpWidget(withField(publishedCommands(), controller));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      controller.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      expect(
        itemNamed(tester, 'Copy').onPressed,
        isNotNull,
        reason: 'opening the menu must not lose the field it applies to',
      );
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();

      expect(clipboard['text'], 'hello');
      expect(controller.text, 'hello world', reason: 'copy leaves the text');
    });

    testWidgets('Copy survives opening the menu with a mouse', (tester) async {
      // The pointer *kind* is the whole point of this test. A field unfocuses
      // itself when a tap lands outside it, and on desktop that only happens
      // for a mouse — so a touch-driven tap (what `tester.tap` sends by
      // default) never reproduces what a real click does to focus. This is the
      // path a human takes, and it was broken while every touch-driven test
      // above passed.
      final controller = TextEditingController(text: 'hello world');
      addTearDown(controller.dispose);
      await tester.pumpWidget(withField(publishedCommands(), controller));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(TextField), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      controller.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Edit'), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(
        itemNamed(tester, 'Copy').onPressed,
        isNotNull,
        reason: 'clicking the menu must not lose the field it applies to',
      );

      await tester.tap(find.text('Copy'), kind: PointerDeviceKind.mouse);
      await tester.pumpAndSettle();
      expect(clipboard['text'], 'hello');
    });

    testWidgets('Cut removes the selection and Paste puts it back', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'hello world');
      addTearDown(controller.dispose);
      await tester.pumpWidget(withField(publishedCommands(), controller));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      controller.selection = const TextSelection(baseOffset: 0, extentOffset: 6);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cut'));
      await tester.pumpAndSettle();
      expect(controller.text, 'world');
      expect(clipboard['text'], 'hello ');

      controller.selection = const TextSelection.collapsed(offset: 5);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Paste'));
      await tester.pumpAndSettle();

      expect(controller.text, 'worldhello ');
    });

    testWidgets('Copy stays disabled while the selection is empty', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'hello world');
      addTearDown(controller.dispose);
      await tester.pumpWidget(withField(publishedCommands(), controller));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      controller.selection = const TextSelection.collapsed(offset: 3);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();

      expect(itemNamed(tester, 'Cut').onPressed, isNull);
      expect(itemNamed(tester, 'Copy').onPressed, isNull);
      expect(
        itemNamed(tester, 'Paste').onPressed,
        isNotNull,
        reason: 'a caret with nothing selected can still be pasted into',
      );
    });

    testWidgets('leaving the field for something else greys them again', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'hello world');
      final elsewhere = FocusNode();
      addTearDown(controller.dispose);
      addTearDown(elsewhere.dispose);
      await tester.pumpWidget(
        harness(
          publishedCommands(),
          platform: TargetPlatform.linux,
          home: Scaffold(
            body: Column(
              children: [
                TextField(controller: controller),
                Focus(
                  focusNode: elsewhere,
                  child: const SizedBox(height: 40, width: 40),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      controller.selection = const TextSelection(baseOffset: 0, extentOffset: 5);
      await tester.pumpAndSettle();

      // A file-tree row, say, taking focus.
      elsewhere.requestFocus();
      await tester.pumpAndSettle();

      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();

      expect(itemNamed(tester, 'Copy').onPressed, isNull);
    });

    testWidgets('Preferences opens Settings', (tester) async {
      var opened = 0;
      await tester.pumpWidget(
        harness(
          publishedCommands(preferences: () => opened++),
          platform: TargetPlatform.linux,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Preferences'));
      await tester.pumpAndSettle();

      expect(opened, 1);
    });
  });

  group('the Help menu', () {
    testWidgets('Help and About invoke their commands', (tester) async {
      var help = 0;
      var about = 0;
      await tester.pumpWidget(
        harness(
          publishedCommands(help: () => help++, about: () => about++),
          platform: TargetPlatform.linux,
        ),
      );
      await tester.pumpAndSettle();

      // "Help" names both the menu and its first item; the menu title is the
      // one in the bar, so open it and take the item from the opened menu.
      await tester.tap(find.text('Help'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('About'));
      await tester.pumpAndSettle();
      expect(about, 1);

      await tester.tap(find.text('Help').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Help').last);
      await tester.pumpAndSettle();
      expect(help, 1);
    });
  });

  group('the macOS system menu bar', () {
    PlatformMenuBar bar(WidgetTester tester) =>
        tester.widget<PlatformMenuBar>(find.byType(PlatformMenuBar));

    List<String> labelsOf(List<PlatformMenuItem> menus) => [
      for (final menu in menus)
        if (menu is PlatformMenuItemGroup)
          ...labelsOf(menu.members)
        else
          menu.label,
    ];

    testWidgets('follows the platform layout: About, Preferences and Quit '
        'live in the application menu', (tester) async {
      await tester.pumpWidget(
        harness(
          publishedCommands(
            newNote: () {},
            newFolder: () {},
            preferences: () {},
            help: () {},
            about: () {},
          ),
          platform: TargetPlatform.macOS,
        ),
      );
      await tester.pumpAndSettle();

      final menus = bar(tester).menus.cast<PlatformMenu>();
      expect(labelsOf(menus), ['BrainFrame', 'File', 'Edit', 'Help']);
      expect(labelsOf(menus[0].menus), ['About', 'Preferences', 'Quit']);
      expect(labelsOf(menus[1].menus), ['New note', 'New folder']);
      expect(labelsOf(menus[2].menus), ['Cut', 'Copy', 'Paste']);
      expect(labelsOf(menus[3].menus), ['Help']);
    });

    testWidgets('its accelerators are the Command-key ones', (tester) async {
      await tester.pumpWidget(
        harness(
          publishedCommands(newNote: () {}),
          platform: TargetPlatform.macOS,
        ),
      );
      await tester.pumpAndSettle();

      final menus = bar(tester).menus.cast<PlatformMenu>();
      final newNote = menus[1].menus.first;
      expect(
        newNote.shortcut,
        const SingleActivator(LogicalKeyboardKey.keyN, meta: true),
      );
    });

    testWidgets('an unpublished command leaves its item unselectable', (
      tester,
    ) async {
      await tester.pumpWidget(
        harness(publishedCommands(), platform: TargetPlatform.macOS),
      );
      await tester.pumpAndSettle();

      final menus = bar(tester).menus.cast<PlatformMenu>();
      final newNote = menus[1].menus.first;
      expect(newNote.onSelected, isNull);
    });
  });

  testWidgets('the menu bar stays above a dialog opened inside the app', (
    tester,
  ) async {
    await tester.pumpWidget(
      harness(publishedCommands(newNote: () {}), platform: TargetPlatform.linux),
    );
    await tester.pumpAndSettle();

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    showDialog<void>(
      context: navigator.context,
      builder: (_) => const AlertDialog(content: Text('a dialog')),
    );
    await tester.pumpAndSettle();

    expect(find.text('a dialog'), findsOneWidget);
    // Still there, and still usable — the strip is outside the Navigator.
    await tester.tap(find.text('File'));
    await tester.pumpAndSettle();
    expect(find.text('New note'), findsOneWidget);
  });
}
