/// `deliver`: one device's operations carried into another's op-log, by
/// hand — the local half of sync (#67), with a person standing in for the
/// transport.
///
/// The op-log is a table keyed `(document_id, change_id)`, and every row for
/// a note is a complete causal set, so *moving* the rows is three SQL
/// statements. What makes delivery more than that is everything a transport
/// carries besides operations, and what the receiver must do once they
/// land — none of which the app does yet, because nothing has ever
/// delivered anything:
///
/// 0. **Identity first.** The sender's identity-map files — engram-level
///    shared state, one file per peer, designed to be copied by a sync
///    client (Decision 9) — are copied into the receiver's folder when the
///    two folders differ, and the receiver is scanned. That scan is the
///    real code doing the real thing: adopting identities for files it has,
///    and, where both devices minted one path, the election — the lower
///    ULID wins, the loser is retired. Without this step a receiver over
///    its own copy of the folder calls every note by a different name and
///    nothing can be delivered to it.
/// 1. **Local drift first.** If the receiver's file has changed outside the
///    app and its row is live, that drift is reconciled *before* the
///    import, so the receiver's own edits are operations against the
///    document as it was — the ordering that lets the merge be a merge.
///    Skipped when the two devices share one folder: there the file already
///    carries the sender's edits, and diffing them in would author a second
///    copy of every one of them.
/// 2. **Import.** The sender's changes the receiver lacks are saved into
///    its op-log. `INSERT OR REPLACE`, so a re-run is harmless.
/// 3. **A history-pending row is promoted** to live: it has a log now. Its
///    file, which was the authority until this moment, is diffed into the
///    arrived document once — plain-file edits made while pending become
///    operations on top of the sender's — and the result is materialized.
///    This is the step the row's "last observed" hash exists for, and the
///    one that must run *regardless* of that hash.
/// 4. **A live row is materialized** from the merged document: the file
///    becomes the projection of both histories, and the hash is recorded so
///    the receiver's next scan finds nothing to do.
/// 5. **A note the receiver has never met is created.** The sender's row
///    says what it is — path, policy, seed claim — and the log holds its
///    whole text, so the row is written, the log imported, and the file
///    materialized: the note appears in the receiver's folder. Not a seed:
///    the seed is the minter's, imported with the rest. If the receiver
///    holds a *different* ULID at that path, both devices minted it and
///    the election in step 0 should have settled it; a leftover means the
///    receiver's ULID won, and the note is delivered the other way.
///
/// A blob's log carries digests, never bytes (Decision 3), so for a blob the
/// register is merged and, when the winning digest is not what the receiver's
/// file holds, the bytes are copied from the sender's folder if that file
/// matches; otherwise the receiver is told what it is missing.
///
/// **The receiving app must be closed.** It holds the store open and keeps
/// a note's text in its editor; delivering underneath it would leave that
/// buffer stale, and its next save would diff the stale text into the
/// merged document — deleting what just arrived. On Linux this is checked
/// through `/proc`, naming whatever holds the store; a bfmon `watch` is
/// tolerated, since it only reads. Elsewhere it cannot be checked, and
/// `--force` says you did.
library;

import 'dart:convert';
import 'dart:io';

import 'package:brainframe/engram/crdt/app_data_source.dart';
import 'package:brainframe/engram/crdt/blob_document_io.dart';
import 'package:brainframe/engram/crdt/catalog.dart';
import 'package:brainframe/engram/crdt/drift.dart';
import 'package:brainframe/engram/crdt/drift_reconciler_io.dart';
import 'package:brainframe/engram/crdt/identity_authorship_io.dart';
import 'package:brainframe/engram/crdt/identity_map_io.dart';
import 'package:brainframe/engram/crdt/materializer_io.dart';
import 'package:brainframe/engram/crdt/metadata_db_io.dart';
import 'package:brainframe/engram/crdt/note_document_io.dart';
import 'package:brainframe/engram/crdt/note_document_lock.dart';
import 'package:brainframe/engram/fs/engram_location.dart';
import 'package:brainframe/engram/fs/fs_store_io.dart';
import 'package:brainframe/engram/metadata.dart';
import 'package:crdt_lf/crdt_lf.dart';

import 'replay.dart';
import 'store.dart';

/// What happened to one note, for the summary.
enum DeliveryOutcome { delivered, upToDate, skipped, failed }

