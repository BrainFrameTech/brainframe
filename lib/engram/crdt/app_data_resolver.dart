/// The device-local engram store's location: `appDataRootResolver` and
/// `engramStorePath`, plus the platform-agnostic [AppDataSource] decision.
///
/// Callers import only this file. The implementation lives in
/// [app_data_resolver_io.dart](app_data_resolver_io.dart), which reaches
/// `dart:io` and `path_provider`; [AppDataSource] stays pure beside it so the
/// decision can be constructed and compared without them.
library;

export 'app_data_resolver_io.dart';
export 'app_data_source.dart';
