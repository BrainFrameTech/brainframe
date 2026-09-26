/// How the editor's buffer reaches storage.
///
/// One seam with two implementations, because Decision 4 inverts the save path
/// for notes the CRDT owns while leaving it alone everywhere else. Keeping it
/// an interface — rather than a flag inside the controller — is what lets the
/// editor stay ignorant of whether an engram has an op-log behind it, and lets
/// the CRDT implementation live in a `dart:io`-only file the UI never imports.
library;

import 'crdt/line_terminators.dart';
import 'engram_store.dart';
import 'text_merge.dart';

/// Writes a note's full text to wherever that note lives.
///
/// The editor holds a buffer, so what it has to offer is always a whole
/// document rather than a stream of edits. Turning that into something smaller
/// is the implementation's problem, not the caller's.
///
/// **Nothing is written over a change the writer has not taken in** (the
/// filesystem watcher design, Decision 5). Every implementation looks at the
/// file before it writes. A file changed on disk since this device last wrote
/// or read it — another editor, a sync client, a script — is not simply
/// overwritten.
abstract class NoteWriter {
  /// Persists [text] as the content of the note at engram-relative [path], and
  /// returns what the note now holds.
  ///
  /// [base] is the text [text] grew from — what the editor last loaded or
  /// saved. When the file has changed since, the change is taken in first,
  /// and then:
  ///
  /// - **with a [base]**, [text] is merged with it three ways
  ///   ([threeWayMerge]) and the merge is what is saved and returned, so
  ///   neither the external edit nor the typing is lost;
  /// - **without one**, [text] is saved over it as the caller's word. Where
  ///   the note keeps a history, the external edit is in it all the same.
  ///
  /// In the ordinary case — the file as this device left it — the result is
  /// [text], exactly.
  ///
  /// Completes when the write is durable. Throws on failure, which the
  /// controller surfaces as [SaveStatus.error] and retries on the next flush;
  /// throws [NoteMergeOverLimitException] when a merge would take the note
  /// past its size ceiling.
  Future<String> write(String path, String text, {String? base});
}

/// A save that found the file changed underneath it, took the change in, and
/// then merged a text too large for the note to hold (the note size ceiling
/// design, Decision 1): nothing of the merge was written.
///
/// Nothing is lost either. The external edit is already what the note holds —
/// [onDisk] — and [merged] is the typing merged over it, for the editor to
/// hold as its buffer, over the limit, as though the user had typed it there.
class NoteMergeOverLimitException implements Exception {
  const NoteMergeOverLimitException({
    required this.path,
    required this.merged,
    required this.onDisk,
  });

  /// Engram-relative.
  final String path;

  /// The typing merged over the external edit — over the ceiling, unsaved.
  final String merged;

  /// What the note holds now: the external edit, taken in.
  final String onDisk;

  @override
  String toString() =>
      'NoteMergeOverLimitException: merging into $path would pass its size '
      'ceiling; nothing was written';
}

/// Writes the buffer straight to the store, the way notes were written before
/// the CRDT existed.
///
/// Still the correct writer in three cases, none of them a fallback in the
/// apologetic sense: a read-only engram, an engram with no op-log at all, and
/// Decision 4's bounded exception — a history-pending note, whose op-log has
/// not arrived, so there is no document to project from.
///
/// It keeps no history, so its check before writing is the file's text against
/// [base]: a file that differs is merged three ways, and the merge is written.
/// No ceiling applies here — there is no CRDT to protect — and the merge's
/// diff is the bounded one, so a large file costs time, not memory.
class DirectNoteWriter implements NoteWriter {
  const DirectNoteWriter(this.store);

  final EngramStore store;

  @override
  Future<String> write(String path, String text, {String? base}) async {
    var result = text;
    if (base != null) {
      final onDisk = await _readIfPresent(path);
      if (onDisk != null &&
          normalizeTerminators(onDisk) != normalizeTerminators(base)) {
        result = threeWayMerge(base: base, mine: text, theirs: onDisk);
      }
    }
    await store.writeString(path, result);
    return result;
  }

  /// The file's text, or null when there is none to merge with — a new file,
  /// or one this store cannot read, which is nothing a merge could use.
  Future<String?> _readIfPresent(String path) async {
    try {
      return await store.readString(path);
    } on Exception {
      return null;
    }
  }
}
