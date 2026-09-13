/// The scan: external edits become operations (Decision 6), and files that
/// appeared, moved, or vanished become creations, moves, and deletions of
/// notes (Decision 7).
///
/// `dart:io`-only by way of [NoteDocument] and the materializer, and handed up
/// to the UI as a [NoteReconciler] so nothing above the session imports this.
///
/// **Decision 6** is the per-note procedure, in order: flush the editor (the
/// caller's job), materialize, diff, apply in one transaction, re-materialize,
/// write back if it differs, commit the new hash.
///
/// **Decision 7** is the table this file works through, once the folder has
/// been listed in full:
///
/// - a findable note whose file is gone, plus a new file whose content hash
///   matches, is a **move**: keep the id and the history, record the new path
///   — exactly how `git` detects a rename;
/// - gone, plus a new file the content sketch says is most of it, is a
///   **rename with edit**: re-associate, then reconcile the difference as
///   ordinary drift;
/// - a new file nothing claims is a **creation**: mint, seed from the file's
///   text, take the seed claim — unless the identity map knows the path, in
///   which case **adopt** the ULID and seed nothing;
/// - gone, with no match, is a **deletion**: tombstone, and say so in the map.
///
/// **Absence is not deletion.** A tombstone is written only when the scan is
/// *known complete* — the folder exists and was listed without error — and
/// the file is *confirmed absent* by a stat of its own. A folder on an
/// unmounted drive lists as empty, and a scan that took that at face value
/// would tombstone every note in it.
///
/// **Below the similarity cutoff, the cost is surfaced.** A note renamed and
/// rewritten past recognition is a tombstone and a creation, and its history
/// stays with the tombstone. That is the honest price of Decision 1's
/// rejection of a frontmatter id, and the report carries both halves so that
/// step 13 can show them rather than the scan swallowing it.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import '../engram_paths.dart';
import '../engram_store.dart';
import '../metadata.dart';
import '../note_reconciler.dart';
import 'blob_document_io.dart';
import 'catalog.dart';
import 'drift.dart';
import 'identity_authorship_io.dart';
import 'identity_merge.dart';
import 'materializer_io.dart';
import 'metadata_db_io.dart';
import 'note_document_io.dart';
import 'note_document_lock.dart';
import 'sketch.dart';

/// Logger name for scan diagnostics (see `dart:developer`).
const String driftScanLogName = 'brainframe.engram.drift';

/// Reconciles the folder into the catalog, one note at a time.
class DriftReconciler implements NoteReconciler {
  DriftReconciler({
    required this.database,
    required this.engram,
    required this.lock,
    required this.identity,
    this.noteSizeCeilingBytes = defaultNoteSizeCeilingBytes,
  });

  /// The engram's catalog and op-log.
  final MetadataDatabase database;

  /// Where the files are.
  final EngramStore engram;

  /// Shared with the editor's writer, so a reconciliation and a save never
  /// hold the same note's document at once.
  final NoteDocumentLock lock;

  /// This device's identity-map file and the reader over every device's.
  ///
  /// Null when the engram has no folder for a map to live in — no writable
  /// engram is like that today, but the seam allows one — in which case the
  /// scan reconciles drift and nothing else: without a folder to enumerate,
  /// there is no listing to infer creations and deletions from.
  final AuthoredIdentity? identity;

  /// The largest text note this engram allows, in bytes on disk — the
  /// engram's recorded value, never the build's constant (the note size
  /// ceiling design, Decision 7). A text file arriving larger than this is
  /// minted as a plain file (Decision 6); the decision is made from a
  /// `stat`, before any read, so the file is never loaded to find out.
  final int noteSizeCeilingBytes;

  final StreamController<String> _reconciled =
      StreamController<String>.broadcast();
  final StreamController<AdoptionProgress?> _adoption =
      StreamController<AdoptionProgress?>.broadcast();
  AdoptionProgress? _currentAdoption;

  /// Set by [close]. A scan still running when its session closes stops at
  /// the next note rather than failing one note at a time against a closed
  /// database — an engram switch mid-adoption is the ordinary way this
  /// happens, and the next open of that engram resumes where this left off.
  bool _closed = false;

  /// The scan in progress, so a second trigger joins it instead of starting a
  /// concurrent one. A resume that lands while the start-up scan is still
  /// running is the ordinary way this happens.
  Future<DriftScanReport>? _running;

  /// The one `bf_meta` key overwritten with the finish time of the latest
  /// scan, clean or not. A clean scan writes nothing else: it changed
  /// nothing, so the history has no row for it — this stamp is the only sign
  /// it ran. Nothing reads it to decide whether to scan; it feeds the
  /// ledger's "last scan" line and that is all.
  static const String lastScanKey = 'last_scan_utc';

  @override
  Stream<String> get reconciled => _reconciled.stream;

  @override
  Stream<AdoptionProgress?> get adoption => _adoption.stream;

