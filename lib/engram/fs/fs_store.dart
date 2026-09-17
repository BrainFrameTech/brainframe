/// Conditional-export seam for the filesystem engram store, mirroring
/// [lib/window/window_state.dart](../../window/window_state.dart): the real
/// `dart:io` implementation on native platforms, a throwing stub on web.
///
/// Callers import only this file and get `createFileSystemEngram`,
/// `openFileSystemEngram`, and the rest of the store — plus the
/// platform-agnostic [EngramLocation] value type — resolved to the right
/// implementation for the build. The default *containers* engrams live in
/// are behind [engram_container.dart](engram_container.dart) instead, the
/// one place in this layer that touches `path_provider`.
library;

export 'engram_location.dart';
export 'folder_preview.dart';
export 'fs_store_stub.dart' if (dart.library.io) 'fs_store_io.dart';
