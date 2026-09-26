/// What a save asks before it writes a note's file (the filesystem watcher
/// design, Decision 5).
///
/// A seam rather than a direct call because the answer is the scan's: the
/// same stat, the same hash, the same ceiling, the same states. The writers
/// ask it; the reconciler answers, so there is one implementation of "has
/// this file changed underneath us, and what does the note hold now".
library;

import 'catalog.dart';

/// Takes in whatever changed in a note's file since this device last wrote or
/// read it, so that a save never writes over it.
abstract interface class PreSaveCheck {
  /// The largest text note the engram allows, in bytes on disk. A save that
  /// merges must not take the note past it.
  int get noteSizeCeilingBytes;

  /// Reconciles the file behind [row] into the note, **holding the note lock
  /// already** — the writer's — and returns the note's text afterwards if the
  /// file had changed, or null if it had not (or is gone, or keeps no text
  /// history to diff into).
  ///
  /// A text note's change becomes operations, as the scan would make them; a
  /// plain file's becomes one last-writer-wins claim, recorded before the
  /// save's own replaces it. Nothing is announced on the reconciler's
  /// `reconciled` stream: the saving editor learns the result from the save,
  /// and a reload triggered by the announcement would race it.
  ///
  /// Throws [StateError] when the file has grown past the ceiling: the note
  /// now awaits the user's decision (the note size ceiling design, Decision
  /// 4), and nothing may be saved over the oversized version.
  Future<String?> reconcileBeforeSave(CatalogRow row);
}