  @override
  AdoptionProgress? get currentAdoption => _currentAdoption;

  void _reportAdoption(AdoptionProgress? progress) {
    _currentAdoption = progress;
    if (!_adoption.isClosed) _adoption.add(progress);
  }

  @override
  Future<DriftScanReport> scan({ScanTrigger trigger = ScanTrigger.manual}) {
    final started = DateTime.now();
    return _running ??= _scan()
        .then((report) {
          _recordScan(report, trigger: trigger, startedAt: started);
          return report;
        })
        .whenComplete(() => _running = null);
  }

  /// Writes what the scan did to the history, or — for a clean scan — only
  /// when it ran. Recording is not allowed to fail the scan: the work is
  /// done and the report is true whether or not it was written down, so a
  /// database that refuses the row is logged and the report still returned.
  void _recordScan(
    DriftScanReport report, {
    required ScanTrigger trigger,
    required DateTime startedAt,
    bool stampLastScan = true,
  }) {
    if (_closed) return;
    final finished = DateTime.now();
    try {
      // A conversion is recorded here so Housekeeping lists it, but it is
      // not a scan, and the ledger's "last scan" must not say it was.
      if (stampLastScan) {
        database.writeMeta(
          lastScanKey,
          '${finished.toUtc().millisecondsSinceEpoch}',
        );
      }
      database.scans.record(
        report,
        startedAt: startedAt,
        finishedAt: finished,
        trigger: trigger,
        // The identity is the whole point of recording the event, and for
        // these two kinds byPath cannot supply it. A tombstoned note has no
        // live row at its path at all. A retired note does — but it is the
        // election winner's, adopted in the same pass; the note this device
        // gave up is the loser's, which _retire tombstoned. Both are found
        // among the tombstones.
        ulidOf: (kind, path) => switch (kind) {
          ScanEventKind.tombstoned ||
          ScanEventKind.retired => database.catalog.lastTombstoneAt(path)?.ulid,
          _ => database.catalog.byPath(path)?.ulid,
        },
      );
    } on Object catch (error, stack) {
      developer.log(
        'scan history could not be written',
        name: driftScanLogName,
        error: error,
        stackTrace: stack,
      );
    }
  }

  @override
  Future<List<ScanNotice>> recentScans({int limit = 20}) async => [
    for (final record in database.scans.recent(
      limit: limit,
      unacknowledgedOnly: true,
    ))
      record.notice,
  ];

  @override
  Future<void> dismissScan(int id) async => database.scans.acknowledge(id);

  @override
  Future<void> convertToPlainFile(String path) async {
    final started = DateTime.now();
    final converted = await lock.run(() async {
      final row = database.catalog.byPath(path);
      if (row == null) throw StateError('no note at $path');
      if (row.mergePolicy == MergePolicy.blobLww) return false;
      // The file as it is on disk is what the register will describe: the
      // caller has either just written it (the in-app door) or is keeping
      // it as found (the external one). Streamed — it is over the ceiling,
      // which is why it is being converted.
      final digest = await digestFile(engram, path);
      // The history goes first, and all of it: the user was told. With
      // nothing left to replay, "never back to a text note" costs nothing
      // to enforce — there is no epoch to keep the old sequence out of.
      database.crdt.deleteDocumentData(row.ulid);
      final blob = BlobDocument.convert(
        store: database,
        ulid: row.ulid,
        digest: digest,
      );
      try {
        final committed = await recordFileState(
          store: database,
          engram: engram,
          row: database.catalog.byUlid(row.ulid)!,
          digest: digest,
        );
        // Published with the new policy and the new seed claim, so every
        // other device follows (phase 1 of its next scan) rather than
        // keeping a character history for a note this one has made whole.
        identity?.record(committed, deleted: false);
      } finally {
        blob.dispose();
      }
      return true;
    });
    if (!converted) return;
    // A scan of its own, so Housekeeping lists the conversion beside the
    // scans — it is a change to the engram the user will want to find.
    _recordScan(
      DriftScanReport(converted: [path]),
      trigger: ScanTrigger.manual,
      startedAt: started,
      stampLastScan: false,
    );
  }

  @override
  Future<bool> isPlainFile(String path) async {
    final row = database.catalog.byPath(path);
    return row != null &&
        row.mergePolicy == MergePolicy.blobLww &&
        mergePolicyForPath(path) == MergePolicy.fugueText;
  }

  @override
  Future<List<PendingNote>> awaitingDecision() async => [
    for (final row in database.catalog.findable())
      if (row.state == NoteState.oversized)
        PendingNote(
          path: row.path,
          sizeBytes: (await engram.statFile(row.path))?.size ?? 0,
        ),
  ];

