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
    this.selectAll,
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
          selectAll: SingleActivator(LogicalKeyboardKey.keyA, control: true),
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
          selectAll: SingleActivator(LogicalKeyboardKey.keyA, meta: true),
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
  final SingleActivator? selectAll;

  /// Whether Flutter should bind these itself. False on macOS, where the OS
  /// menu bar owns them.
  final bool bindInApp;

  // Hoisted out of [bindings] deliberately, to work around a compiler bug.
  //
  // Written inline as `?newNote: const NewNoteIntent()` — a null-aware map
  // entry whose value is a *const constructor invocation* — these crash the AOT
  // compiler. The CFE's constant evaluator throws "Null check operator used on
  // a null value" in `_recordConstructorCoverage`, which fails
  // `kernel_snapshot_program` and leaves `flutter build linux --release`
  // reporting only its generic "Build process failed". The real message is
  // ~180 lines into `--verbose`, so this is expensive to diagnose twice.
  //
  // Debug never evaluates constants this way (`--aot --tfa -Ddart.vm.product`
  // is release-only), so `flutter run` and `flutter test` stay perfectly happy
  // while release is broken — do not take a green test suite as evidence here.
  //
  // Referencing a const *variable* rather than invoking a const constructor in
  // place sidesteps it, and these stay canonicalized exactly as before. Keeping
  // the null-aware `?` entries is fine; it is only the inline `const` call in
  // that position that trips it. Flutter 3.44.8 / Dart 3.12.2.
  static const _newNote = NewNoteIntent();
  static const _newFolder = NewFolderIntent();
  static const _quit = QuitAppIntent();
  static const _preferences = OpenPreferencesIntent();

  /// The in-app key bindings.
  ///
  /// Cut / Copy / Paste / Select all are deliberately absent even where they
  /// are displayed: Flutter's `DefaultTextEditingShortcuts` already binds them
  /// inside a focused text field on every platform, and an app-level binding
  /// would shadow that.
  Map<ShortcutActivator, Intent> get bindings {
    if (!bindInApp) return const <ShortcutActivator, Intent>{};
    return <ShortcutActivator, Intent>{
      ?newNote: _newNote,
      ?newFolder: _newFolder,
      ?quit: _quit,
      ?preferences: _preferences,
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
