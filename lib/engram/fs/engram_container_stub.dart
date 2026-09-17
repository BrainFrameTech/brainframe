/// Web (and any non-`dart:io`) build: there is no engram container.
///
/// Signature parity with [engram_container_io.dart](engram_container_io.dart)
/// so the conditional export in `engram_container.dart` presents one API on
/// every platform; nothing here ever returns a path.
library;

const String _unsupported =
    'Filesystem engrams are not supported on this platform.';

Future<String> applicationEngramContainerPath() =>
    throw UnsupportedError(_unsupported);

Future<String> ephemeralEngramContainerPath() =>
    throw UnsupportedError(_unsupported);