  @override
  Future<String> reconstruct(String path) async {
    final started = DateTime.now();
    final kept = await lock.run(() async {
      final row = database.catalog.byPath(path);
      if (row == null || row.state != NoteState.oversized) {
        throw StateError('$path is not awaiting a decision');
      }
      // The oversized file is moved aside, not copied: a rename never reads
      // it, and it may be larger than memory. It is then an ordinary file in
      // the folder, and the next scan tracks it as any oversized arrival.
      final aside = await _asidePathFor(path);
      await engram.move(path, aside);
      // Live again first, so the materializer commits a live row.
      database.catalog.upsert(_withState(row, NoteState.live));
      final note = NoteDocument.open(store: database, ulid: row.ulid);
      try {
        // The CRDT's last state: the last version BrainFrame saved, under
        // the ceiling by construction, written back to the note's path.
        await materializeNote(store: database, engram: engram, note: note);
      } finally {
        note.dispose();
      }
      return aside;
    });
    _recordScan(
      DriftScanReport(reconstructed: {path: kept}),
      trigger: ScanTrigger.manual,
      startedAt: started,
      stampLastScan: false,
    );
    _reconciled.add(path);
    return kept;
  }

  /// The first of [asidePathFor]'s names beside [path] that nothing is at —
  /// never overwriting anything.
  Future<String> _asidePathFor(String path) async {
    for (var n = 1; ; n++) {
      final candidate = asidePathFor(path, ordinal: n);
      if (await engram.statFile(candidate) == null) return candidate;
    }
  }

  @override
  Future<NoteLedger> ledger() async {
    final map = identity;
    final ours = database.peerId;
    var minted = 0;
    var adopted = 0;
    var unclaimed = 0;
    var plainFiles = 0;
    for (final row in database.catalog.findable()) {
      if (row.seededBy == ours) minted++;
      if (row.state == NoteState.historyPending) {
        adopted++;
        if (row.seedClaim == null) unclaimed++;
      }
      // The row's policy against the path's: a blob at a text path is one
      // the ceiling made, since nothing else mints a .md as a blob.
      if (row.mergePolicy == MergePolicy.blobLww &&
          mergePolicyForPath(row.path) == MergePolicy.fugueText) {
        plainFiles++;
      }
    }
    // This device counts whether or not it has written its file yet — it is
    // plainly here — and with no map at all it is the only one.
    var peers = 1;
    if (map != null) {
      final seen = await map.map.peersSeen();
      peers = seen.contains(ours) ? seen.length : seen.length + 1;
    }
    return NoteLedger(
      peers: peers,
      minted: minted,
      adopted: adopted,
      unclaimed: unclaimed,
      tombstoned: database.catalog.countTombstoned(),
      plainFiles: plainFiles,
      lastScanAt: _lastScanAt(),
    );
  }

  DateTime? _lastScanAt() {
    final stamp = int.tryParse(database.readMeta(lastScanKey) ?? '');
    return stamp == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(stamp, isUtc: true).toLocal();
  }

  // ---------------------------------------------------------------- the scan

