import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'app_data_source.dart';
import 'engram_store_location_io.dart' as location;

// The typedef lives with the platform-agnostic decisions; re-exported here
// because this file is where a caller reaching for the resolver looks.
export 'app_data_source.dart' show AppDataRootResolver;

/// Picks where this device's app-owned engram data lives.
///
/// This lives in its own unit, rather than inline at the call site in
/// `main.dart`, for the same reason
/// [container_resolver.dart](../container_resolver.dart) does: `main.dart` is
/// excluded from the coverage gate as untestable bootstrap, and a resolver
/// that silently picks the wrong directory does not fail — it opens an empty
/// engram.
///
/// **This is the one function in the store's world that touches
/// `path_provider`**, and this file is the only one that imports it. The
/// directory work — [engramStorePath], [recordEngramPath],
/// [deleteEngramStore] — lives in
/// [engram_store_location_io.dart](engram_store_location_io.dart), which
/// takes the resolver as an argument; the wrappers below supply this
/// function as the default, so a caller at the app's edge may omit it, while
/// the store underneath never depends on it and stays compilable by plain
/// `dart`.
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
    AppDataSource.applicationSupport =>
      () async => (await getApplicationSupportDirectory()).path,
    AppDataSource.applicationCache =>
      () async => (await getApplicationCacheDirectory()).path,
  };
}

/// [location.engramStorePath], with this platform's root when [resolveRoot]
/// is omitted.
Future<String> engramStorePath(
  String engramId, {
  AppDataRootResolver? resolveRoot,
}) => location.engramStorePath(
  engramId,
  resolveRoot: resolveRoot ?? appDataRootResolver(),
);

/// [location.recordEngramPath], with this platform's root when [resolveRoot]
/// is omitted.
Future<void> recordEngramPath(
  String engramId,
  String folderPath, {
  AppDataRootResolver? resolveRoot,
}) => location.recordEngramPath(
  engramId,
  folderPath,
  resolveRoot: resolveRoot ?? appDataRootResolver(),
);

/// [location.deleteEngramStore], with this platform's root when [resolveRoot]
/// is omitted.
Future<bool> deleteEngramStore(
  String engramId, {
  AppDataRootResolver? resolveRoot,
}) => location.deleteEngramStore(
  engramId,
  resolveRoot: resolveRoot ?? appDataRootResolver(),
);