/// A process that has a store open: its pid and what it is.
class StoreHolder {
  const StoreHolder(this.pid, this.name);

  final int pid;

  /// The process name from `/proc/<pid>/comm` — `brainframe` for the app,
  /// `bfmon` for a built monitor, `dart:bfmon.dart` for one under
  /// `dart run`.
  final String name;

  /// Whether this is another bfmon — a `watch` in the third window,
  /// typically. It holds the store read-only and keeps nothing in memory
  /// that a delivery could leave stale; it will narrate the delivery.
  bool get isMonitor => name.contains('bfmon');

  @override
  String toString() => 'pid $pid ($name)';
}

/// The processes, other than this one, that have [path] open.
///
/// Linux only, through `/proc/<pid>/fd`; null where it cannot be told.
/// Only this user's processes are readable, which is the case that matters:
/// the app is theirs. The path is compared resolved, since the kernel
/// reports the real file and the user may have named it through a symlink.
List<StoreHolder>? holdersOf(String path) {
  if (!Platform.isLinux) return null;
  final proc = Directory('/proc');
  if (!proc.existsSync()) return null;
  final file = File(path);
  final target = file.existsSync()
      ? file.resolveSymbolicLinksSync()
      : file.absolute.path;
  final holders = <StoreHolder>[];
  for (final entry in proc.listSync()) {
    final other = int.tryParse(
      entry.uri.pathSegments.where((s) => s.isNotEmpty).last,
    );
    if (other == null || other == pid) continue;
    final fds = Directory('${entry.path}/fd');
    late final List<FileSystemEntity> links;
    try {
      links = fds.listSync();
    } on FileSystemException {
      continue; // not ours
    }
    for (final link in links) {
      try {
        if (Link(link.path).targetSync() != target) continue;
      } on FileSystemException {
        continue;
      }
      String name;
      try {
        name = File('${entry.path}/comm').readAsStringSync().trim();
      } on FileSystemException {
        name = '?';
      }
      holders.add(StoreHolder(other, name));
      break;
    }
  }
  return holders;
}

