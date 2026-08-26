import 'dart:ui' show Size;

/// Web (and any non-`dart:io`) build: there is no desktop window to manage.
/// [startupSize] is accepted so the seam presents one API, and ignored — there
/// is no OS window to size.
Future<void> initWindowManager({Size? startupSize}) async {}

/// No-op where there is no OS window (see the io implementation).
void suspendWindowStatePersistence() {}

/// No-op where there is no OS window to close (see the io implementation).
/// Quit is only ever offered on desktop, which is never this build.
Future<void> requestAppQuit() async {}
