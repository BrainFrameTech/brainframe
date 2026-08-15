import 'package:flutter/widgets.dart';

/// Creates a new note in the browser's current target folder.
class NewNoteIntent extends Intent {
  const NewNoteIntent();
}

/// Creates a new folder in the browser's current target folder.
class NewFolderIntent extends Intent {
  const NewFolderIntent();
}

/// Saves any pending edits and closes the app.
class QuitAppIntent extends Intent {
  const QuitAppIntent();
}

/// Opens the Settings screen.
class OpenPreferencesIntent extends Intent {
  const OpenPreferencesIntent();
}

/// The app-wide commands the desktop menu bar and its hotkeys invoke.
///
/// The menu bar lives above the [Navigator] (so it stays put across routes and
/// under dialogs), which puts it out of reach of the screens that actually
/// perform these actions. This is the seam between them: the engram browser
/// publishes what it can currently do, and the menu bar renders each item
/// enabled or greyed accordingly. A command is null when it is unavailable —
/// before the browser has mounted, or for a read-only engram, which cannot be
/// written to at all.
class AppCommands extends ChangeNotifier {
  /// Set once [dispose] has run. A publisher is a *descendant* of the widget
  /// that owns this, and Flutter disposes a parent's state before unmounting
  /// its children — so the browser's withdraw-on-dispose legitimately arrives
  /// after ours. Accept it quietly rather than notifying a dead notifier.
  bool _disposed = false;

  VoidCallback? _newNote;
  VoidCallback? _newFolder;
  VoidCallback? _preferences;
  VoidCallback? _help;
  VoidCallback? _about;

  VoidCallback? get newNote => _newNote;
  VoidCallback? get newFolder => _newFolder;
  VoidCallback? get preferences => _preferences;
  VoidCallback? get help => _help;
  VoidCallback? get about => _about;

  /// Publishes the browser's commands, passing null for each one that is not
  /// available right now.
  ///
  /// Listeners are notified only when a command's *availability* changes, not
  /// when a still-available callback is replaced by an equivalent one: the
  /// publisher re-registers on every dependency change, and a rebuild per
  /// re-registration would be pure churn. (Tear-offs of the same method on the
  /// same object compare equal in Dart, so this is a cheap identity test.)
  void publish({
    VoidCallback? newNote,
    VoidCallback? newFolder,
    VoidCallback? preferences,
    VoidCallback? help,
    VoidCallback? about,
  }) {
    final changed =
        (_newNote == null) != (newNote == null) ||
        (_newFolder == null) != (newFolder == null) ||
        (_preferences == null) != (preferences == null) ||
        (_help == null) != (help == null) ||
        (_about == null) != (about == null);
    _newNote = newNote;
    _newFolder = newFolder;
    _preferences = preferences;
    _help = help;
    _about = about;
    if (changed && !_disposed) notifyListeners();
  }

  /// Withdraws every command — used when the publisher unmounts, so the menu
  /// never holds a callback into a dead widget.
  void withdraw() => publish();

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

/// Makes the [AppCommands] instance available to the menu bar, the app-level
/// shortcuts, and the screens that publish into it.
///
/// Sits above the `MaterialApp` (like `RepositoryScope`) so both the menu bar —
/// which is built outside the [Navigator] — and the routes inside it can reach
/// the same instance.
class AppCommandsScope extends InheritedNotifier<AppCommands> {
  const AppCommandsScope({
    super.key,
    required AppCommands commands,
    required super.child,
  }) : super(notifier: commands);

  /// The commands, rebuilding the caller when a command's availability changes.
  static AppCommands of(BuildContext context) {
    final scope = context
        .dependOnInheritedWidgetOfExactType<AppCommandsScope>();
    assert(scope != null, 'No AppCommandsScope found in context');
    return scope!.notifier!;
  }

  /// The commands without subscribing to changes, or null when there is no
  /// scope — the shape a publisher wants, since it only ever writes.
  static AppCommands? maybeOf(BuildContext context) => context
      .getInheritedWidgetOfExactType<AppCommandsScope>()
      ?.notifier;
}
