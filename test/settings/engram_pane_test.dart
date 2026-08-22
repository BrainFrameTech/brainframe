
import 'package:brainframe/engram/engram.dart';
import 'package:brainframe/engram/engram_store.dart';
import 'package:brainframe/engram/metadata.dart';
import 'package:brainframe/settings/engram_pane.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/localized_app.dart';

/// A store standing in for a filesystem engram: it reports a location, which is
/// what the pane distinguishes an on-disk engram from a bundled one by.
class _FakeStore extends EngramStore {
  _FakeStore({this.location = '/home/user/notes/zettel'});

  final String? location;

  @override
  String? get locationDescription => location;

  @override
  Future<List<String>> list() async => const [];

  @override
  Future<Uint8List> readBytes(String path) async => Uint8List(0);

  @override
  Future<void> writeBytes(String path, Uint8List bytes) async {}
}

const String _id = '01JAB2CD3EFGHJKMNPQRSTVWXY';

Engram _engram({
  String name = 'zettel',
  bool readOnly = false,
  String? location = '/home/user/notes/zettel',
}) => Engram(
  id: _id,
  displayName: name,
  readOnly: readOnly,
  store: _FakeStore(location: location),
);

EngramMetadata _metadata({String name = 'zettel'}) => EngramMetadata(
  schemaVersion: 1,
  id: _id,
  displayName: name,
  createdUtc: DateTime.utc(2026, 5, 1, 9),
);

void main() {
  /// A fake rename: records the name, and serves it back through the marker
  /// loader so the pane's re-read reflects the write — no filesystem.
  late List<String> renames;
  late EngramMetadata? stored;
  late Engram engram;
  Object? renameError;

  Future<EngramMetadata?> load() async => stored;

  Future<Engram> rename(String name) async {
    if (renameError != null) throw renameError!;
    renames.add(name);
    stored = stored?.withDisplayName(name);
    engram = engram.withDisplayName(name);
    return engram;
  }

  setUp(() {
    renames = [];
    stored = _metadata();
    engram = _engram();
    renameError = null;
  });

  Widget host({Engram? open, ValueChanged<Engram>? onRenamed}) => localizedApp(
    home: Scaffold(
      body: EngramPane(
        engram: open ?? engram,
        loadMetadata: load,
        rename: rename,
        onRenamed: onRenamed,
      ),
    ),
  );

  testWidgets('shows the stored name, identifier, location and format', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'zettel',
    );
    expect(find.text(_id), findsOneWidget);
    expect(find.text('/home/user/notes/zettel'), findsOneWidget);
    expect(find.text('2026-05-01T09:00:00.000Z'), findsOneWidget);
    expect(find.text('1'), findsOneWidget);
    expect(find.text('No'), findsOneWidget); // read-only
  });

  testWidgets('Save is disabled until the name actually changes', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    FilledButton save() =>
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'));
    expect(save().onPressed, isNull);

    await tester.enterText(find.byType(TextField), 'Field Notebook');
    await tester.pump();
    expect(save().onPressed, isNotNull);

    // Back to the stored name — nothing to save again.
    await tester.enterText(find.byType(TextField), 'zettel');
    await tester.pump();
    expect(save().onPressed, isNull);
  });

  testWidgets('saving renames, confirms, and reports the new engram', (
    tester,
  ) async {
    Engram? reported;
    await tester.pumpWidget(host(onRenamed: (e) => reported = e));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Field Notebook');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(renames, ['Field Notebook']);
    expect(reported?.displayName, 'Field Notebook');
    expect(find.textContaining('Renamed to'), findsOneWidget);
    // The details block re-read the marker rather than patching its copy.
    expect(stored!.displayName, 'Field Notebook');
  });

  testWidgets('a trailing space is trimmed before saving', (tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '  Field Notebook  ');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(renames, ['Field Notebook']);
  });

  testWidgets('a blank name is refused without touching the marker', (
    tester,
  ) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(renames, isEmpty);
    expect(find.text('Enter a name.'), findsOneWidget);

    // Typing clears the complaint.
    await tester.enterText(find.byType(TextField), 'Field Notebook');
    await tester.pump();
    expect(find.text('Enter a name.'), findsNothing);
  });

  testWidgets('submitting the field saves, like the button', (tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Field Notebook');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(renames, ['Field Notebook']);
  });

  testWidgets('a failed write is reported and leaves the field editable', (
    tester,
  ) async {
    renameError = StateError('Permission denied');
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'Field Notebook');
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not save the name'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
  });

  group('a built-in engram', () {
    setUp(() {
      engram = _engram(name: 'Tutorial', readOnly: true, location: null);
      stored = null; // asset-backed: no marker on disk
    });

    testWidgets('cannot be renamed and says why', (tester) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
      expect(find.widgetWithText(FilledButton, 'Save'), findsNothing);
      expect(
        find.textContaining("Built-in engrams can't be renamed"),
        findsOneWidget,
      );
    });

    testWidgets('still shows the details it has', (tester) async {
      await tester.pumpWidget(host());
      await tester.pumpAndSettle();

      expect(find.text(_id), findsOneWidget);
      expect(find.text('Bundled with the app'), findsOneWidget);
      expect(find.text('Yes'), findsOneWidget); // read-only
      // Nothing is invented for the fields a bundled engram has no marker for.
      expect(find.text('Created'), findsNothing);
      expect(find.text('Format version'), findsNothing);
    });
  });

  testWidgets('a malformed marker is surfaced, not hidden', (tester) async {
    await tester.pumpWidget(
      localizedApp(
        home: Scaffold(
          body: EngramPane(
            engram: engram,
            loadMetadata: () async => throw const EngramMetadataException(
              'engram.json is not valid JSON',
            ),
            rename: rename,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining("Could not read this engram's details"),
      findsOneWidget,
    );
    // The identity the app does know is still shown, and the name is still
    // editable — a broken marker is exactly when you need this pane.
    expect(find.text(_id), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
  });

  testWidgets('copies the details to the clipboard', (tester) async {
    final clipboard = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    final copy = find.widgetWithText(OutlinedButton, 'Copy details');
    await tester.scrollUntilVisible(
      copy,
      100,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(copy);
    await tester.pumpAndSettle();

    expect(clipboard.single, contains(_id));
    expect(clipboard.single, contains('/home/user/notes/zettel'));
    expect(clipboard.single, contains('2026-05-01T09:00:00.000Z'));
    expect(find.textContaining('Details copied'), findsOneWidget);
  });

  testWidgets('the name field and detail rows carry semantics', (tester) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(
      tester.getSemantics(find.byType(TextField)),
      matchesSemantics(
        label: 'Display name',
        isTextField: true,
        isEnabled: true,
        hasEnabledState: true,
      ),
    );
    expect(find.bySemanticsLabel('Identifier'), findsOneWidget);
    handle.dispose();
  });
}
