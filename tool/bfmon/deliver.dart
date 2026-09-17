/// `deliver`: one device's operations carried into another's op-log, by
/// hand — the local half of sync (#67), with a person standing in for the
/// transport.
///
/// The op-log is a table keyed `(document_id, change_id)`, and every row for
/// a note is a complete causal set, so *moving* the rows is three SQL
/// statements. What makes delivery more than that is what the receiver must
/// do once they land, and nothing in the app does it yet, because nothing
/// has ever delivered anything:
///
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
/// through `/proc`; elsewhere it cannot be, and `--force` says you did.
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

import 'replay.dart';
import 'store.dart';

/// What happened to one note, for the summary.
enum DeliveryOutcome { delivered, upToDate, skipped, failed }

/// Whether another process has [path] open — the receiving app, typically.
///
/// Linux only, through `/proc/<pid>/fd`; null where it cannot be told.
/// Only this user's processes are readable, which is the case that matters:
/// the app is theirs.
bool? isOpenByAnotherProcess(String path) {
  if (!Platform.isLinux) return null;
  final target = File(path).absolute.path;
  final proc = Directory('/proc');
  if (!proc.existsSync()) return null;
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
        if (Link(link.path).targetSync() == target) return true;
      } on FileSystemException {
        continue;
      }
    }
  }
  return false;
}

/// Carries the sender's log for [note] — a path or a ULID, or every note
/// when null — into the receiver's store, and brings the receiver's files
/// up to date with what arrived. Prints one line per note to [out].
///
/// Throws [ArgumentError] for a refusal: the same store on both sides, a
/// receiver with no folder label, or a receiver still open elsewhere
/// without [force].
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
  switch (isOpenByAnotherProcess(to)) {
    case true when !force:
      throw ArgumentError(
        'the receiving store is open in another process — close that '
        'BrainFrame first (or pass --force if you know what you are doing)',
      );
    case null when !force:
      out.writeln(
        'note: cannot tell whether the receiving app is running on this '
        'platform; make sure it is closed',
      );
    default:
      break;
  }

  final sender = StoreReader.open(from, label: 'sender');
  final senderFolder = engramFolderOf(from);
  final shared =
      senderFolder != null &&
      Directory(senderFolder).absolute.path ==
          Directory(receiverFolder).absolute.path;
  final receiver = await _openReceiver(to);
  final engram = FileSystemEngramStore(EngramLocation(receiverFolder));
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
    final targets = <CatalogEntry>[];
    if (note != null) {
      final entry = sender.entryNamed(note);
      if (entry == null) {
        throw ArgumentError('the sender has no catalog row for $note');
      }
      targets.add(entry);
    } else {
      final counts = sender.changeCounts();
      targets.addAll(
        sender.catalog().values.where((e) => (counts[e.ulid] ?? 0) > 0),
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
  required StringSink out,
}) async {
  final ulid = target.ulid;
  var row = receiver.catalog.byUlid(ulid);
  if (row == null) {
    out.writeln(
      '${target.path}  skipped: the receiver has no row for ${_short(ulid)} '
      '— open the engram there so it adopts the identity first',
    );
    return DeliveryOutcome.skipped;
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
  if (fresh.isEmpty && !wasPending) {
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
  var reconciledFirst = false;
  if (!shared && !wasPending && row.mergePolicy == MergePolicy.fugueText) {
    reconciledFirst = await reconciler.reconcile(path);
    row = receiver.catalog.byUlid(ulid)!;
  }

  return lock.run(() async {
    // Step 2: import.
    if (fresh.isNotEmpty) storage.saveChanges(fresh);
    final arrived = '+${fresh.length} change${fresh.length == 1 ? '' : 's'}';
    final phrases = <String>[
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
