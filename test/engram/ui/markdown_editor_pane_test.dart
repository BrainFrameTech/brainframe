import 'dart:async';
import 'dart:convert';

import 'package:brainframe/commands/app_commands.dart';
import 'package:brainframe/engram/engram_store.dart';
import 'package:brainframe/engram/ui/find_in_page.dart';
import 'package:brainframe/engram/ui/markdown_editor_pane.dart';
import 'package:brainframe/engram/ui/markdown_reader.dart';
import 'package:brainframe/engram/ui/markdown_source_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/localized_app.dart';

/// A read-write in-memory store that records which paths were written.
class _RwStore extends EngramStore {
  _RwStore(this.files);
  final Map<String, String> files;
  final List<String> writes = [];

  /// When true, every write throws — to exercise the `error` status.
  bool failWrites = false;

  /// When set, writes block on this completer — to hold the `saving` status
  /// long enough to observe it.
  Completer<void>? gate;

  @override
  Future<List<String>> list() async => files.keys.toList();

  @override
  Future<Uint8List> readBytes(String path) async {
    final content = files[path];
    if (content == null) throw StateError('no such file: $path');
    return Uint8List.fromList(utf8.encode(content));
  }

  @override
  Future<void> writeBytes(String path, Uint8List bytes) async {
    if (gate != null) await gate!.future;
    if (failWrites) throw Exception('write failed');
    files[path] = utf8.decode(bytes);
    writes.add(path);
  }
}

/// A store whose reads always fail, to exercise the pane's error branch.
class _ThrowingStore extends EngramStore {
  @override
  Future<List<String>> list() async => const [];

  @override
  Future<Uint8List> readBytes(String path) async =>
      throw StateError('boom: $path');

  @override
  Future<void> writeBytes(String path, Uint8List bytes) async {}
}

Widget _host(EngramStore store, String path) => localizedApp(
      home: Scaffold(
        body: SizedBox(
          width: 1000,
          height: 600,
          child: MarkdownEditorPane(store: store, path: path),
        ),
      ),
    );