/// Carries the sender's log for [note] — a path or a ULID, or every note
/// when null — into the receiver's store, and brings the receiver's files
/// up to date with what arrived. Prints one line per note to [out].
///
/// Throws [ArgumentError] for a refusal: the same store on both sides, a
/// receiver with no folder label, or a receiver still open in a process that
/// is not a bfmon, without [force]. Another bfmon — the `watch` in the third
/// window — is fine: it reads, keeps no note in memory, and will narrate
/// what arrives.
Future<Map<DeliveryOutcome, int>> deliver({
  required String fromStorePath,
  required String toStorePath,
  String? note,
  required StringSink out,
  bool force = false,
}) async {
  final from = File(fromStorePath).absolute.path;
  final to = File(toStorePath).absolute.path;
  if (from == to) {
    throw ArgumentError('the sender and the receiver are the same store');
  }
  final receiverFolder = engramFolderOf(to);
  if (receiverFolder == null) {
    throw ArgumentError(
      'the receiver has no $engramPathFileName beside it, so its engram '
      'folder is unknown; open the engram in that instance once',
    );
  }
  final holders = holdersOf(to);
  if (holders == null) {
    if (!force) {
      out.writeln(
        'note: cannot tell whether the receiving app is running on this '
        'platform; make sure it is closed',
      );
    }
  } else {
    final monitors = holders.where((h) => h.isMonitor).toList();
    final others = holders.where((h) => !h.isMonitor).toList();
    if (monitors.isNotEmpty) {
      out.writeln(
        'note: ${monitors.join(', ')} is watching the receiving store; '
        'it will see the delivery land',
      );
    }
    if (others.isNotEmpty && !force) {
      throw ArgumentError(
        'the receiving store is open in another process: '
        '${others.join(', ')} — close it first (or pass --force if it is '
        'not a BrainFrame and you know what you are doing)',
      );
    }
  }

  final sender = StoreReader.open(from, label: 'sender');
  final senderFolder = engramFolderOf(from);
  final shared =
      senderFolder != null &&
      Directory(senderFolder).absolute.path ==
          Directory(receiverFolder).absolute.path;
  final receiver = await _openReceiver(to);
  final engram = FileSystemEngramStore(EngramLocation(receiverFolder));
  final mapsCopied = shared
      ? 0
      : _copyIdentityMaps(from: senderFolder, to: receiverFolder);
  final identity = await AuthoredIdentity.load(
    IdentityMap(engramRoot: receiverFolder, peerId: receiver.peerId),
  );
  final lock = NoteDocumentLock();
  final reconciler = DriftReconciler(
    database: receiver,
    engram: engram,
    lock: lock,
    identity: identity,
    noteSizeCeilingBytes: defaultNoteSizeCeilingBytes,
  );
  final outcomes = <DeliveryOutcome, int>{};
  void count(DeliveryOutcome outcome) =>
      outcomes[outcome] = (outcomes[outcome] ?? 0) + 1;

  try {
    out.writeln(
      'delivering from ${sender.peerId.substring(0, 8)} '
      'to ${receiver.peerId.toString().substring(0, 8)}'
      '${shared ? '  (shared folder: files already carry the sender\'s edits)' : ''}',
    );
    if (mapsCopied > 0) {
      out.writeln(
        'identity: $mapsCopied map file${mapsCopied == 1 ? '' : 's'} copied '
        'into the receiver\'s folder',
      );
    }
    // Step 0: the receiver's own scan, so identities meet before history
    // does — adoptions, and the election where both devices minted a path.
    // Its drift pass is step 1 for every note at once, which is right over
    // two folders and wrong over one: there the file already carries the
    // sender's edits, and a scan now would author the receiver's own copy
    // of each before the sender's arrive. Over a shared folder the map is
    // already shared, and a note the receiver has not met is created in
    // step 5 from the sender's identity instead.
    var reconciledByScan = const <String>{};
    if (!shared) {
      final scanned = await reconciler.scan();
      reconciledByScan = scanned.reconciled.toSet();
      final settled = <String>[
        if (scanned.adopted.isNotEmpty) '${scanned.adopted.length} adopted',
        if (scanned.retired.isNotEmpty)
          '${scanned.retired.length} retired (the other device\'s ULID won)',
        if (scanned.created.isNotEmpty) '${scanned.created.length} minted',
        if (scanned.reconciled.isNotEmpty)
          '${scanned.reconciled.length} reconciled',
      ];
      if (settled.isNotEmpty) {
        out.writeln('receiver scanned: ${settled.join(', ')}');
      }
    }
    final targets = <CatalogEntry>[];
    if (note != null) {
      final entry = sender.entryNamed(note);
      if (entry == null) {
        throw ArgumentError('the sender has no catalog row for $note');
      }
      targets.add(entry);
    } else {
      // Every note the sender holds a log for — except the tombstoned: a
      // retired ULID's seed, or a deleted note's history, is not wanted
      // anywhere, and its path is now another row's.
      final counts = sender.changeCounts();
      targets.addAll(
        sender.catalog().values.where(
          (e) =>
              (counts[e.ulid] ?? 0) > 0 && e.state != NoteState.tombstoned.name,
        ),
      );
      targets.sort((a, b) => a.path.compareTo(b.path));
    }

    for (final target in targets) {
      try {
        count(
          await _deliverOne(
            target,
            sender: sender,
            senderFolder: senderFolder,
            receiver: receiver,
            engram: engram,
            reconciler: reconciler,
            lock: lock,
            shared: shared,
            reconciledByScan: reconciledByScan,
            out: out,
          ),
        );
      } on Object catch (error) {
        out.writeln('${target.path}  failed: $error');
        count(DeliveryOutcome.failed);
      }
    }
    out.writeln(
      outcomes.entries.map((e) => '${e.value} ${e.key.name}').join(', '),
    );
  } finally {
    await reconciler.close();
    await identity.flush();
    receiver.close();
    sender.close();
  }
  return outcomes;
}

/// The receiver's store, opened read-write through the real store code —
/// which wants the app-data root and the engram ULID, both of which the
/// path spells out: `<root>/engrams/<ulid>/metadata.db`.
Future<MetadataDatabase> _openReceiver(String storePath) {
  final segments = File(storePath).absolute.uri.pathSegments;
  if (segments.length < 4 ||
      segments[segments.length - 3] != 'engrams' ||
      segments.last != metadataDatabaseFileName) {
    throw ArgumentError(
      '$storePath is not <root>/engrams/<ulid>/$metadataDatabaseFileName',
    );
  }
  final engramId = segments[segments.length - 2];
  final root = '/${segments.sublist(0, segments.length - 3).join('/')}';
  return MetadataDatabase.open(engramId, resolveRoot: () async => root);
}

