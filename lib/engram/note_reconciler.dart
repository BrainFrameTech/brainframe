/// How the app asks for the catalog to be brought back in line with the
/// folder after something else changed it — the content of a file, or the
/// set of files.
///
/// The counterpart of [NoteWriter](note_writer.dart), and a seam for the same
/// reason: the UI needs to ask for a scan on resume and for one note before it
/// opens it, and it must be able to do that without importing the `dart:io`
/// implementation that reaches SQLite. On web and in a read-only engram there
/// is nothing behind this at all, which the session expresses by publishing
/// no reconciler rather than an inert one.
library;

/// What one scan did (Decisions 6 and 7).
///
/// A report rather than a boolean because the things a caller can act on are
/// lists: the editor reloads a note that was reconciled underneath it, and the
/// housekeeping surface (step 13) will want to show the rest — above all the
/// deletions, because a note that went missing and came back as something not
/// similar enough is a delete plus a create, and the history that just went
/// with it is a cost Decision 7 requires to be visible rather than silent.
class DriftScanReport {
  const DriftScanReport({
    this.reconciled = const <String>[],
    this.failed = const <String, Object>{},
    this.created = const <String>[],
    this.adopted = const <String>[],
    this.moved = const <String, String>{},
    this.tombstoned = const <String>[],
    this.retired = const <String>[],
    this.listingFailure,
  });

  /// A scan that found nothing to do.
  static const DriftScanReport clean = DriftScanReport();

  /// Engram-relative paths whose files had drifted and were reconciled, in
  /// scan order. A note re-associated by similarity and then reconciled
  /// appears here as well as in [moved].
  final List<String> reconciled;

  /// Paths whose reconciliation threw, with the error, keyed by path.
  ///
  /// One note's failure never stops the scan: the others are still visited,
  /// and this note is still drifted on the next one, which will try again.
  final Map<String, Object> failed;

  /// Paths this device minted a new note for: a file no catalog row and no
  /// identity-map row claimed, seeded from its own text.
  final List<String> created;

  /// Paths adopted from another device's identity map: the ULID is recorded
  /// and **nothing is seeded** — the note is history-pending until its op-log
  /// arrives. Also a note of our own recovered from our own map after the
  /// local database was lost.
  final List<String> adopted;

  /// Notes found at a new path, old path → new path. Exact matches by content
  /// hash, and near matches by the content sketch — the latter also reconciled
  /// as drift, and therefore also in [reconciled].
  final Map<String, String> moved;

  /// Paths whose note was tombstoned: gone from the folder, the scan known
  /// complete, and no new file matched it. **This is the surfaced cost.** A
  /// path here alongside one in [created] may well have been one note renamed
  /// and rewritten past the point of recognition; its history stayed with the
  /// tombstone.
  final List<String> tombstoned;

  /// Paths whose local note lost an identity election to another device's
  /// and was retired: the winning ULID was adopted as history-pending, and
  /// this device's own document for the path was tombstoned. Content survives
  /// on disk exactly once; the local history — in the case this mostly
  /// serves, a single seed — does not.
  final List<String> retired;

  /// Set when the folder could not be enumerated, in which case the scan did
  /// only what it could without a listing: drift on the notes it already
  /// knew. Nothing was created, moved, or tombstoned — a scan that cannot see
  /// the folder must not conclude anything about what is absent from it.
  final Object? listingFailure;

  /// Whether the folder was enumerated in full, which is the precondition for
  /// every deletion and every creation above.
  bool get complete => listingFailure == null;

  /// True when the scan changed nothing and nothing failed.
  bool get isClean =>
      reconciled.isEmpty &&
      failed.isEmpty &&
      created.isEmpty &&
      adopted.isEmpty &&
      moved.isEmpty &&
      tombstoned.isEmpty &&
      retired.isEmpty &&
      listingFailure == null;
}

/// How far a scan has got through bringing new files into the catalog.
///
/// Reported only for the expensive part of a scan — minting or adopting files
/// the catalog has never seen, which is adoption whether the folder was picked
/// a moment ago or has been an engram since before the catalog existed. The
/// drift half of a scan is a stat per note and reports nothing: a bar that
/// flashed on every resume would be noise, and on e-ink a repaint for nothing.
class AdoptionProgress {
  const AdoptionProgress({required this.done, required this.total});

