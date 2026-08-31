/// Conditional-export seam for the device-local engram store's location,
/// mirroring [fs_store.dart](../fs/fs_store.dart): the real `dart:io` +
/// `path_provider` implementation on native platforms, a throwing stub on web.
///
/// Callers import only this file and get `appDataRootResolver` and
/// `engramStorePath` — plus the platform-agnostic [AppDataSource] decision —
/// resolved to the right implementation for the build.
///
/// Web has no filesystem store and only the read-only built-in engrams, so it
/// needs neither a catalog nor an op-log; `dart:ffi` does not exist there, so
/// `crdt_lf_sqlite` could not load even if it did. Keeping the location behind
/// this seam is what stops a web build reaching any of it.
library;

export 'app_data_source.dart';
export 'app_data_resolver_stub.dart'
    if (dart.library.io) 'app_data_resolver_io.dart';