Future<DeliveryOutcome> _deliverOne(
  CatalogEntry target, {
  required StoreReader sender,
  required String? senderFolder,
  required MetadataDatabase receiver,
  required FileSystemEngramStore engram,
  required DriftReconciler reconciler,
  required NoteDocumentLock lock,
  required bool shared,
  required Set<String> reconciledByScan,
  required StringSink out,
}) async {
  final ulid = target.ulid;
  var row = receiver.catalog.byUlid(ulid);
  var created = false;
  if (row == null) {
    final atPath = receiver.catalog.byPath(target.path);
    if (atPath != null) {
      // Both devices minted this path. The election is deterministic —
      // the lower ULID wins. Over two folders the receiver's scan has just
      // run it with the sender's map in hand, so a row still here under
      // another ULID is the winner; over a shared folder it is a race the
      // receiving app settles on its next scan.
      final receiverWins = atPath.ulid.compareTo(ulid) < 0;
      out.writeln(
        '${target.path}  skipped: both devices minted it — '
        '${receiverWins ? 'the receiver\'s ${_short(atPath.ulid)} wins over the sender\'s ${_short(ulid)}; deliver the other way' : 'the sender\'s ${_short(ulid)} wins, and the receiving app retires ${_short(atPath.ulid)} on its next scan; deliver again after'}',
      );
      return DeliveryOutcome.skipped;
    }
    final claim = target.seedClaim;
    if (claim == null) {
      out.writeln(
        '${target.path}  skipped: the sender\'s row has no seed claim to '
        'carry',
      );
      return DeliveryOutcome.skipped;
    }
    // Step 5: a note the receiver has never met. Its identity is the
    // sender's, whole, and the log about to arrive holds its text.
    row = CatalogRow(
      ulid: ulid,
      path: target.path,
      mergePolicy: MergePolicy.parse(target.mergePolicy),
      state: NoteState.live,
      seedClaim: OperationId.parse(claim),
    );
    receiver.catalog.upsert(row);
    created = true;
  }
  if (row.state == NoteState.tombstoned) {
    out.writeln('${row.path}  skipped: tombstoned on the receiver');
    return DeliveryOutcome.skipped;
  }
  final path = row.path;
  final storage = receiver.crdt.changeStorageForDocument(ulid);
  final have = {for (final c in storage.getChanges()) c.id.toString()};
  final fresh = [
    for (final stored in sender.changesFor(ulid))
      if (!have.contains(stored.changeId)) stored.change,
  ];
  final wasPending = row.state == NoteState.historyPending;
  if (fresh.isEmpty && !wasPending && !created) {
    out.writeln('$path  up to date');
    return DeliveryOutcome.upToDate;
  }
  if (fresh.isEmpty && wasPending && have.isEmpty) {
    out.writeln('$path  skipped: the sender has no log for it either');
    return DeliveryOutcome.skipped;
  }

  // Step 1: the receiver's own drift, as its own operations, before
  // anything else arrives — only where the file could not already hold the
  // sender's edits.
  var reconciledFirst = reconciledByScan.contains(path);
  if (!shared && !wasPending && row.mergePolicy == MergePolicy.fugueText) {
    reconciledFirst = await reconciler.reconcile(path) || reconciledFirst;
    row = receiver.catalog.byUlid(ulid)!;
  }

  return lock.run(() async {
    // Step 2: import.
    if (fresh.isNotEmpty) storage.saveChanges(fresh);
    final arrived = '+${fresh.length} change${fresh.length == 1 ? '' : 's'}';
    final phrases = <String>[
      if (created) 'created on the receiver',
      arrived,
      if (reconciledFirst) 'local drift reconciled first',
    ];

    // Step 3: a pending row has a history now.
    if (wasPending) {
      row = CatalogRow(
        ulid: row!.ulid,
        path: row!.path,
        mergePolicy: row!.mergePolicy,
        state: NoteState.live,
        materializedHash: row!.materializedHash,
        size: row!.size,
        mtimeUtc: row!.mtimeUtc,
        sketch: row!.sketch,
        seedClaim: row!.seedClaim,
      );
      receiver.catalog.upsert(row!);
      phrases.add('promoted historyPending → live');
    }

    // Steps 3 and 4: the file and the document brought to agree.
    if (row!.mergePolicy == MergePolicy.fugueText) {
      final onDisk = await engram.statFile(path) == null
          ? null
          : await engram.readBytes(path);
      final note = NoteDocument.open(store: receiver, ulid: ulid);
      try {
        if (wasPending && onDisk != null) {
          // The file was the authority: what it holds beyond the arrived
          // document becomes this device's operations, once.
          final before = note.value;
          note.applyExternalText(utf8.decode(onDisk));
          final delta = describeDelta(before, note.value);
          if (delta != 'no change') phrases.add('file diffed in: $delta');
        }
        final committed = await materializeNote(
          store: receiver,
          engram: engram,
          note: note,
          onDiskHash: onDisk == null ? null : contentHash(onDisk),
        );
        phrases.add(
          onDisk != null && committed.materializedHash == contentHash(onDisk)
              ? 'file already the projection'
              : 'materialized ${committed.materializedHash!.substring(0, 12)}',
        );
      } finally {
        note.dispose();
      }
    } else {
      phrases.add(
        await _settleBlob(
          row!,
          receiver: receiver,
          engram: engram,
          senderFolder: senderFolder,
          shared: shared,
        ),
      );
    }
    out.writeln('$path  ${phrases.join('; ')}');
    return DeliveryOutcome.delivered;
  });
}

