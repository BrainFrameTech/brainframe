/// Web (and any non-`dart:io`) build: there is no device-local store to open.
///
/// `crdt_lf_sqlite` needs `dart:ffi`, which the web does not have, so the
/// op-log cannot exist here at all. These mirror the `dart:io` implementation's
/// signatures so the conditional export in `metadata_db.dart` presents one API
/// on every platform.
///
/// **Only the entry points are mirrored, and they all refuse.** The io build's
/// instance surface — `database` (a `sqlite3` connection), `crdt` (a
/// `CRDTSqlite`), `peerId`, `close()` — is deliberately absent, because on this
/// platform no instance can ever be obtained: every way in throws. The analyzer
/// resolves the seam to *this* file, so shared code that reaches for a store's
/// contents fails to compile, which is the seam doing its job rather than a gap
/// in it. Code that legitimately touches a live store is `dart:io`-only and
/// imports `metadata_db_io.dart` directly, the way `fs_store_io_test.dart`
/// already does for the filesystem store.
library;

import 'app_data_resolver.dart';

/// The failure types are shared with the `dart:io` build rather than mirrored
/// here, so a `catch` clause names one class on every platform. They are pure
/// Dart and carry no storage of their own.
export 'store_exceptions.dart';

const String _unsupported =
    'Device-local engram storage is not supported on this platform.';

abstract final class MetadataDatabase {
  static const int currentSchemaVersion = 1;

  static Future<MetadataDatabase> open(
    String engramId, {
    AppDataRootResolver? resolveRoot,
  }) => throw UnsupportedError(_unsupported);

  static MetadataDatabase openInMemory() =>
      throw UnsupportedError(_unsupported);
}

Future<void> relocateEngramStore({
  required String fromEngramId,
  required String toEngramId,
  AppDataRootResolver? resolveRoot,
}) => throw UnsupportedError(_unsupported);
