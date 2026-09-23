/// The filesystem engram store: `createFileSystemEngram`,
/// `openFileSystemEngram`, and the rest of the store, plus the
/// platform-agnostic [EngramLocation] value type and folder-adoption preview.
///
/// Callers import only this file. The implementation lives in
/// [fs_store_io.dart](fs_store_io.dart), which reaches `dart:io` directly; the
/// value types beside it stay pure so code that only reasons about a location
/// never pulls the filesystem in with it.
///
/// The default *containers* engrams live in are behind
/// [engram_container.dart](engram_container.dart) instead, the one place in
/// this layer that touches `path_provider`.
library;

export 'engram_location.dart';
export 'folder_preview.dart';
export 'fs_store_io.dart';
