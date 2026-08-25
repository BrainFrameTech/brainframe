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

/// Opens the find bar for the document on screen.
class FindInPageIntent extends Intent {
  const FindInPageIntent();
}

/// The app-wide commands the desktop menu bar and its hotkeys invoke.
///
/// The menu bar lives above the [Navigator] (so it stays put across routes and
/// under dialogs), which puts it out of reach of the screens that actually
/// perform these actions. This is the seam between them: the engram browser
/// publishes what it can currently do (and the open document pane publishes
/// [find]), and the menu bar renders each item enabled or greyed accordingly. A command is null when it is unavailable —
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

  VoidCallback? _find;

  VoidCallback? get newNote => _newNote;
  VoidCallback? get newFolder => _newFolder;
  VoidCallback? get preferences => _preferences;
  VoidCallback? get help => _help;
  VoidCallback? get about => _about;

  /// Opens find-in-page for the document on screen, or null when nothing on
  /// screen can be searched (no file open, a format with no text, or a viewer
  /// that has no find of its own).
  VoidCallback? get find => _find;

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

  /// Publishes find-in-page, or null when it is unavailable.
  ///
  /// A channel of its own because it has a different owner: Find belongs to the
  /// document pane on screen, which mounts and unmounts independently of the
  /// browser that publishes everything else. [publish] therefore leaves it
  /// alone, and this leaves [publish]'s commands alone.
  void publishFind(VoidCallback? find) {
    final changed = (_find == null) != (find == null);
    _find = find;
    if (changed && !_disposed) notifyListeners();
  }

  /// Withdraws every command published by [publish] — used when that publisher
  /// unmounts, so the menu never holds a callback into a dead widget. Find has
  /// its own owner, and therefore its own [withdrawFind].
  void withdraw() => publish();

  /// Withdraws the find command [owner] published, used when that document
  /// pane unmounts.
  ///
  /// It is a no-op if something else has published a different one since:
  /// Flutter mounts a replacement *before* unmounting what it replaced, so a
  /// pane handing over to the next one would otherwise withdraw the incoming
  /// pane's Find rather than its own.
  void withdrawFind(VoidCallback owner) {
    if (_find == owner) publishFind(null);
  }

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
