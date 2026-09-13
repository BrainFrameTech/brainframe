import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../id.dart';
import 'app_data_source.dart';

/// Resolves the root directory holding every engram's device-local store.
///
/// A function rather than a value so the choice can be made once at startup
/// and injected, the way `engramContainerResolver` already is.
typedef AppDataRootResolver = Future<String> Function();

/// Picks where this device's app-owned engram data lives.
///
/// This lives in its own unit, rather than inline at the call site in
/// `main.dart`, for the same reason
/// [container_resolver.dart](../container_resolver.dart) does: `main.dart` is
/// excluded from the coverage gate as untestable bootstrap, and a resolver
/// that silently picks the wrong directory does not fail — it opens an empty
/// engram.
///
/// [overridePath] short-circuits platform resolution entirely and is the
/// Raspberry Pi's case: its library is expected to live on a separate mounted
/// volume whose path comes from configuration, which `path_provider` cannot
/// report. Nothing supplies one yet; the parameter is the seam that case will
/// arrive through.
///
/// [operatingSystem] defaults to this process's platform and exists so tests
/// can exercise every row of [appDataSourceFor] on one host.
///
/// The returned path is **not** created; the caller that opens a database
/// there creates it.
AppDataRootResolver appDataRootResolver({
  String? overridePath,
  String? operatingSystem,
}) {
  if (overridePath != null) {
    return () async => overridePath;
  }
  return switch (appDataSourceFor(
    operatingSystem ?? Platform.operatingSystem,
  )) {
    AppDataSource.applicationSupport => () async =>
      (await getApplicationSupportDirectory()).path,
    AppDataSource.applicationCache => () async =>
      (await getApplicationCacheDirectory()).path,
  };
}

/// The directory holding the engram [engramId]'s device-local store —
/// `<app data root>/engrams/<engram ULID>/`, where `metadata.db` goes.
///
/// **The engram ULID names the directory and appears nowhere inside the
/// database.** That is what makes a changed engram ULID — which a future sync
/// election can produce, since two devices that adopt one folder before
/// syncing each mint their own — a directory rename and nothing more: every
/// byte inside is already correct. Nothing should later key a table on it.
///
/// Throws [ArgumentError] unless [engramId] is a canonical ULID, so a display
/// name or a relative path can never become a directory component here.
Future<String> engramStorePath(
  String engramId, {
  AppDataRootResolver? resolveRoot,
}) async {
  if (!isCanonicalUlid(engramId)) {
    throw ArgumentError.value(
      engramId,
      'engramId',
      'must be a canonical ULID',
    );
  }
  final root = await (resolveRoot ?? appDataRootResolver())();
  return '$root/$engramsDirectoryName/$engramId';
}

/// Deletes the engram [engramId]'s device-local store directory — `metadata.db`
/// and anything beside it — and returns whether there was one to delete.
///
/// Absence is success, not failure: a store that was never opened on this
/// device, or one already removed by an earlier attempt, both leave nothing
/// to do. The other half of a clean-up, the marker directory inside the
/// folder, lives behind the filesystem store seam.
///
/// The directory is resolved through [engramStorePath], so the same ULID check
/// guards it: nothing but a canonical engram ULID can name what is deleted
/// here. **Never call this for an open engram:** its `metadata.db` is a live
/// SQLite connection, which on Windows refuses the delete and everywhere else
/// leaves the session writing into an unlinked file.
Future<bool> deleteEngramStore(
  String engramId, {
  AppDataRootResolver? resolveRoot,
}) async {
  final directory = Directory(
    await engramStorePath(engramId, resolveRoot: resolveRoot),
  );
  if (!await directory.exists()) return false;
  await directory.delete(recursive: true);
  return true;
}
