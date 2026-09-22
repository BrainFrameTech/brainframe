import '../engram.dart';
import '../note_reconciler.dart';
import '../note_writer.dart';

/// Web's answer: there is no session, and there never will be one.
///
/// `crdt_lf_sqlite` rides on `dart:ffi`, so a web build cannot open an op-log
/// at all. Web serves only the read-only built-in engrams, which cannot be
/// edited and cannot drift, so nothing is missing — the editor writes directly
/// and that is the whole story there, not a degraded mode.
class CrdtSession {
  const CrdtSession._();

  /// Always null on web. [trace] is accepted for signature parity with the
  /// `dart:io` implementation and never called: there is no scan to narrate.
  static Future<CrdtSession?> openFor(
    Engram engram, {
    void Function(String line)? trace,
  }) async => null;

  /// Unreachable: no session is ever created here.
  NoteWriter get writer => throw UnsupportedError('No CRDT session on web.');

  /// Unreachable, as [writer] is.
  NoteReconciler get reconciler =>
      throw UnsupportedError('No CRDT session on web.');

  /// Unreachable, and harmless to call.
  Future<void> flush() async {}

  /// Unreachable, and harmless to call.
  Future<void> close() async {}
}
