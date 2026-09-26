/// How a folder outside the app's container is chosen and reached again —
/// the seam between the platform's folder chooser and the plain paths the
/// filesystem store works in (the sandboxed folder adoption design,
/// Decision 2).
///
/// Every platform ends in an absolute path that `dart:io` can read and write
/// (Decision 1). What differs is how that path is obtained: on Linux and
/// Windows a dialog returns it and it stays good, while Android needs a
/// permission before it can be used and iOS and macOS must turn a stored
/// bookmark back into it at each launch. A [FolderAccess] hides which, so the
/// repository resolves every registry row the same way.
///
/// Pure Dart, like [EngramLocation]: implementations that reach a platform
/// live elsewhere, so the repository and its tests can depend on this file
/// without one.
library;

/// Why a registered engram cannot be reached (Decision 6).
enum UnreachableReason {
  /// The folder is gone, unreadable, or no longer an engram.
  missing,

  /// The app lacks the permission it needs to look at folders outside its
  /// container (Android, when All files access has been revoked). The folder
  /// may well be there; granting access fixes it.
  accessNeeded,

  /// The stored bookmark no longer resolves to a folder (iOS, macOS). Adopting
  /// the folder again fixes it, keeping its identity.
  bookmarkInvalid,
}

/// A folder the user chose: its path, and — on the platforms that need one to
/// reach it again — an opaque bookmark to store beside it.
class PickedFolder {
  const PickedFolder(this.path, {this.bookmark});

  /// Absolute path to the folder, usable now.
  final String path;

  /// Opaque, platform-defined token that reaches the folder in a later launch,
  /// or null where the path alone is enough. Never parsed in Dart.
  final String? bookmark;
}

/// A registry row turned back into a usable folder.
class ResolvedFolder {
  const ResolvedFolder(this.path, {this.refreshedBookmark});

  /// Absolute path to the folder now — which may differ from the path stored
  /// with the bookmark, if the folder moved.
  final String path;

  /// A replacement for a bookmark the platform reported stale, to be written
  /// back to the row; null when the stored one is still good.
  final String? refreshedBookmark;
}

/// A folder that could not be resolved, and why.
class FolderAccessException implements Exception {
  const FolderAccessException(this.reason, [this.message]);

  /// Never [UnreachableReason.missing]: a folder that is simply not there is
  /// found out by opening it, not by resolving it.
  final UnreachableReason reason;

  /// The platform's own words, kept for the log: [reason] folds several
  /// native failures into one, and this is what tells them apart afterwards.
  ///
  /// It is untranslated and reaches [toString], so UI must not show this
  /// exception's text — present [reason] as a localized sentence instead.
  final String? message;

  @override
  String toString() =>
      'FolderAccessException(${reason.name}${message == null ? '' : ': $message'})';
}

/// Chooses folders and reaches them again.
abstract class FolderAccess {
  const FolderAccess();

  /// Whether this platform can show a folder chooser at all. "Open folder…"
  /// is offered only where this is true.
  bool get canPick;

  /// Shows the platform's folder chooser; null if the user cancels.
  Future<PickedFolder?> pick();

  /// Turns a stored row — its last known [path] and, if it has one, its
  /// [bookmark] — into a folder usable now, starting access if the platform
  /// needs it.
  ///
  /// Throws [FolderAccessException] when the platform cannot reach the folder;
  /// does not check that the folder exists, which opening it will.
  Future<ResolvedFolder> resolve({required String path, String? bookmark});

  /// Whether the app may reach folders outside its container right now. True
  /// wherever no such permission exists.
  Future<bool> get hasBroadAccess;

  /// Asks for the access [hasBroadAccess] reports, returning whether the app
  /// has it afterwards. True at once wherever no such permission exists.
  Future<bool> requestBroadAccess();
}
