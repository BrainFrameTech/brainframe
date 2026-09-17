/// Conditional-export seam for the default engram containers, mirroring
/// [fs_store.dart](fs_store.dart): the real `dart:io` + `path_provider`
/// implementation on native platforms, a throwing stub on web.
///
/// Callers import only this file and get `applicationEngramContainerPath`
/// and `ephemeralEngramContainerPath`, resolved to the right implementation
/// for the build. Kept apart from the store seam so the store never imports
/// a Flutter plugin.
library;

export 'engram_container_stub.dart'
    if (dart.library.io) 'engram_container_io.dart';
