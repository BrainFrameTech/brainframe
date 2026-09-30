/// How Housekeeping's Recent scans folds back-to-back routine changes into
/// one card (the filesystem watcher design, Decision 10).
///
/// Every change made outside the app is recorded — the watcher's, and a
/// note's own check before it opens or saves — so a note edited in another
/// editor beside the app leaves a record per save. Listed one by one they
/// bury everything else, and they read alike, so dismissing one looks like
/// dismissing nothing. Folded, an editing session is one card.
///
/// Pure, and incremental: the reader feeds records newest first, a page at a
/// time, and stops once enough cards are closed. What a card accumulates is
/// its records' ids and each changed path once — bounded by the notes in the
/// engram, however long the run.
library;

import 'note_reconciler.dart';

/// The longest quiet between two records that still folds them: from one
/// finishing to the next one starting. A named constant beside the rule, like
/// the watcher's batch timings, so tuning it is a one-line change.
const Duration scanFoldGap = Duration(minutes: 5);

/// One recorded scan as the folder needs it.
typedef ScannedRecord = ({
  int id,
  DateTime startedAt,
  DateTime finishedAt,
  ScanTrigger trigger,
  DriftScanReport report,
});

/// Whether [record] may fold with its neighbours: found while the engram was
/// open, and routine.
///
/// **Routine is an allow-list** — notes updated, created, adopted, moved, or
/// deleted, in a folder listed in full. Anything else deserves a card of its
/// own and is never folded away: a history lost to a rename past
/// recognition, a failure, an unlisted folder, and everything the note size
/// ceiling does. A kind added to the report later stands alone until it is
/// added here on purpose.
bool isFoldable(ScannedRecord record) {
  if (record.trigger != ScanTrigger.watcher &&
      record.trigger != ScanTrigger.note) {
    return false;
  }
  final report = record.report;
  final lostHistory = report.tombstoned.isNotEmpty && report.created.isNotEmpty;
  return !lostHistory &&
      report.complete &&
      report.failed.isEmpty &&
      report.oversized.isEmpty &&
      report.converted.isEmpty &&
      report.convertedElsewhere.isEmpty &&
      report.awaitingDecision.isEmpty &&
      report.reconstructed.isEmpty &&
      report.retired.isEmpty;
}

/// Folds records fed newest first into [ScanNotice] cards.
class ScanFolder {
  ScanFolder({this.gap = scanFoldGap});

  /// The longest quiet that still folds; [scanFoldGap] unless a test says
  /// otherwise.
  final Duration gap;

  final List<ScanNotice> _closed = [];
  _Run? _open;

  /// Cards no later record can change, newest first.
  List<ScanNotice> get closed => List.unmodifiable(_closed);

  /// Takes the next record, which must be older than every one before it.
  void add(ScannedRecord record) {
    final open = _open;
    if (open != null && open.takes(record, gap)) {
      open.add(record);
      return;
    }
    _close();
    _open = _Run(record);
  }

  /// Every card, the last one included: call once the records run out.
  List<ScanNotice> finish() {
    _close();
    return closed;
  }

  void _close() {
    final open = _open;
    if (open == null) return;
    _closed.add(open.notice());
    _open = null;
  }
}

/// A run being folded: the newest record first, then older ones.
class _Run {
  _Run(ScannedRecord newest)
    : _newest = newest,
      _oldest = newest,
      _foldable = isFoldable(newest),
      _watcher = newest.trigger == ScanTrigger.watcher {
    _union(newest.report);
  }

  final ScannedRecord _newest;
  ScannedRecord _oldest;
  final bool _foldable;
  bool _watcher;
  final List<int> _folded = [];

  // Insertion-ordered, so paths read newest first; a set, so each path is
  // counted once however many records name it.
  final Set<String> _reconciled = {};
  final Set<String> _created = {};
  final Set<String> _adopted = {};
  final Set<String> _tombstoned = {};
  final Map<String, String> _moved = {};

  /// Whether [record], the next older one, joins this run: both foldable,
  /// and no more than [gap] between it finishing and this run's oldest
  /// starting.
  bool takes(ScannedRecord record, Duration gap) =>
      _foldable &&
      isFoldable(record) &&
      _oldest.startedAt.difference(record.finishedAt) <= gap;

  void add(ScannedRecord record) {
    _folded.add(record.id);
    _oldest = record;
    _watcher |= record.trigger == ScanTrigger.watcher;
    _union(record.report);
  }

  void _union(DriftScanReport report) {
    _reconciled.addAll(report.reconciled);
    _created.addAll(report.created);
    _adopted.addAll(report.adopted);
    _tombstoned.addAll(report.tombstoned);
    for (final move in report.moved.entries) {
      _moved.putIfAbsent(move.key, () => move.value);
    }
  }

  ScanNotice notice() {
    if (_folded.isEmpty) {
      return ScanNotice(
        id: _newest.id,
        at: _newest.finishedAt,
        trigger: _newest.trigger,
        report: _newest.report,
      );
    }
    return ScanNotice(
      id: _newest.id,
      at: _newest.finishedAt,
      since: _oldest.finishedAt,
      folded: List.unmodifiable(_folded),
      trigger: _watcher ? ScanTrigger.watcher : ScanTrigger.note,
      report: DriftScanReport(
        reconciled: List.unmodifiable(_reconciled),
        created: List.unmodifiable(_created),
        adopted: List.unmodifiable(_adopted),
        tombstoned: List.unmodifiable(_tombstoned),
        moved: Map.unmodifiable(_moved),
      ),
    );
  }
}