  /// Files brought in so far, including ones found already present.
  final int done;

  /// Files the scan set out to bring in.
  final int total;

  /// Whether there is still work to show.
  bool get isRunning => done < total;

  @override
  bool operator ==(Object other) =>
      other is AdoptionProgress && other.done == done && other.total == total;

  @override
  int get hashCode => Object.hash(done, total);

  @override
  String toString() => 'AdoptionProgress($done of $total)';
}

/// What this device knows about the notes in an engram, for the Housekeeping
/// panel — Decision 9's promise, paid out here instead of as a prompt on open.
///
/// Minting is reversible, most users cannot answer "is this engram from
/// another machine?", and refusing to open until an unbuilt transport reached
/// an unreachable peer would trade a possible history loss for a certain
/// outage. So the app never asks; it reads the shared map, adopts what it
/// finds, and shows the result here. Before **#67** exists, [adopted] is
/// exactly the set of notes with no local history, and this is the only place
/// that state is visible at all.
class NoteLedger {
  const NoteLedger({
    required this.peers,
    required this.minted,
    required this.adopted,
    required this.unclaimed,
    required this.tombstoned,
    this.lastScanAt,
  });

  /// Devices that have written to this engram's shared map, this one
  /// included — one file each under `.brainframe/shared/`.
  final int peers;

  /// Notes this device seeded: minted here, so their whole history is here.
  final int minted;

  /// Notes whose identity was adopted from another device's map and whose
  /// history has not arrived: readable and editable as ordinary files, with
  /// no document behind them until a log lands.
  final int adopted;

  /// Of [adopted], those whose seed nobody has claimed anywhere — the map
  /// outlived every op-log that ever backed them.
  final int unclaimed;

  /// Notes this device remembers as deleted: the tombstones, kept so a later
  /// file at the same path is a new note and not the dead one resurrected.
  final int tombstoned;

  /// When the last scan finished — clean or not — or null if none has run on
  /// this device. Clean scans leave only this behind.
  final DateTime? lastScanAt;
}

/// What started a scan. Recorded with it, so a notice can say whether the
/// change was found at launch, on coming back to the window, or by a watcher.
enum ScanTrigger {
  /// The session opened: app start, or an engram switch.
  open,

  /// The app came back to the foreground.
  resume,

  /// The filesystem watcher (**#70**), once it exists.
  watcher,

  /// Anything else — a test, a future button.
  manual;

  /// Parses the stored spelling, the enum's own name; throws
  /// [FormatException] for anything else.
  static ScanTrigger parse(String value) => values.firstWhere(
    (trigger) => trigger.name == value,
    orElse: () => throw FormatException('unknown scan trigger: "$value"'),
  );
}

/// One scan that changed something or failed, kept for the session so the
/// Housekeeping panel can show what the log otherwise swallows — above all a
/// deletion and a creation in one scan, which is a rename past recognition
/// and a history that stayed with the tombstone.
class ScanNotice {
  const ScanNotice({
    required this.at,
    required this.report,
    this.id,
    this.trigger = ScanTrigger.manual,
  });

  /// When the scan finished, local time.
  final DateTime at;

  final DriftScanReport report;

  /// The record's id in the scan history, which [NoteReconciler.dismissScan]
  /// takes, or null for a notice that was never recorded.
  final int? id;

  /// What started the scan.
  final ScanTrigger trigger;

  /// Whether this scan tombstoned and created in one pass: the case Decision
  /// 7 requires to be surfaced rather than silent.
  bool get lostHistory =>
      report.tombstoned.isNotEmpty && report.created.isNotEmpty;
}