/// Copies every identity-map file in the sender's folder that the
/// receiver's folder lacks or holds a different version of. Returns how
/// many were written. The files are whole, small, and rewritten whole by
/// their owner, so a byte comparison is the right test.
int _copyIdentityMaps({required String? from, required String to}) {
  if (from == null) return 0;
  final source = Directory('$from/.brainframe/shared');
  if (!source.existsSync()) return 0;
  final target = Directory('$to/.brainframe/shared')
    ..createSync(recursive: true);
  var copied = 0;
  for (final entity in source.listSync()) {
    if (entity is! File || !entity.path.endsWith('.db')) continue;
    final destination = File('${target.path}/${entity.uri.pathSegments.last}');
    final bytes = entity.readAsBytesSync();
    if (destination.existsSync() &&
        _sameBytes(destination.readAsBytesSync(), bytes)) {
      continue;
    }
    destination.writeAsBytesSync(bytes, flush: true);
    copied++;
  }
  return copied;
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// A blob after import: the register's winner against the file's bytes.
Future<String> _settleBlob(
  CatalogRow row, {
  required MetadataDatabase receiver,
  required FileSystemEngramStore engram,
  required String? senderFolder,
  required bool shared,
}) async {
  final blob = BlobDocument.open(store: receiver, ulid: row.ulid);
  try {
    final winner = blob.state;
    final present = await engram.statFile(row.path) != null;
    final onDisk = present ? await digestFile(engram, row.path) : null;
    if (winner == null) {
      if (onDisk != null) {
        blob.record(onDisk);
        await recordFileState(
          store: receiver,
          engram: engram,
          row: row,
          digest: onDisk,
        );
      }
      return 'no claim in the log; the file stays';
    }
    if (onDisk != null && onDisk.hash == winner.hash) {
      await recordFileState(
        store: receiver,
        engram: engram,
        row: row,
        digest: onDisk,
      );
      return 'file already matches the winning claim';
    }
    // The log carries the decision, not the bytes (Decision 3). In a shared
    // folder the sender has written them here already, so a mismatch is a
    // later local write; otherwise the sender's copy may hold them.
    if (!shared && senderFolder != null) {
      final source = File('$senderFolder/${row.path}');
      if (source.existsSync()) {
        final bytes = await source.readAsBytes();
        final digest = ContentDigest.of(bytes);
        if (digest.hash == winner.hash) {
          await engram.writeBytes(row.path, bytes);
          await recordFileState(
            store: receiver,
            engram: engram,
            row: row,
            digest: digest,
          );
          return 'bytes copied from the sender (${bytes.length} bytes)';
        }
      }
    }
    return 'winning claim ${winner.hash.substring(0, 12)} is not what the '
        'file holds, and its bytes are not available here';
  } finally {
    blob.dispose();
  }
}

String _short(String ulid) =>
    '${ulid.substring(0, 6)}…${ulid.substring(ulid.length - 4)}';
