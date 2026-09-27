/// Where a filesystem engram lives on disk, and how to reach it.
///
/// This is the one *filesystem*-only concept the design keeps out of the
/// top-level model: `Engram` holds an [EngramStore], never an [EngramLocation].
/// A location is always just an absolute directory path — the app-container
/// default (resolved via `path_provider`) or a folder the user picked. How a
/// picked path is *reached* differs by platform (an Android permission, an iOS
/// or macOS security-scoped bookmark), but that lives in the registry row and
/// the `FolderAccess` seam, in front of this type: every access kind ends in a
/// path here (the sandboxed folder adoption design, Decision 1). So it is
/// deliberately a plain value with no `dart:io` dependency — it can be
/// constructed and compared by any code, including the pure layer and tests
/// that never touch a filesystem.
class EngramLocation {
  const EngramLocation(this.path);

  /// Absolute path to the engram's root directory.
  final String path;

  @override
  bool operator ==(Object other) =>
      other is EngramLocation && other.path == path;

  @override
  int get hashCode => path.hashCode;

  @override
  String toString() => 'EngramLocation($path)';
}
