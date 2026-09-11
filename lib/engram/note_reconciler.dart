/// How the app asks for a note's file to be brought back in line with its
/// history after something else changed it.
///
/// The counterpart of [NoteWriter](note_writer.dart), and a seam for the same
/// reason: the UI needs to ask for a scan on resume and for one note before it
/// opens it, and it must be able to do that without importing the `dart:io`
/// implementation that reaches SQLite. On web and in a read-only engram there
/// is nothing behind this at all, which the session expresses by publishing
/// no reconciler rather than an inert one.
library;

/// What one scan did (Decision 6).
///
/// A report rather than a boolean because the two things a caller can act on
/// are lists: the editor reloads a note that was reconciled underneath it, and
/// the housekeeping surface (step 13) will want to show what could not be.
class DriftScanReport {
  const DriftScanReport({required this.reconciled, required this.failed});

  /// A scan that found nothing to do.
  static const DriftScanReport clean = DriftScanReport(
    reconciled: <String>[],
    failed: <String, Object>{},
  );

  /// Engram-relative paths whose files had drifted and were reconciled, in
  /// scan order.
  final List<String> reconciled;

  /// Paths whose reconciliation threw, with the error, keyed by path.
  ///
  /// One note's failure never stops the scan: the others are still visited,
  /// and this note is still drifted on the next one, which will try again.
  final Map<String, Object> failed;

  /// True when the scan reconciled nothing and nothing failed.
  bool get isClean => reconciled.isEmpty && failed.isEmpty;
}

/// Reconciles files that changed outside the app into their notes' history.
///
/// **Callers flush the editor first.** Decision 6's first step — "flush the
/// editor if this note is open" — belongs to whoever holds the editor, which
/// nothing at this level does. The session host flushes every registered
/// controller before a scan; the editor pane reconciles a note before it reads
/// it, at which point that note is not the open one. A future caller that
/// reaches this from somewhere else (the filesystem watcher, **#70**) owes the
/// same courtesy, and the design says why: reconciling underneath an unsaved
/// buffer races the save.
abstract class NoteReconciler {
  /// Reconciles every drifted note in the engram.
  ///
  /// Never throws for one note's sake — per-note failures are collected into
  /// the report so a single unreadable file cannot leave the rest of the
  /// engram unreconciled. Two overlapping calls share one scan rather than
  /// racing each other.
  Future<DriftScanReport> scan();

  /// Reconciles the one note at engram-relative [path], if it has drifted.
  ///
  /// Returns true if the file had changed and was reconciled, false if it had
  /// not — or if there is nothing to reconcile it against: a path the catalog
  /// does not know (a creation, step 11's question), a file that is gone
  /// (a move or deletion, the same step's), or a note whose history has not
  /// arrived. Throws if the reconciliation itself fails.
  Future<bool> reconcile(String path);

  /// Every path that was reconciled, by either [scan] or [reconcile], as it
  /// happens. Broadcast: subscribe from anywhere, miss nothing that happens
  /// while subscribed, and expect nothing from before.
  ///
  /// This is how the editor learns that the file under its open note was
  /// rewritten — regardless of which trigger did it — so it can reload rather
  /// than save a buffer that no longer knows what is on disk.
  Stream<String> get reconciled;
}