void main() {
  testWidgets('opens in Edit mode showing the file source and a clean status',
      (tester) async {
    final store = _RwStore({'a.md': '# Hello'});
    await tester.pumpWidget(_host(store, 'a.md'));
    await tester.pumpAndSettle();

    expect(find.byType(MarkdownSourceEditor), findsOneWidget);
    expect(find.text('# Hello'), findsOneWidget);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Preview'), findsOneWidget);
    expect(find.text('Saved'), findsOneWidget);
  });

  testWidgets('Preview renders the reader and hides the editor',
      (tester) async {
    final store = _RwStore({'a.md': '# Heading'});
    await tester.pumpWidget(_host(store, 'a.md'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();

    expect(find.byType(MarkdownReader), findsOneWidget);
    expect(find.byType(MarkdownSourceEditor), findsNothing);
  });

  testWidgets('editing marks unsaved, and tapping the chip saves', (tester) async {
    final store = _RwStore({'a.md': '# A'});
    await tester.pumpWidget(_host(store, 'a.md'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '# A edited');
    await tester.pump();
    expect(find.text('Unsaved changes'), findsOneWidget);

    await tester.tap(find.text('Unsaved changes')); // the save-now chip
    await tester.pump();
    await tester.pump();

    expect(store.files['a.md'], '# A edited');
    expect(store.writes, ['a.md']);
    expect(find.text('Saved'), findsOneWidget);
  });

  testWidgets('edits survive an Edit → Preview → Edit round-trip',
      (tester) async {
    final store = _RwStore({'a.md': '# A'});
    await tester.pumpWidget(_host(store, 'a.md'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '# A edited');
    await tester.pump();

    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    expect(find.byType(MarkdownSourceEditor), findsNothing);

    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();

    // The editor must show the in-progress edit, not the on-open copy.
    expect(find.text('# A edited'), findsOneWidget);
    expect(find.text('# A'), findsNothing);
  });

  testWidgets('toggling to Preview flushes pending edits first', (tester) async {
    final store = _RwStore({'a.md': '# A'});
    await tester.pumpWidget(_host(store, 'a.md'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '# changed');
    await tester.pump();

    await tester.tap(find.text('Preview'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(store.files['a.md'], '# changed');
    expect(find.byType(MarkdownReader), findsOneWidget);
  });

  testWidgets('idle autosave writes without a manual save', (tester) async {
    final store = _RwStore({'a.md': '# A'});
    await tester.pumpWidget(_host(store, 'a.md'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '# auto');
    await tester.pump();
    await tester.pump(const Duration(seconds: 6)); // past the 5s idle debounce
    await tester.pump();

    expect(store.files['a.md'], '# auto');
  });

  testWidgets('losing editor focus flushes', (tester) async {
    final store = _RwStore({'a.md': '# A'});
    await tester.pumpWidget(_host(store, 'a.md'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '# blur');
    await tester.pump();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pump();
    await tester.pump();

    expect(store.files['a.md'], '# blur');
  });

  testWidgets('switching the open file flushes the previous one',
      (tester) async {
    final store = _RwStore({'a.md': '# A', 'b.md': '# B'});
    await tester.pumpWidget(_host(store, 'a.md'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '# A edited');
    await tester.pump();

    // Same tree position, new path -> didUpdateWidget -> flush a.md, open b.md.
    await tester.pumpWidget(_host(store, 'b.md'));
    await tester.pumpAndSettle();

    expect(store.files['a.md'], '# A edited');
    expect(find.text('# B'), findsOneWidget);
  });

  testWidgets('shows Saving… while a write is in flight', (tester) async {
    final store = _RwStore({'a.md': '# A'})..gate = Completer<void>();
    await tester.pumpWidget(_host(store, 'a.md'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '# A edited');
    await tester.pump();
    await tester.tap(find.text('Unsaved changes'));
    await tester.pump(); // flush starts; write blocks on the gate

    expect(find.text('Saving…'), findsOneWidget);

    store.gate!.complete();
    await tester.pump();
    await tester.pump();
    expect(find.text('Saved'), findsOneWidget);
  });

  testWidgets('a failed save shows the error status and keeps edits',
      (tester) async {
    final store = _RwStore({'a.md': '# A'})..failWrites = true;
    await tester.pumpWidget(_host(store, 'a.md'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '# A edited');
    await tester.pump();
    await tester.tap(find.text('Unsaved changes'));
    await tester.pump();
    await tester.pump();

    expect(find.text('Couldn’t save'), findsOneWidget);
    expect(store.writes, isEmpty);
  });

  testWidgets('a read failure shows an error instead of the editor',
      (tester) async {
    await tester.pumpWidget(_host(_ThrowingStore(), 'a.md'));
    await tester.pumpAndSettle();

    expect(find.byType(MarkdownSourceEditor), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  for (final (name, modifier) in [
    ('Ctrl+S', LogicalKeyboardKey.control),
    ('Cmd+S', LogicalKeyboardKey.meta),
  ]) {
    testWidgets('$name saves the buffer', (tester) async {
      final store = _RwStore({'a.md': '# A'});
      await tester.pumpWidget(_host(store, 'a.md'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '# A edited');
      await tester.pump();

      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(modifier);
      await tester.pump();
      await tester.pump();

      expect(store.files['a.md'], '# A edited');
    });
  }

  group('find in page', () {
    /// The document's own field — with the find bar open there are two.
    Finder sourceField() => find.descendant(
      of: find.byType(MarkdownSourceEditor),
      matching: find.byType(TextField),
    );

    Finder queryField() => find.descendant(
      of: find.byType(FindInPageBar),
      matching: find.byType(TextField),
    );

    TextSelection sourceSelection(WidgetTester tester) => tester
        .widget<EditableText>(
          find.descendant(
            of: find.byType(MarkdownSourceEditor),
            matching: find.byType(EditableText),
          ),
        )
        .controller
        .selection;

    Future<void> openFind(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Find in page'));
      await tester.pumpAndSettle();
    }

    testWidgets('the magnifying glass opens the bar and counts the matches', (
      tester,
    ) async {
      final store = _RwStore({'a.md': 'one two one'});
      await tester.pumpWidget(_host(store, 'a.md'));
      await tester.pumpAndSettle();

      expect(find.byType(FindInPageBar), findsNothing);
      await openFind(tester);
      expect(find.byType(FindInPageBar), findsOneWidget);

      await tester.enterText(queryField(), 'one');
      await tester.pump();

      expect(find.text('1 of 2'), findsOneWidget);
    });

    testWidgets('the steppers cycle through the matches, wrapping at both '
        'ends', (tester) async {
      final store = _RwStore({'a.md': 'one two one three one'});
      await tester.pumpWidget(_host(store, 'a.md'));
      await tester.pumpAndSettle();
      await openFind(tester);
      await tester.enterText(queryField(), 'one');
      await tester.pump();

      await tester.tap(find.widgetWithIcon(IconButton, Icons.keyboard_arrow_down));
      await tester.pump();
      expect(find.text('2 of 3'), findsOneWidget);

      await tester.tap(find.widgetWithIcon(IconButton, Icons.keyboard_arrow_up));
      await tester.tap(find.widgetWithIcon(IconButton, Icons.keyboard_arrow_up));
      await tester.pump();
      expect(find.text('3 of 3'), findsOneWidget, reason: 'wraps backwards');

      await tester.tap(find.widgetWithIcon(IconButton, Icons.keyboard_arrow_down));
      await tester.pump();
      expect(find.text('1 of 3'), findsOneWidget, reason: 'wraps forwards');
    });

    testWidgets('closing hands the caret to the match the user stopped at', (
      tester,
    ) async {
      final store = _RwStore({'a.md': 'one two one'});
      await tester.pumpWidget(_host(store, 'a.md'));
      await tester.pumpAndSettle();
      await openFind(tester);
      await tester.enterText(queryField(), 'one');
      await tester.pump();
      await tester.tap(find.widgetWithIcon(IconButton, Icons.keyboard_arrow_down));
      await tester.pump();

      await tester.tap(find.byTooltip('Close find'));
      await tester.pumpAndSettle();

      expect(find.byType(FindInPageBar), findsNothing);
      expect(
        sourceSelection(tester),
        const TextSelection(baseOffset: 8, extentOffset: 11),
      );
    });

    testWidgets('a query that matches nothing says so and steps nowhere', (
      tester,
    ) async {
      final store = _RwStore({'a.md': 'one two one'});
      await tester.pumpWidget(_host(store, 'a.md'));
      await tester.pumpAndSettle();
      await openFind(tester);
      await tester.enterText(queryField(), 'zebra');
      await tester.pump();

      expect(find.text('No results'), findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.widgetWithIcon(IconButton, Icons.keyboard_arrow_down),
            )
            .onPressed,
        isNull,
      );

      // Closing with no match leaves the document alone rather than jumping.
      await tester.tap(find.byTooltip('Close find'));
      await tester.pumpAndSettle();
      expect(sourceSelection(tester).isCollapsed, isTrue);
    });

    testWidgets('find works on the source, so it leaves Preview', (
      tester,
    ) async {
      final store = _RwStore({'a.md': '# Heading'});
      await tester.pumpWidget(_host(store, 'a.md'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Preview'));
      await tester.pumpAndSettle();
      expect(find.byType(MarkdownSourceEditor), findsNothing);

      await openFind(tester);

      expect(find.byType(MarkdownSourceEditor), findsOneWidget);
      expect(find.byType(FindInPageBar), findsOneWidget);
    });

    testWidgets('editing the document keeps the count honest', (tester) async {
      final store = _RwStore({'a.md': 'one two'});
      await tester.pumpWidget(_host(store, 'a.md'));
      await tester.pumpAndSettle();
      await openFind(tester);
      await tester.enterText(queryField(), 'one');
      await tester.pump();
      expect(find.text('1 of 1'), findsOneWidget);

      await tester.enterText(sourceField(), 'one two one');
      await tester.pump();

      expect(find.text('1 of 2'), findsOneWidget);
    });

    testWidgets('an open find re-runs against the next file opened', (
      tester,
    ) async {
      final store = _RwStore({'a.md': 'one two', 'b.md': 'one one one'});
      await tester.pumpWidget(_host(store, 'a.md'));
      await tester.pumpAndSettle();
      await openFind(tester);
      await tester.enterText(queryField(), 'one');
      await tester.pump();
      expect(find.text('1 of 1'), findsOneWidget);

      await tester.pumpWidget(_host(store, 'b.md'));
      await tester.pumpAndSettle();

      expect(find.text('1 of 3'), findsOneWidget);
    });

    testWidgets('reopening find offers the previous query, selected', (
      tester,
    ) async {
      final store = _RwStore({'a.md': 'one two one'});
      await tester.pumpWidget(_host(store, 'a.md'));
      await tester.pumpAndSettle();
      await openFind(tester);
      await tester.enterText(queryField(), 'one');
      await tester.pump();
      await tester.tap(find.byTooltip('Close find'));
      await tester.pumpAndSettle();

      await openFind(tester);

      final query = tester.widget<TextField>(queryField()).controller!;
      expect(query.text, 'one');
      expect(
        query.selection,
        const TextSelection(baseOffset: 0, extentOffset: 3),
        reason: 'typing must replace the old query, not append to it',
      );
      expect(find.text('1 of 2'), findsOneWidget);
    });

    testWidgets('it publishes Find to the menu bar, and withdraws it when the '
        'pane goes', (tester) async {
      final commands = AppCommands();
      addTearDown(commands.dispose);
      final store = _RwStore({'a.md': 'one two one'});

      await tester.pumpWidget(
        AppCommandsScope(
          commands: commands,
          child: _host(store, 'a.md'),
        ),
      );
      await tester.pumpAndSettle();

      expect(commands.find, isNotNull);
      commands.find!();
      await tester.pumpAndSettle();
      expect(find.byType(FindInPageBar), findsOneWidget);

      await tester.pumpWidget(
        AppCommandsScope(
          commands: commands,
          child: localizedApp(home: const Scaffold(body: SizedBox())),
        ),
      );
      await tester.pumpAndSettle();

      expect(commands.find, isNull);
    });
  });
}