  Future<DriftScanReport> _scan() async {
    final reconciled = <String>[];
    final failed = <String, Object>{};
    final created = <String>[];
    final oversized = <String>[];
    final adopted = <String>[];
    final moved = <String, String>{};
    final tombstoned = <String>[];
    final retired = <String>[];
    final convertedElsewhere = <String, int>{};
    final awaitingDecision = <String>[];

    // The listing, and whether it can be trusted to be the whole folder.
    // Both halves are required before anything is called absent: a folder
    // that does not exist lists as empty rather than failing, and "empty"
    // from an unmounted drive is not "every note was deleted".
    Object? listingFailure;
    var onDisk = <String>{};
    final map = identity;
    if (map == null) {
      listingFailure = StateError('no folder to enumerate');
    } else if (!await Directory(map.map.engramRoot).exists()) {
      listingFailure = FileSystemException(
        'engram folder is not there',
        map.map.engramRoot,
      );
    } else {
      try {
        onDisk = {
          for (final path in await engram.list())
            if (!isHiddenEngramPath(path)) path,
        };
      } on Object catch (error, stack) {
        listingFailure = error;
        developer.log(
          'engram folder could not be listed',
          name: driftScanLogName,
          error: error,
          stackTrace: stack,
        );
      }
    }
    final complete = listingFailure == null;
    final merged = complete
        ? mergeIdentity(await map!.map.readEveryDevicesRows())
        : null;

    // Phase 1: every note the catalog expects to find. Present notes get
    // Decision 6; absent ones are held as candidates for Decision 7.
    final missing = <CatalogRow>[];
    for (final row in database.catalog.findable()) {
      if (_closed) break;
      try {
        if (merged != null && merged.retired.contains(row.ulid)) {
          // A lost election: the loser retires, before anything else is
          // concluded about a path it no longer owns.
          await _retire(row, merged);
          retired.add(row.path);
          continue;
        }
        if (merged != null) {
          final abandoned = await _followConversion(row, merged);
          if (abandoned != null) convertedElsewhere[row.path] = abandoned;
        }
        if (complete && isHiddenEngramPath(row.path)) {
          // A note living where no note may. The listing never admits the
          // path, so it is treated exactly as a file renamed into a
          // dot-directory: gone, whatever a stat would say.
          missing.add(row);
          continue;
        }
        if (!complete || onDisk.contains(row.path)) {
          switch (await _reconcileRow(row)) {
            case _Drift.reconciled:
              reconciled.add(row.path);
            case _Drift.awaitingDecision:
              awaitingDecision.add(row.path);
            case _Drift.none:
              break;
          }
          continue;
        }
        // Listed as absent. Confirm it with a stat of its own, so a listing
        // that raced a write is not the sole witness.
        if (await engram.statFile(row.path) == null) missing.add(row);
      } on Object catch (error, stack) {
        _fail(failed, row.path, error, stack);
      }
    }

    // Phase 2: files the catalog does not know. Each is a move, a rename
    // with edit, or new — in that order, because the exact test is cheap
    // and certain, the sketch is neither, and minting is the last resort.
    if (complete && !_closed) {
      final unknown =
          onDisk.where((path) => database.catalog.byPath(path) == null).toList()
            ..sort();
      // This is the expensive half, and the only one worth a progress bar:
      // every file here is seeded, and on a folder that predates the catalog
      // that is every file in it.
      var done = 0;
      if (unknown.isNotEmpty) {
        _reportAdoption(AdoptionProgress(done: 0, total: unknown.length));
      }
      for (final path in unknown) {
        if (_closed) break;
        try {
          // One pass over the file, shared by the match and the mint: a
          // blob is digested over a stream and its bytes are never held;
          // text is read whole, since the sketch and the seed need it.
          final content = await _NewFile.read(
            engram,
            path,
            ceiling: noteSizeCeilingBytes,
          );
          final match = await _matchMissing(path, content, missing);
          if (match != null) {
            missing.remove(match);
            moved[match.path] = path;
            switch (await _reconcileRow(database.catalog.byPath(path)!)) {
              case _Drift.reconciled:
                reconciled.add(path);
              case _Drift.awaitingDecision:
                awaitingDecision.add(path);
              case _Drift.none:
                break;
            }
            continue;
          }
          switch (await _bringIn(path, content, merged!)) {
            case _Arrival.minted:
              (content.overCeiling ? oversized : created).add(path);
            case _Arrival.adopted:
              adopted.add(path);
            case _Arrival.present:
              // The editor got there first: the user opened it, and
              // reconcile() brought it in. Nothing to report.
              break;
          }
        } on Object catch (error, stack) {
          _fail(failed, path, error, stack);
        } finally {
          done++;
          if (unknown.isNotEmpty) {
            _reportAdoption(
              AdoptionProgress(done: done, total: unknown.length),
            );
          }
        }
      }
      if (unknown.isNotEmpty) _reportAdoption(null);

      // Phase 3: what is still missing is gone. Known complete, confirmed
      // absent, and nothing on disk claimed it. Not after a cut-short phase
      // 2, though: a file that would have matched a missing note was never
      // looked at, and tombstoning the note now would lose its history.
      for (final row in _closed ? const <CatalogRow>[] : missing) {
        try {
          await _tombstone(row);
          tombstoned.add(row.path);
        } on Object catch (error, stack) {
          _fail(failed, row.path, error, stack);
        }
      }
      if (tombstoned.isNotEmpty && created.isNotEmpty) {
        developer.log(
          'notes deleted and created in one scan — a rename past the '
          'similarity cutoff loses its history: deleted $tombstoned, '
          'created $created',
          name: driftScanLogName,
        );
      }
    }

    return DriftScanReport(
      reconciled: reconciled,
      failed: failed,
      created: created,
      oversized: oversized,
      adopted: adopted,
      moved: moved,
      tombstoned: tombstoned,
      retired: retired,
      convertedElsewhere: convertedElsewhere,
      awaitingDecision: awaitingDecision,
      listingFailure: listingFailure,
    );
  }

  void _fail(
    Map<String, Object> failed,
    String path,
    Object error,
    StackTrace stack,
  ) {
    // Collected, not rethrown: the rest of the engram still gets its scan,
    // and this path is still wrong for the next one. Logged so the failure
    // is visible somewhere until step 13 gives it a surface.
    failed[path] = error;
    developer.log(
      'scan failed for $path',
      name: driftScanLogName,
      error: error,
      stackTrace: stack,
    );
  }

  // ------------------------------------------------------- one path, by hand

