/// The device-local `metadata.db`: the database itself, the catalog's row
/// types, and the schema.
///
/// Callers import only this file. The implementation lives in
/// [metadata_db_io.dart](metadata_db_io.dart), which reaches `sqlite3` through
/// `dart:ffi`. The catalog's row types are exported unconditionally and are
/// pure Dart, so code that reasons about a note's merge policy or state never
/// pulls the table backing them in with it.
library;

export 'app_data_resolver.dart';
export 'catalog.dart';
export 'metadata_db_io.dart';
export 'schema.dart';
