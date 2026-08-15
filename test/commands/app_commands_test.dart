import 'package:brainframe/commands/app_commands.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('publish exposes the callbacks it was given', () {
    final commands = AppCommands();
    addTearDown(commands.dispose);
    var notes = 0;

    commands.publish(newNote: () => notes++, about: () {});

    expect(commands.newNote, isNotNull);
    expect(commands.about, isNotNull);
    expect(commands.newFolder, isNull);
    commands.newNote!();
    expect(notes, 1);
  });

  test('listeners fire when availability changes, not on every publish', () {
    final commands = AppCommands();
    addTearDown(commands.dispose);
    var notifications = 0;
    commands.addListener(() => notifications++);

    commands.publish(newNote: () {});
    expect(notifications, 1, reason: 'newNote became available');

    // Same availability, a different closure: the menu would render exactly the
    // same, so rebuilding it would be pure churn.
    commands.publish(newNote: () {});
    expect(notifications, 1);

    commands.publish(newFolder: () {});
    expect(
      notifications,
      2,
      reason: 'newNote went away and newFolder arrived',
    );
  });

  test('withdraw clears every command', () {
    final commands = AppCommands();
    addTearDown(commands.dispose);
    commands.publish(
      newNote: () {},
      newFolder: () {},
      preferences: () {},
      help: () {},
      about: () {},
    );

    commands.withdraw();

    expect(commands.newNote, isNull);
    expect(commands.newFolder, isNull);
    expect(commands.preferences, isNull);
    expect(commands.help, isNull);
    expect(commands.about, isNull);
  });

  test('a publisher withdrawing after disposal is accepted quietly', () {
    // Flutter disposes a parent's state before unmounting its children, so the
    // browser's withdraw-on-dispose arrives after the app root has disposed
    // this. It must not throw on the way out of the app.
    final commands = AppCommands()..publish(newNote: () {});
    commands.dispose();

    expect(commands.withdraw, returnsNormally);
  });

  testWidgets('the scope hands the same instance to both sides of the app', (
    tester,
  ) async {
    final commands = AppCommands();
    addTearDown(commands.dispose);
    late AppCommands seen;

    await tester.pumpWidget(
      AppCommandsScope(
        commands: commands,
        child: Builder(
          builder: (context) {
            seen = AppCommandsScope.of(context);
            return const SizedBox();
          },
        ),
      ),
    );

    expect(identical(seen, commands), isTrue);
  });

  testWidgets('of() rebuilds its dependents when availability changes', (
    tester,
  ) async {
    final commands = AppCommands();
    addTearDown(commands.dispose);
    var builds = 0;

    await tester.pumpWidget(
      AppCommandsScope(
        commands: commands,
        child: Builder(
          builder: (context) {
            builds++;
            return Text(
              AppCommandsScope.of(context).newNote == null ? 'off' : 'on',
              textDirection: TextDirection.ltr,
            );
          },
        ),
      ),
    );
    expect(find.text('off'), findsOneWidget);
    final before = builds;

    commands.publish(newNote: () {});
    await tester.pump();

    expect(builds, greaterThan(before));
    expect(find.text('on'), findsOneWidget);
  });

  testWidgets('maybeOf is null outside a scope, and does not subscribe', (
    tester,
  ) async {
    final commands = AppCommands();
    addTearDown(commands.dispose);
    var builds = 0;
    AppCommands? outside;

    await tester.pumpWidget(
      Column(
        textDirection: TextDirection.ltr,
        children: [
          Builder(
            builder: (context) {
              outside = AppCommandsScope.maybeOf(context);
              return const SizedBox();
            },
          ),
          AppCommandsScope(
            commands: commands,
            child: Builder(
              builder: (context) {
                builds++;
                AppCommandsScope.maybeOf(context);
                return const SizedBox();
              },
            ),
          ),
        ],
      ),
    );
    expect(outside, isNull);
    final before = builds;

    commands.publish(newNote: () {});
    await tester.pump();

    expect(
      builds,
      before,
      reason: 'a publisher only writes; it must not rebuild on its own writes',
    );
  });
}