  @override
  Future<bool> reconcile(String path) async {
    // First, before the catalog is even consulted: a hidden path is outside
    // the scan's world whether or not a row claims it. A row at one can only
    // be a mistake, and reconciling it would keep the mistake alive.
    if (isHiddenEngramPath(path)) return false;
    final row = database.catalog.byPath(path);
    if (row != null) {
      final started = DateTime.now();
      switch (await _reconcileRow(row)) {
        case _Drift.reconciled:
          return true;
        case _Drift.awaitingDecision:
          // Found before an open rather than by a scan: recorded as one so
          // Housekeeping has the same card either way.
          _recordScan(
            DriftScanReport(awaitingDecision: [path]),
            trigger: ScanTrigger.manual,
            startedAt: started,
            stampLastScan: false,
          );
          return false;
        case _Drift.none:
          return false;
      }
    }
    final map = identity;
    if (map == null) return false;
    if (await engram.statFile(path) == null) return false;
    // Re-read and re-merged on every before-open of an unknown note. Cheap
    // today — a few kilobyte files, one per device that has ever written to
    // this engram — but it is per-open work that grows with that device
    // count, and a merged view cached per session (invalidated by a scan,
    // which re-reads anyway) is the fix if it ever shows up in a profile.
    final arrival = await _bringIn(
      path,
      await _NewFile.read(engram, path, ceiling: noteSizeCeilingBytes),
      mergeIdentity(await map.map.readEveryDevicesRows()),
    );
    // Present means a scan got there first while this was waiting on the
    // lock — nothing changed on this call's account.
    return arrival != _Arrival.present;
  }

  @override
  Future<void> noteCreated(String path) async {
    await reconcile(path);
  }

  @override
  Future<void> noteMoved(String from, String to) => lock.run(() async {
    final row = database.catalog.byPath(from);
    if (row == null) {
      // Nothing to carry: the destination is simply a file the catalog has
      // not met, which the next open or scan brings in.
      return;
    }
    if (isHiddenEngramPath(to)) {
      // Moved out of what counts as content. The scan would never list it
      // again, so this is what the scan would conclude, said sooner.
      _tombstoneRow(row);
      return;
    }
    _record(_withPath(row, to));
  });

  @override
  Future<void> noteDeleted(String path) => lock.run(() async {
    final row = database.catalog.byPath(path);
    if (row != null) _tombstoneRow(row);
  });

  // ---------------------------------------------------------- Decision 6

  /// Decision 6, steps 2–6, for one note; step 1 is the caller's.
  ///
  /// The lock is taken per note and released before the next, so a save
  /// waiting on it waits for one reconciliation, not a whole scan.
  Future<_Drift> _reconcileRow(CatalogRow row) async {
    if (row.state != NoteState.live && row.state != NoteState.oversized) {
      return _Drift.none;
    }

    return lock.run(() async {
      // Re-read under the lock: a save that was ahead of us in the queue has
      // just committed a new hash, and the row we were handed describes the
      // file before it.
      var current = database.catalog.byUlid(row.ulid);
      if (current == null) return _Drift.none;
      if (current.state != NoteState.live &&
          current.state != NoteState.oversized) {
        return _Drift.none;
      }

      final stat = await engram.statFile(current.path);
      if (stat == null) return _Drift.none; // gone: the scan's question
      if (current.mergePolicy != MergePolicy.fugueText) {
        return await _reconcileBlob(current, stat)
            ? _Drift.reconciled
            : _Drift.none;
      }

      // The ceiling, from the stat and before any read, and whether or not
      // the file looks changed — a lowered ceiling changes nothing on disk.
      // A text note over it has a history and is too large to open as one:
      // it waits for the user (the note size ceiling design, Decision 4).
      // The file is left exactly as found; nothing below runs for it. A
      // note that was waiting and is now back under the line has been
      // trimmed outside the app, and comes back as ordinary drift.
      if (stat.size > noteSizeCeilingBytes) {
        if (current.state == NoteState.oversized) return _Drift.none;
        database.catalog.upsert(_withState(current, NoteState.oversized));
        return _Drift.awaitingDecision;
      }
      if (current.state == NoteState.oversized) {
        current = _withState(current, NoteState.live);
        database.catalog.upsert(current);
      }

      // Decision 5's two-stage test, with the file's bytes kept: the hash the
      // pre-filter could not rule out is the same one the materializer uses
      // to decide whether the write-back is needed. A row with no sketch —
      // one that predates the sketch — reads the file regardless, so the
      // sketch can be built from it.
      if (current.sketch != null && !mayHaveDrifted(current, stat)) {
        return _Drift.none;
      }
      final bytes = await engram.readBytes(current.path);
      final onDiskHash = contentHash(bytes);
      if (!hasDrifted(current, onDiskHash)) {
        if (current.sketch == null) {
          await recordFileState(
            store: database,
            engram: engram,
            row: current,
            digest: ContentDigest(hash: onDiskHash, size: bytes.length),
            text: utf8.decode(bytes),
          );
        }
        return _Drift.none;
      }

      final NoteDocument note;
      try {
        note = NoteDocument.open(store: database, ulid: current.ulid);
      } on NoteHistoryPendingException {
        // A live row whose log has not arrived: nothing to diff into. The
        // file stays as the user left it, which is what Decision 4's bounded
        // exception promises, and the eventual log reconciles it then.
        return _Drift.none;
      }
      try {
        // Steps 3 and 4: a minimal script — never replace-all — applied in
        // one transaction. Terminators are normalized on the way in, so a
        // CRLF round-trip arrives here as zero operations and still reaches
        // the materializer below, which is the whole reason step 5 is not
        // gated on "did this produce anything?".
        note.applyExternalText(utf8.decode(bytes));
        // Steps 5 and 6, unconditional. The write is skipped only when the
        // materialized bytes are exactly what is on disk; the hash is
        // committed either way.
        await materializeNote(
          store: database,
          engram: engram,
          note: note,
          onDiskHash: onDiskHash,
        );
      } finally {
        note.dispose();
      }
      _reconciled.add(current.path);
      return _Drift.reconciled;
    });
  }

