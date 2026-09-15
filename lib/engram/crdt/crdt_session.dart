/// Conditional-export seam for the active engram's op-log session, mirroring
/// [metadata_db.dart](metadata_db.dart): the real `dart:io` implementation on
/// native platforms, a null-returning stub on web.
///
/// The seam exists so the UI can ask for a session without importing anything
/// that reaches SQLite. What it gets back is a [NoteWriter] — pure — so the
/// editor stays ignorant of whether an op-log is behind its saves.
library;

export 'crdt_session_stub.dart'
    if (dart.library.io) 'crdt_session_io.dart';
