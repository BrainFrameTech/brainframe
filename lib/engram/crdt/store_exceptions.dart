/// The device-local store's failure types, shared by every platform build.
///
/// Pure Dart on purpose. Both `metadata_db_io.dart` and `metadata_db_stub.dart`
/// re-export these, so the seam presents the *same* classes everywhere rather
/// than two look-alikes that a `catch` clause would distinguish. Keeping them
/// here also lets `catalog_io.dart` raise them without importing the file that
/// imports it.
library;

/// Thrown when the device-local store cannot be opened or read into a usable
/// state.
///
/// Strict by design, the way `EngramMetadata` is: a database written by a newer
/// build, or holding a value we cannot make sense of, raises rather than being
/// half-read. Recovery is cheap and documented — deleting `metadata.db` costs
/// history, never content and never identity — so failing loudly beats
/// operating on a schema we do not understand.
class MetadataDatabaseException implements Exception {
  const MetadataDatabaseException(this.message);

  final String message;

  @override
  String toString() => 'MetadataDatabaseException: $message';
}

/// Thrown when relocating a store would overwrite one that already exists.
///
/// This device holds two stores for what is now one engram, which means it
/// adopted the same folder twice locally. Surfaced rather than resolved: a
/// silent merge would interleave two op-logs, and a silent clobber would
/// discard one wholesale.
class EngramStoreCollisionException implements Exception {
  const EngramStoreCollisionException(this.path);

  /// The occupied destination directory.
  final String path;

  @override
  String toString() =>
      'EngramStoreCollisionException: a store already exists at $path';
}