  /// [row] in [state], everything else as it was.
  CatalogRow _withState(CatalogRow row, NoteState state) => CatalogRow(
    ulid: row.ulid,
    path: row.path,
    mergePolicy: row.mergePolicy,
    state: state,
    materializedHash: row.materializedHash,
    size: row.size,
    mtimeUtc: row.mtimeUtc,
    sketch: row.sketch,
    seedClaim: row.seedClaim,
  );

  /// Decision 6 for a blob, under the lock already: the same two-stage drift
  /// test, and then — instead of a diff, which a blob never enters — one
  /// last-writer-wins claim that the file is now these bytes (Decision 3).
  ///
  /// The catalog is brought up to date either way, so a moved blob can be
  /// found by its hash; the claim is what makes the change *history*, so a
  /// second device that later receives it knows which bytes won.
  Future<bool> _reconcileBlob(CatalogRow current, FileFingerprint stat) async {
    if (!mayHaveDrifted(current, stat)) return false;
    // Streamed, never read whole: a blob may be larger than memory, and the
    // only thing anything below needs to know about it is its digest.
    final digest = await digestFile(engram, current.path);
    if (!hasDrifted(current, digest.hash)) return false;

    var claimed = false;
    try {
      final blob = BlobDocument.open(store: database, ulid: current.ulid);
      try {
        claimed = blob.record(digest);
      } finally {
        blob.dispose();
      }
    } on NoteHistoryPendingException {
      // The ULID was adopted and its log has not arrived; there is no
      // register to write to yet. The file stays as found, which is what
      // Decision 4's bounded exception promises, and the log reconciles it
      // when it lands — as for a text note in the same state.
    }
    await recordFileState(
      store: database,
      engram: engram,
      row: current,
      digest: digest,
    );
    if (claimed) _reconciled.add(current.path);
    return claimed;
  }

  // ---------------------------------------------------------- Decision 7

  /// The missing note that the new file at [path] is, if any: an exact
  /// content match first, then — for text, whose bytes [content] holds —
  /// the closest sketch above the cutoff. On a match the note is re-pointed
  /// at [path] and the match is returned.
  Future<CatalogRow?> _matchMissing(
    String path,
    _NewFile content,
    List<CatalogRow> missing,
  ) async {
    if (missing.isEmpty) return null;
    final hash = content.digest.hash;

    CatalogRow? match;
    for (final candidate in missing) {
      if (candidate.materializedHash == hash) {
        match = candidate;
        break;
      }
    }

    final bytes = content.bytes;
    if (match == null && bytes != null) {
      final sketch = computeSketch(utf8.decode(bytes));
      var best = 0.0;
      for (final candidate in missing) {
        if (candidate.mergePolicy != MergePolicy.fugueText) continue;
        final similarity = sketchSimilarity(sketch, candidate.sketch);
        // Strictly greater, so a tie between two candidates is a miss for
        // both: re-associating with the wrong one merges two histories,
        // which is the failure this whole comparison is biased against.
        if (similarity >= renameSimilarityCutoff && similarity > best) {
          best = similarity;
          match = candidate;
        }
      }
    }

    if (match == null) return null;
    await lock.run(() async {
      _record(_withPath(match!, path));
    });
    return match;
  }

