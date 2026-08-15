import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../window/window_state.dart';
import 'app_commands.dart';

/// The accelerators a platform gives the app's commands — one source for both
/// what the menus *display* and what is actually *bound*, so the two can never
/// drift.
///
/// Linux and Windows carry them on Control; macOS on Command. The e-ink target
/// and mobile have no menu bar and no modifiers to speak of, so they get none.
class AppShortcuts {
  const AppShortcuts({
    this.newNote,
    this.newFolder,
    this.quit,
    this.preferences,
    this.cut,
    this.copy,
    this.paste,
    this.bindInApp = true,
  });

  /// The accelerators for [platform].
  factory AppShortcuts.forPlatform(TargetPlatform platform) {
    switch (platform) {
      case TargetPlatform.linux:
      case TargetPlatform.windows:
        return const AppShortcuts(
          newNote: SingleActivator(LogicalKeyboardKey.keyN, control: true),
          newFolder: SingleActivator(
            LogicalKeyboardKey.keyN,
            control: true,
            shift: true,
          ),
          quit: SingleActivator(LogicalKeyboardKey.keyQ, control: true),
          preferences: SingleActivator(
            LogicalKeyboardKey.comma,
            control: true,
          ),
          cut: SingleActivator(LogicalKeyboardKey.keyX, control: true),
          copy: SingleActivator(LogicalKeyboardKey.keyC, control: true),
          paste: SingleActivator(LogicalKeyboardKey.keyV, control: true),
        );
      case TargetPlatform.macOS:
        // Command, not Control — and bound by the *system* menu bar, which
        // registers each item's key equivalent with macOS. Binding them in-app
        // as well is how a command ends up firing twice.
        return const AppShortcuts(
          newNote: SingleActivator(LogicalKeyboardKey.keyN, meta: true),
          newFolder: SingleActivator(
            LogicalKeyboardKey.keyN,
            meta: true,
            shift: true,
          ),
          quit: SingleActivator(LogicalKeyboardKey.keyQ, meta: true),
          preferences: SingleActivator(LogicalKeyboardKey.comma, meta: true),
          cut: SingleActivator(LogicalKeyboardKey.keyX, meta: true),
          copy: SingleActivator(LogicalKeyboardKey.keyC, meta: true),
          paste: SingleActivator(LogicalKeyboardKey.keyV, meta: true),
          bindInApp: false,
        );
      case TargetPlatform.android:
      case TargetPlatform.fuchsia:
      case TargetPlatform.iOS:
        return const AppShortcuts();
    }
  }

  final SingleActivator? newNote;
  final SingleActivator? newFolder;
  final SingleActivator? quit;
  final SingleActivator? preferences;
  final SingleActivator? cut;
  final SingleActivator? copy;
  final SingleActivator? paste;

  /// Whether Flutter should bind these itself. False on macOS, where the OS
  /// menu bar owns them.
  final bool bindInApp;

  /// The in-app key bindings.
  ///
  /// Cut / Copy / Paste are deliberately absent even where they are displayed:
  /// Flutter's `DefaultTextEditingShortcuts` already binds them inside a
  /// focused text field on every platform, and an app-level binding would
  /// shadow that.
  Map<ShortcutActivator, Intent> get bindings {
    if (!bindInApp) return const <ShortcutActivator, Intent>{};
    return <ShortcutActivator, Intent>{
      ?newNote: const NewNoteIntent(),
      ?newFolder: const NewFolderIntent(),
      ?quit: const QuitAppIntent(),
      ?preferences: const OpenPreferencesIntent(),
    };
  }
}

/// Binds the app-level hotkeys to the published [AppCommands].
///
/// Wraps the whole app below the `MaterialApp`, so it is an ancestor of every
/// focusable widget and sees a key before the app's default bindings. An
/// unavailable command leaves its action *disabled* rather than handling the
/// key with a no-op, so the event keeps propagating instead of being silently
/// swallowed.
class AppCommandShortcuts extends StatelessWidget {
  const AppCommandShortcuts({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final commands = AppCommandsScope.of(context);
    return Shortcuts(
      shortcuts: AppShortcuts.forPlatform(Theme.of(context).platform).bindings,
      child: Actions(
        actions: <Type, Action<Intent>>{
          NewNoteIntent: _CommandAction<NewNoteIntent>(commands.newNote),
          NewFolderIntent: _CommandAction<NewFolderIntent>(commands.newFolder),
          OpenPreferencesIntent: _CommandAction<OpenPreferencesIntent>(
            commands.preferences,
          ),
          QuitAppIntent: _CommandAction<QuitAppIntent>(
            () => unawaited(requestAppQuit()),
          ),
        },
        child: child,
      ),
    );
  }
}

/// An action that runs [callback], and is disabled when there is none.
class _CommandAction<T extends Intent> extends Action<T> {
  _CommandAction(this.callback);

  final VoidCallback? callback;

  @override
  bool get isActionEnabled => callback != null;

  @override
  Object? invoke(T intent) {
    callback?.call();
    return null;
  }
}
