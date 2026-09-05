/// Conditional-export seam for the device-local `metadata.db`, mirroring
/// [app_data_resolver.dart](app_data_resolver.dart): the real `dart:io` +
/// `sqlite3` implementation on native platforms, a throwing stub on web.
///
/// `crdt_lf_sqlite` rides on `dart:ffi`, which does not exist on the web, so
/// this seam is what stops a web build reaching SQLite at all. Web has no
/// filesystem engrams and serves only the read-only built-ins, which cannot
/// drift and cannot be edited — so it needs neither an op-log nor a catalog.
library;

export 'app_data_resolver.dart';
// The catalog's row types, unconditionally: they are pure Dart, so code that
// reasons about a note's merge policy or state compiles on web even though the
// table backing them cannot exist there.
export 'catalog.dart';
export 'metadata_db_stub.dart' if (dart.library.io) 'metadata_db_io.dart';
export 'schema.dart';
