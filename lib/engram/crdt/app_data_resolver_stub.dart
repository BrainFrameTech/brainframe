/// Web (and any non-`dart:io`) build: there is no device-local engram store.
///
/// Web has no filesystem engrams to catalog, cannot load `crdt_lf_sqlite`
/// (which needs `dart:ffi`), and serves only the read-only built-in engrams —
/// which cannot drift and cannot be edited, so they need neither a catalog nor
/// an op-log. These mirror the signatures of the `dart:io` implementation so
/// the conditional export in `app_data_resolver.dart` presents one API on
/// every platform.
library;

const String _unsupported =
    'Device-local engram storage is not supported on this platform.';

/// Signature parity with the `dart:io` build; nothing here ever returns one.
typedef AppDataRootResolver = Future<String> Function();

AppDataRootResolver appDataRootResolver({
  String? overridePath,
  String? operatingSystem,
}) => throw UnsupportedError(_unsupported);

Future<String> engramStorePath(
  String engramId, {
  AppDataRootResolver? resolveRoot,
}) => throw UnsupportedError(_unsupported);