  /// Brings a file the catalog does not know into it, as the identity map
  /// says: minted and seeded if nobody claims the path, adopted without a
  /// seed if another device does, recovered if this device's own map does.
  ///
  /// [content] was read before the lock was taken, so a save that lands in
  /// between seeds from bytes a moment old. That is the same window the
  /// crash-ordering case already tolerates: the next scan sees the file
  /// differ from what was seeded and reconciles it. Reading under the lock
  /// instead would cost a blob a second full pass, which is the thing a
  /// video cannot afford.
  Future<_Arrival> _bringIn(
    String path,
    _NewFile content,
    MergedIdentity merged,
  ) => lock.run(() async {
    if (database.catalog.byPath(path) != null) return _Arrival.present;
    final map = identity!;

    switch (dispositionForPath(merged, path, self: map.map.peerId)) {
      case NoteDisposition.mint:
        // One shape per policy (Decision 3): a text note is seeded from
        // the file's full text as a single insert, a blob's register from
        // its digest — the op-log never carries a blob's bytes, and
        // neither does this method. Either is disposed once the seed is
        // durable, so a folder of notes costs one document at a time.
        final CatalogRow committed;
        final bytes = content.bytes;
        if (bytes != null) {
          final note = NoteDocument.mint(
            store: database,
            path: path,
            content: utf8.decode(bytes),
          );
          try {
            // Materialized, which is where Decision 10 lands on disk: a
            // CRLF file is rewritten LF here, in the one sweep adoption
            // makes over the folder, rather than one note at a time as
            // each is first edited. A drip of terminator changes over
            // months — never ending, if some notes are never opened —
            // is the worse experience for exactly the user who would
            // notice either, one with the folder under version control;
            // one warned, one-time change is something they can commit
            // on its own. The confirmation states the count first. A
            // file already LF is left untouched, mtime and all.
            committed = await materializeNote(
              store: database,
              engram: engram,
              note: note,
              onDiskHash: content.digest.hash,
            );
          } finally {
            note.dispose();
          }
        } else {
          final blob = BlobDocument.mint(
            store: database,
            path: path,
            digest: content.digest,
            overCeiling: content.overCeiling,
          );
          // Just written by mint, under this same lock; a missing row
          // here is a bug, and a named exception says so rather than a
          // bare null-check failure.
          final minted = database.catalog.byUlid(blob.ulid);
          if (minted == null) throw UnknownNoteException(blob.ulid);
          try {
            // A blob's bytes are never normalized and never rewritten;
            // the file is the only copy. It is recorded as found so a
            // later move can be matched by hash.
            committed = await recordFileState(
              store: database,
              engram: engram,
              row: minted,
              digest: content.digest,
            );
          } finally {
            blob.dispose();
          }
        }
        map.record(committed, deleted: false);
        return _Arrival.minted;

      case NoteDisposition.adoptPending:
      case NoteDisposition.adoptClaimable:
        // Never seed under a ULID this device did not mint: two seeds of
        // one document id are disjoint element universes, and the merge
        // concatenates rather than recognises. History-pending until a
        // log arrives; an unclaimed seed is taken on the first edit, and
        // that door is not built yet — the row records the honest state
        // and the writer treats both alike.
        final row = merged.forPath(path)!;
        database.catalog.upsert(
          CatalogRow(
            ulid: row.ulid,
            path: path,
            mergePolicy: row.mergePolicy,
            state: NoteState.historyPending,
            seedClaim: row.seedClaim,
          ),
        );
        return _Arrival.adopted;

      case NoteDisposition.alreadyOurs:
        // Our own map, but no catalog row: the local database was lost.
        // Identity survives, history does not. The row is live with our
        // seed claim, an empty log, and no hash — "this device has never
        // written this file" — so the next reconciliation of it seeds
        // the empty document from the file. That is the one seed this
        // device is entitled to make again, because it made the first;
        // a peer that still holds the old log will see two, which is
        // #67's to notice from the claim's clock.
        final row = merged.forPath(path)!;
        database.catalog.upsert(
          CatalogRow(
            ulid: row.ulid,
            path: path,
            mergePolicy: row.mergePolicy,
            state: NoteState.live,
            seedClaim: row.seedClaim,
          ),
        );
        return _Arrival.adopted;
    }
  });

  /// A note gone from the folder with nothing to show for it.
  Future<void> _tombstone(CatalogRow row) => lock.run(() async {
    _tombstoneRow(row);
  });

  /// The loser of an identity election over its path (Decision 9, rule 2):
  /// this device's ULID is tombstoned, the winner's is adopted as
  /// history-pending, and the map is told the loser is retired.
  ///
  /// Not a re-key. Both documents were independently seeded, so pointing this
  /// one at the winner's id would put two disjoint element universes under
  /// one document — the duplication the frozen suite pins.
  /// Applies a conversion another device made (Decision 4): when the map's
  /// row for a text note says `blobLww`, this device's row follows, without
  /// asking — consent was given once, by whoever converted it, and one
  /// device keeping a character history for a note another has made whole
  /// is the split-brain one ceiling everywhere exists to prevent. The local
  /// log is left where it is (nothing here destroys history the user did
  /// not consent to losing) but nothing reads it as a text sequence again;
  /// the count of changes in it is what the user is told is unreachable.
  ///
  /// Never the other way. A map row saying `fugueText` for a note this
  /// device holds as a blob is an older row that lost to the conversion, or
  /// a build that predates it, and is ignored: promotion does not exist.
  ///
  /// Returns the number of local changes made unreachable, or null when
  /// nothing was followed.
  Future<int?> _followConversion(CatalogRow row, MergedIdentity merged) async {
    final theirs = merged.byUlid[row.ulid];
    if (theirs == null ||
        theirs.mergePolicy != MergePolicy.blobLww ||
        row.mergePolicy != MergePolicy.fugueText) {
      return null;
    }
    return lock.run(() async {
      final current = database.catalog.byUlid(row.ulid);
      if (current == null || current.mergePolicy != MergePolicy.fugueText) {
        return null;
      }
      final abandoned = database.crdt
          .changeStorageForDocument(row.ulid)
          .getChanges()
          .length;
      database.catalog.upsert(
        CatalogRow(
          ulid: current.ulid,
          path: current.path,
          mergePolicy: MergePolicy.blobLww,
          state: current.state,
          materializedHash: current.materializedHash,
          size: current.size,
          mtimeUtc: current.mtimeUtc,
          // The converter's claim: the seeder of the new epoch, so this
          // device's own map row, when next written, agrees with theirs.
          seedClaim: theirs.seedClaim ?? current.seedClaim,
        ),
      );
      return abandoned;
    });
  }

