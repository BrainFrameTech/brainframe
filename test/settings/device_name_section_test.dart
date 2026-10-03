import 'package:brainframe/engram/device_name.dart';
import 'package:brainframe/settings/device_name_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fake_device_naming.dart';
import '../support/localized_app.dart';

/// Settings › Engram's "This device" section (the device names design,
/// Decisions 1 and 2): the default name, this engram's name, and what the
/// other devices see.
void main() {
  Widget host(DeviceNaming naming) => localizedApp(
    home: Scaffold(
      body: ListView(children: [DeviceNameSection(naming: naming)]),
    ),
  );

  Finder field(String key) => find.descendant(
    of: find.byKey(ValueKey(key)),
    matching: find.byType(TextField),
  );

  Finder saveOf(String key) => find.descendant(
    of: find.byKey(ValueKey(key)),
    matching: find.byType(FilledButton),
  );

  bool enabled(WidgetTester tester, Finder button) =>
      tester.widget<FilledButton>(button).onPressed != null;

  testWidgets('shows both names, what blank falls back to, and the result', (
    tester,
  ) async {
    final naming = FakeDeviceNaming(deviceDefault: 'jdoe\'s laptop');
    await tester.pumpWidget(host(naming));

    expect(find.text('This device'), findsOneWidget);
    expect(find.textContaining('synced or shared'), findsOneWidget);
    expect(
      tester.widget<TextField>(field('device-default-name')).controller!.text,
      'jdoe\'s laptop',
    );
    expect(
      find.textContaining('Leave blank to use “jdoe-desktop”'),
      findsOneWidget,
      reason: 'a blank default falls back to the platform\'s name',
    );
    expect(
      find.textContaining('Leave blank to use “jdoe\'s laptop”'),
      findsOneWidget,
      reason: 'a blank engram name falls back to the default',
    );
    expect(
      find.text('Other devices see this one as “jdoe\'s laptop”.'),
      findsOneWidget,
    );
    expect(enabled(tester, saveOf('device-default-name')), isFalse);
    expect(enabled(tester, saveOf('device-engram-name')), isFalse);
  });

  testWidgets('a name for this engram is saved and wins', (tester) async {
    final naming = FakeDeviceNaming(deviceDefault: 'jdoe\'s laptop');
    await tester.pumpWidget(host(naming));

    await tester.enterText(field('device-engram-name'), '  Work laptop ');
    await tester.pump();
    expect(enabled(tester, saveOf('device-engram-name')), isTrue);
    await tester.tap(saveOf('device-engram-name'));
    await tester.pumpAndSettle();

    expect(naming.calls, ['engram:  Work laptop ']);
    expect(
      find.text('Other devices see this one as “Work laptop”.'),
      findsOneWidget,
    );
    expect(
      tester.widget<TextField>(field('device-engram-name')).controller!.text,
      'Work laptop',
      reason: 'the field shows what was stored, trimmed',
    );
    expect(find.textContaining('Saved.'), findsOneWidget);
    expect(enabled(tester, saveOf('device-engram-name')), isFalse);
  });

  testWidgets('saving a name blank clears it, falling back a step', (
    tester,
  ) async {
    final naming = FakeDeviceNaming(
      engram: 'Work laptop',
      deviceDefault: 'jdoe\'s laptop',
    );
    await tester.pumpWidget(host(naming));
    expect(
      find.text('Other devices see this one as “Work laptop”.'),
      findsOneWidget,
    );

    await tester.enterText(field('device-engram-name'), '');
    await tester.pump();
    await tester.tap(saveOf('device-engram-name'));
    await tester.pumpAndSettle();

    expect(
      find.text('Other devices see this one as “jdoe\'s laptop”.'),
      findsOneWidget,
    );
  });

  testWidgets('the default is saved through its own field', (tester) async {
    final naming = FakeDeviceNaming();
    await tester.pumpWidget(host(naming));

    await tester.enterText(field('device-default-name'), 'jdoe\'s laptop');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(naming.calls, ['default:jdoe\'s laptop']);
    expect(
      find.text('Other devices see this one as “jdoe\'s laptop”.'),
      findsOneWidget,
    );
    expect(
      find.textContaining('Leave blank to use “jdoe\'s laptop”'),
      findsOneWidget,
      reason: 'the engram field now falls back to the new default',
    );
  });

  testWidgets('submitting an unchanged field saves nothing', (tester) async {
    final naming = FakeDeviceNaming(deviceDefault: 'jdoe\'s laptop');
    await tester.pumpWidget(host(naming));
    await tester.showKeyboard(field('device-default-name'));
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(naming.calls, isEmpty);
  });

  testWidgets('a name longer than the limit cannot be typed', (tester) async {
    final naming = FakeDeviceNaming();
    await tester.pumpWidget(host(naming));
    await tester.enterText(field('device-engram-name'), 'x' * 80);
    await tester.pump();
    expect(
      tester.widget<TextField>(field('device-engram-name')).controller!.text,
      'x' * deviceNameMaxLength,
    );
  });

  testWidgets('a failed save is said, and the names stay', (tester) async {
    final naming = FakeDeviceNaming()..failWith = StateError('locked');
    await tester.pumpWidget(host(naming));

    await tester.enterText(field('device-engram-name'), 'Work laptop');
    await tester.pump();
    await tester.tap(saveOf('device-engram-name'));
    await tester.pumpAndSettle();

    expect(
      find.text('The device name could not be saved: Bad state: locked'),
      findsOneWidget,
    );
    expect(
      find.text('Other devices see this one as “jdoe-desktop”.'),
      findsOneWidget,
    );
  });

  testWidgets('fields and buttons say what they are to a screen reader', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(host(FakeDeviceNaming()));

    expect(find.bySemanticsLabel('Default name (every engram)'), findsWidgets);
    expect(find.bySemanticsLabel('Name in this engram'), findsWidgets);
    expect(find.bySemanticsLabel('Save Name in this engram'), findsOneWidget);
    expect(
      tester.getSemantics(find.text('This device')),
      matchesSemantics(label: 'This device', isHeader: true),
    );
    handle.dispose();
  });

  testWidgets('a screen reader hears the name being edited', (tester) async {
    // The field keeps its own semantics: its label, and its value too —
    // which a wrapper excluding them used to silence.
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      host(FakeDeviceNaming(deviceDefault: 'jdoe\'s laptop')),
    );
    expect(
      // The field's own node is on its EditableText, below the TextField
      // widget's outermost render object.
      tester.getSemantics(
        find.descendant(
          of: field('device-default-name'),
          matching: find.byType(EditableText),
        ),
      ),
      isSemantics(
        isTextField: true,
        label: 'Default name (every engram)',
        value: 'jdoe\'s laptop',
      ),
    );
    handle.dispose();
  });

  testWidgets('a screen reader can press Save, not merely find it', (
    tester,
  ) async {
    // A button node with no tap action can be focused and never activated.
    final handle = tester.ensureSemantics();
    final naming = FakeDeviceNaming();
    await tester.pumpWidget(host(naming));
    await tester.enterText(field('device-engram-name'), 'Work laptop');
    await tester.pump();

    final save = saveOf('device-engram-name');
    expect(
      tester.getSemantics(save),
      isSemantics(
        isButton: true,
        isEnabled: true,
        hasTapAction: true,
        label: 'Save Name in this engram',
      ),
    );
    tester.semantics.tap(find.semantics.byLabel('Save Name in this engram'));
    await tester.pumpAndSettle();
    expect(naming.calls, ['engram:Work laptop']);
    handle.dispose();
  });

  testWidgets('a save that lands from elsewhere is shown, sparing an edit', (
    tester,
  ) async {
    // A section left mid-save and rebuilt: the save it started lands after
    // the new one read the names, and only [DeviceNaming.changes] says so.
    final naming = FakeDeviceNaming(deviceDefault: 'jdoe\'s laptop');
    await tester.pumpWidget(host(naming));
    await tester.enterText(field('device-engram-name'), 'Typing…');

    naming.names = const DeviceNames(
      engram: 'Work laptop',
      deviceDefault: 'jdoe\'s desk',
      platform: 'jdoe-desktop',
    );
    await tester.pump();

    expect(
      tester.widget<TextField>(field('device-default-name')).controller!.text,
      'jdoe\'s desk',
    );
    expect(
      tester.widget<TextField>(field('device-engram-name')).controller!.text,
      'Typing…',
      reason: 'an edit in progress is the user\'s, not overwritten',
    );
    expect(
      find.text('Other devices see this one as “Work laptop”.'),
      findsOneWidget,
    );
    expect(enabled(tester, saveOf('device-default-name')), isFalse);
  });

  testWidgets('a section handed other names follows them', (tester) async {
    final first = FakeDeviceNaming(deviceDefault: 'jdoe\'s laptop');
    await tester.pumpWidget(host(first));
    final second = FakeDeviceNaming(deviceDefault: 'jdoe\'s desk');
    await tester.pumpWidget(host(second));
    expect(
      tester.widget<TextField>(field('device-default-name')).controller!.text,
      'jdoe\'s desk',
    );
    // The first no longer reaches it.
    first.names = const DeviceNames(
      engram: 'elsewhere',
      deviceDefault: null,
      platform: 'jdoe-desktop',
    );
    await tester.pump();
    expect(find.textContaining('elsewhere'), findsNothing);
  });

  testWidgets('saving one field keeps an unsaved edit in the other', (
    tester,
  ) async {
    final naming = FakeDeviceNaming();
    await tester.pumpWidget(host(naming));
    await tester.enterText(field('device-default-name'), 'jdoe\'s laptop');
    await tester.enterText(field('device-engram-name'), 'Work laptop');
    await tester.pump();

    await tester.tap(saveOf('device-engram-name'));
    await tester.pumpAndSettle();

    expect(naming.calls, ['engram:Work laptop']);
    expect(
      tester.widget<TextField>(field('device-default-name')).controller!.text,
      'jdoe\'s laptop',
      reason: 'the draft in the other field is not erased',
    );
    expect(enabled(tester, saveOf('device-default-name')), isTrue);
  });
}