/// Reconciles the folder into the catalog: files that changed outside the app
/// into their notes' history, and files that appeared, moved, or vanished into
/// the notes' identities.
///
/// **Callers flush the editor first.** Decision 6's first step — "flush the
/// editor if this note is open" — belongs to whoever holds the editor, which
/// nothing at this level does. The session host flushes every registered
/// controller before a scan; the editor pane reconciles a note before it reads
/// it, at which point that note is not the open one. A future caller that
/// reaches this from somewhere else (the filesystem watcher, **#70**) owes the
/// same courtesy, and the design says why: reconciling underneath an unsaved
/// buffer races the save.
///
/// **The app's own file management reports through the `note…` methods**
/// rather than leaving the next scan to infer it. The scan could: an in-app
/// rename is a gone path and a new file with the same hash. But inference has
/// a blind spot the app does not — a history-pending note has no hash to
/// match, so an inferred rename of one is a tombstone and a fresh mint, and
/// the identity the map carried for it is lost. The app knows it was a
/// rename; it says so.
abstract class NoteReconciler {
  /// Reconciles the whole folder against the catalog.
  ///
  /// Never throws for one note's sake — per-note failures are collected into
  /// the report so a single unreadable file cannot leave the rest of the
  /// engram unreconciled. Two overlapping calls share one scan rather than
  /// racing each other.
  ///
  /// **Runs behind the UI, not ahead of it.** The session host starts it and
  /// does not wait: a first scan over a large folder mints every note in it,
  /// which on the slowest target is minutes, and the engram is usable
  /// throughout because [reconcile] brings in whichever note the editor opens
  /// before the scan gets there. Its progress is on [adoption].
  ///
  /// [trigger] says what started it, and is recorded with the scan when the
  /// scan did anything worth recording.
  Future<DriftScanReport> scan({ScanTrigger trigger = ScanTrigger.manual});

  /// The scan's progress through files the catalog has never seen, or null
  /// while no scan is doing that. Broadcast, with [currentAdoption] for a
  /// subscriber that arrives mid-scan.
  Stream<AdoptionProgress?> get adoption;

  /// What [adoption] last reported, or null.
  AdoptionProgress? get currentAdoption;

  /// What this device knows about the engram's notes, counted now.
  Future<NoteLedger> ledger();

  /// Scans that changed something or failed and have not been dismissed,
  /// newest first, from this device's scan history — across sessions and
  /// launches, so a notice that a note's history stayed with a tombstone is
  /// still there the next time Settings is opened.
  Future<List<ScanNotice>> recentScans({int limit = 20});

  /// Dismisses the recorded scan [id]: it leaves [recentScans] and stays in
  /// the history.
  Future<void> dismissScan(int id);

  /// Reconciles the one note at engram-relative [path], if it has drifted —
  /// or brings it into the catalog if it is not there yet, by minting or by
  /// adopting from the identity map.
  ///
  /// Returns true if anything changed: the file had drifted and was
  /// reconciled, or the path was new and now has a row. False if there was
  /// nothing to do — or nothing to do it against: a file that is gone (a move
  /// or deletion, the scan's question, since it needs the whole folder to
  /// tell which), a blob, or a note whose history has not arrived. Throws if
  /// the work itself fails.
  Future<bool> reconcile(String path);

  /// The app created the file at [path]. Brings it into the catalog the way
  /// [reconcile] would, and writes the identity-map row if it minted.
  Future<void> noteCreated(String path);

  /// The app moved the file at [from] to [to]. The note keeps its identity
  /// and history; the catalog and the identity map record the new path. A
  /// destination the scan would not admit — a hidden path — is a deletion.
  Future<void> noteMoved(String from, String to);

  /// The app deleted the file at [path]. The note is tombstoned and the map
  /// says so, so a later file at the same path is a new note rather than the
  /// dead one resurrected.
  Future<void> noteDeleted(String path);

  /// Every path whose *content* was reconciled into history, by [scan] or
  /// [reconcile], as it happens. Broadcast: subscribe from anywhere, miss
  /// nothing that happens while subscribed, and expect nothing from before.
  ///
  /// This is how the editor learns that the file under its open note was
  /// rewritten — regardless of which trigger did it — so it can reload rather
  /// than save a buffer that no longer knows what is on disk. Creations,
  /// moves, and deletions are not announced here: the browser initiated the
  /// in-app ones, and the external ones change what is listed, not what an
  /// open buffer holds.
  Stream<String> get reconciled;
}