  Future<void> _retire(CatalogRow row, MergedIdentity merged) =>
      lock.run(() async {
        final winner = merged.forPath(row.path);
        _tombstoneRow(row);
        if (winner == null || winner.ulid == row.ulid) return;
        database.catalog.upsert(
          CatalogRow(
            ulid: winner.ulid,
            path: row.path,
            mergePolicy: winner.mergePolicy,
            state: NoteState.historyPending,
            seedClaim: winner.seedClaim,
          ),
        );
      });

  /// Tombstones [row] in the catalog and, if this device is answerable for
  /// the claim, in the map. Under the lock already.
  void _tombstoneRow(CatalogRow row) {
    final dead = CatalogRow(
      ulid: row.ulid,
      path: row.path,
      mergePolicy: row.mergePolicy,
      state: NoteState.tombstoned,
      materializedHash: row.materializedHash,
      size: row.size,
      mtimeUtc: row.mtimeUtc,
      sketch: row.sketch,
      seedClaim: row.seedClaim,
    );
    database.catalog.upsert(dead);
    identity?.record(dead, deleted: true);
  }

  /// Writes [row] to the catalog and records it in the map. Under the lock
  /// already.
  void _record(CatalogRow row) {
    database.catalog.upsert(row);
    identity?.record(row, deleted: row.state == NoteState.tombstoned);
  }

  static CatalogRow _withPath(CatalogRow row, String path) => CatalogRow(
    ulid: row.ulid,
    path: path,
    mergePolicy: row.mergePolicy,
    state: row.state,
    materializedHash: row.materializedHash,
    size: row.size,
    mtimeUtc: row.mtimeUtc,
    sketch: row.sketch,
    seedClaim: row.seedClaim,
  );

  /// Stops a running scan at its next note and closes the event streams. The
  /// session calls this on the way out; nothing else needs to.
  Future<void> close() async {
    _closed = true;
    _reportAdoption(null);
    await _reconciled.close();
    await _adoption.close();
  }
}

/// How a file the catalog did not know was brought in — or was found to be in
/// already, because the editor opened it before the scan reached it.
enum _Arrival { minted, adopted, present }

/// What one pass over a new file established, shared by the match and the
/// mint so a file is read once per scan.
///
/// A blob is digested over a stream and [bytes] is null: nothing downstream
/// needs more than its digest, and a video is a blob like any other. Text is
/// read whole, because the sketch and the seed both need it — but only once
/// a `stat` has said it is under the engram's note size ceiling. A text file
/// over it is a blob from this moment on ([overCeiling]): digested like one,
/// never read whole, and minted as one (the note size ceiling design,
/// Decisions 1 and 6). That is what keeps a 500 MB `.txt` from ever being
/// loaded, and it is the one place the ceiling is measured for an arrival.
class _NewFile {
  const _NewFile(this.digest, this.bytes, {this.overCeiling = false});

  static Future<_NewFile> read(
    EngramStore engram,
    String path, {
    required int ceiling,
  }) async {
    if (mergePolicyForPath(path) == MergePolicy.fugueText) {
      // Bytes on disk, as found (Decision 1): the size the user can see,
      // and never fewer than the elements the sequence would allocate. A
      // stat that comes back null is a file that vanished between the
      // listing and here; reading it fails the same way it would have.
      final size = (await engram.statFile(path))?.size;
      if (size != null && size > ceiling) {
        return _NewFile(
          await digestFile(engram, path),
          null,
          overCeiling: true,
        );
      }
      final bytes = await engram.readBytes(path);
      return _NewFile(ContentDigest.of(bytes), bytes);
    }
    return _NewFile(await digestFile(engram, path), null);
  }

  final ContentDigest digest;
  final Uint8List? bytes;

  /// A text path the ceiling made a blob of.
  final bool overCeiling;
}

/// What reconciling one note came to.
enum _Drift {
  /// Nothing to do, or nothing that could be done.
  none,

  /// The file had changed and its changes are now history.
  reconciled,

  /// The file is over the ceiling; the note now waits for the user.
  awaitingDecision,
}
