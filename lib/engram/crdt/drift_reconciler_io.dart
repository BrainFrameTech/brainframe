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

import '../engram_paths.dart';
import '../engram_store.dart';
import '../note_reconciler.dart';
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
  Future<DriftScanReport> scan() =>
      _running ??= _scan().whenComplete(() => _running = null);

  // ---------------------------------------------------------------- the scan

  Future<DriftScanReport> _scan() async {
    final reconciled = <String>[];
    final failed = <String, Object>{};
    final created = <String>[];
    final adopted = <String>[];
    final moved = <String, String>{};
    final tombstoned = <String>[];
    final retired = <String>[];

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
        if (complete && isHiddenEngramPath(row.path)) {
          // A note living where no note may. The listing never admits the
          // path, so it is treated exactly as a file renamed into a
          // dot-directory: gone, whatever a stat would say.
          missing.add(row);
          continue;
        }
        if (!complete || onDisk.contains(row.path)) {
          if (await _reconcileRow(row)) reconciled.add(row.path);
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
          final match = await _matchMissing(path, missing);
          if (match != null) {
            missing.remove(match);
            moved[match.path] = path;
            if (await _reconcileRow(database.catalog.byPath(path)!)) {
              reconciled.add(path);
            }
            continue;
          }
          switch (await _bringIn(path, merged!)) {
            case _Arrival.minted:
              created.add(path);
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
      adopted: adopted,
      moved: moved,
      tombstoned: tombstoned,
      retired: retired,
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
    if (row != null) return _reconcileRow(row);
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
  Future<bool> _reconcileRow(CatalogRow row) async {
    if (row.state != NoteState.live) return false;

    return lock.run(() async {
      // Re-read under the lock: a save that was ahead of us in the queue has
      // just committed a new hash, and the row we were handed describes the
      // file before it.
      final current = database.catalog.byUlid(row.ulid);
      if (current == null || current.state != NoteState.live) return false;

      final stat = await engram.statFile(current.path);
      if (stat == null) return false; // gone: the scan's question, not this
      if (current.mergePolicy != MergePolicy.fugueText) {
        // A blob has nothing to diff into until step 14. What it does have
        // is a hash to be found by if it moves, which is kept current here.
        if (!mayHaveDrifted(current, stat)) return false;
        final bytes = await engram.readBytes(current.path);
        if (!hasDrifted(current, contentHash(bytes))) return false;
        await recordFileState(
          store: database,
          engram: engram,
          row: current,
          bytes: bytes,
        );
        return false;
      }

      // Decision 5's two-stage test, with the file's bytes kept: the hash the
      // pre-filter could not rule out is the same one the materializer uses
      // to decide whether the write-back is needed. A row with no sketch —
      // one that predates the sketch — reads the file regardless, so the
      // sketch can be built from it.
      if (current.sketch != null && !mayHaveDrifted(current, stat)) {
        return false;
      }
      final bytes = await engram.readBytes(current.path);
      final onDiskHash = contentHash(bytes);
      if (!hasDrifted(current, onDiskHash)) {
        if (current.sketch == null) {
          await recordFileState(
            store: database,
            engram: engram,
            row: current,
            bytes: bytes,
          );
        }
        return false;
      }

      final NoteDocument note;
      try {
        note = NoteDocument.open(store: database, ulid: current.ulid);
      } on NoteHistoryPendingException {
        // A live row whose log has not arrived: nothing to diff into. The
        // file stays as the user left it, which is what Decision 4's bounded
        // exception promises, and the eventual log reconciles it then.
        return false;
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
      return true;
    });
  }

  // ---------------------------------------------------------- Decision 7

  /// The missing note that the new file at [path] is, if any: an exact
  /// content match first, then the closest sketch above the cutoff. On a
  /// match the note is re-pointed at [path] and the match is returned.
  Future<CatalogRow?> _matchMissing(
    String path,
    List<CatalogRow> missing,
  ) async {
    if (missing.isEmpty) return null;
    final bytes = await engram.readBytes(path);
    final hash = contentHash(bytes);

    CatalogRow? match;
    for (final candidate in missing) {
      if (candidate.materializedHash == hash) {
        match = candidate;
        break;
      }
    }

    if (match == null && mergePolicyForPath(path) == MergePolicy.fugueText) {
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
  Future<_Arrival> _bringIn(String path, MergedIdentity merged) => lock.run(
    () async {
      if (database.catalog.byPath(path) != null) return _Arrival.present;
      final map = identity!;
      final bytes = await engram.readBytes(path);

      switch (dispositionForPath(merged, path, self: map.map.peerId)) {
        case NoteDisposition.mint:
          // Seeded from the file's full text as a single insert; for a
          // blob the sequence stays empty, since the op-log does not carry
          // its bytes (Decision 3). Disposed once the seed is durable, so
          // a folder of notes costs one document at a time.
          final policy = mergePolicyForPath(path);
          final note = NoteDocument.mint(
            store: database,
            path: path,
            content: policy == MergePolicy.fugueText ? utf8.decode(bytes) : '',
          );
          try {
            if (policy == MergePolicy.fugueText) {
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
              await materializeNote(
                store: database,
                engram: engram,
                note: note,
                onDiskHash: contentHash(bytes),
              );
            } else {
              // A blob's bytes are never normalized and never rewritten;
              // it is recorded as found so a later move can be matched.
              await recordFileState(
                store: database,
                engram: engram,
                row: database.catalog.byUlid(note.ulid)!,
                bytes: bytes,
              );
            }
          } finally {
            note.dispose();
          }
          map.record(database.catalog.byUlid(note.ulid)!, deleted: false);
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
    },
  );

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
