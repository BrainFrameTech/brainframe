/// One `blobLww` note's CRDT document: a register over the op-log, never the
/// bytes.
///
/// `dart:io`-only for the reason [NoteDocument] is, and imported directly by
/// the same callers. Decision 3 in code: the op-log carries what
/// last-writer-wins actually requires — an ordering, and enough about the
/// value to know which one won — and the file stays in the engram as the
/// ordinary file it already is. The register holds a [ContentDigest] — the
/// content hash and size; the HLC/peerID stamp the comparator needs is the
/// operation's own id, so it is not repeated inside the value.
///
/// **Nothing here sees the bytes.** [mint] and [record] take the digest, and
/// the caller computes it over a stream ([digestFile]) — a video dropped into
/// the folder is a blob like any other, and the smallest target, a Pi Zero
/// 2 W with 512 MB, cannot be expected to hold one. The one thing this file
/// knows about a blob's content is forty bytes long.
///
/// **A blob never enters the diff path.** Not by a check at the door but by
/// construction: there is no text handler on this document to diff into, and
/// [NoteDocument] refuses a blob, so the only thing a PNG's history can ever
/// contain is a sequence of "the file was these bytes" claims. Concurrent
/// claims resolve by the library's replay order, which is the locked
/// comparator — HLC first, then peerID — and every device replays the same
/// way, so every device names the same winner.
///
/// **The v1 boundary is deliberate.** A peer receiving one of these operations
/// has the *decision* but not the *bytes*; carrying bytes is **#67**'s, with
/// every other transport question. Locally, where the file and the op-log
/// share one folder, nothing is missing — which is why there is no
/// materializer for a blob: the bytes on disk are the only copy, and the
/// register describes them rather than the other way round.
library;

import 'dart:typed_data';

import 'package:crdt_lf/crdt_lf.dart';
import 'package:hlc_dart/hlc_dart.dart';

import '../id.dart';
import 'catalog.dart';
import 'drift.dart';
import 'metadata_db_io.dart';
import 'note_document_io.dart';

/// The handler id for a blob's register — the counterpart of
/// [noteHandlerId], and different from it so a change can never be routed to
/// the wrong shape of handler by a document that has both ids in its log.
const String blobHandlerId = 'blob';

/// The register's stable type tag.
///
/// The library defaults to `runtimeType.toString()`, which a minified build
/// does not preserve, and this tag is written into every change envelope and
/// read back on every open. Persisted data needs a constant.
const String blobHandlerType = 'BrainFrameBlobRegister';

/// [ContentDigest] on the wire: the 32 hash bytes, then the size as a varint.
///
/// The hash is what decides whether two claims are the same claim; the size
/// is a cheap cross-check the scan's pre-filter can use without hashing, and
/// costs a varint.
///
/// Forty-odd bytes a claim, against a JSON encoding of about a hundred. Not
/// for the saving — the change envelope around it is larger than either —
/// but because a fixed binary layout is a statement that this value has
/// exactly two fields, and a reader of a future build can tell a truncated
/// record from a valid one.
class ContentDigestCodec implements ValueCodec<ContentDigest> {
  const ContentDigestCodec();

  static const int _hashBytes = 32;

  @override
  Uint8List encode(ContentDigest value) {
    if (value.hash.length != _hashBytes * 2) {
      throw FormatException('not a SHA-256 hex digest: "${value.hash}"');
    }
    final out = BytesBuilder(copy: false);
    for (var i = 0; i < _hashBytes; i++) {
      out.addByte(int.parse(value.hash.substring(i * 2, i * 2 + 2), radix: 16));
    }
    UVarint.write(value.size, out);
    return out.toBytes();
  }

  @override
  ContentDigest decode(Uint8List bytes) {
    if (bytes.length < _hashBytes + 1) {
      throw const FormatException('Truncated blob state');
    }
    final hash = StringBuffer();
    for (var i = 0; i < _hashBytes; i++) {
      hash.write(bytes[i].toRadixString(16).padLeft(2, '0'));
    }
    final size = UVarint.read(bytes, offset: _hashBytes);
    return ContentDigest(hash: hash.toString(), size: size.value);
  }
}

/// A live `CRDTDocument` for one `blobLww` note, persisted to this engram's
/// op-log.
///
/// **Hold one at a time, and [dispose] it** — cheaper than a text note, since
/// a register replays in constant space, but the same discipline keeps the
/// two shapes interchangeable at every call site.
///
/// **`blobLww` only.** [mint] and [open] refuse a text note, the mirror of
/// [NoteDocument] refusing a blob: one shape per policy, and a call site that
/// picks the wrong one fails at once rather than producing an empty history.
class BlobDocument extends PersistedDocument {
  BlobDocument._(
    super.ulid,
    super.document,
    this.register,
    super.changes,
    super.savedVersion,
  );

  /// The one register. Exposed like [NoteDocument.text], for a caller that
  /// needs the handler rather than its value.
  final CRDTRegisterHandler<ContentDigest> register;

  /// What the history says the file is, or null before the first claim —
  /// which [mint] makes, so a document this device opened never reads null.
  ContentDigest? get state => register.value;

  /// Mints a new blob note: a fresh ULID, a register set to [digest], and a
  /// catalog row.
  ///
  /// [digest] is what the caller established about the file, over a stream;
  /// the bytes themselves never come this way. The first claim is written
  /// unconditionally, even for an empty file — a zero-byte image is a claim
  /// like any other — so a blob's op-log is never empty after a mint, and
  /// [open] never mistakes one of ours for a note whose history is elsewhere.
  ///
  /// [path] is engram-relative; its extension derives the merge policy, fixed
  /// here at creation, and it must be `blobLww` — text is minted through
  /// [NoteDocument.mint], and an [ArgumentError] says so. Throws if a
  /// findable note already holds that path — the catalog's own constraint,
  /// surfaced rather than merged.
  static BlobDocument mint({
    required MetadataDatabase store,
    required String path,
    required ContentDigest digest,
  }) {
    final policy = mergePolicyForPath(path);
    if (policy != MergePolicy.blobLww) {
      throw ArgumentError.value(
        path,
        'path',
        'a ${policy.name} note is a text sequence; mint it as a NoteDocument',
      );
    }
    final ulid = newUlid();
    final document = CRDTDocument(
      peerId: store.peerId,
      documentId: ulid,
      initialClock: HybridLogicalClock.now(),
    );
    final register = _registerOn(document);
    register.set(digest);

    final note = BlobDocument._(
      ulid,
      document,
      register,
      store.crdt.changeStorageForDocument(ulid),
      const <OperationId>{},
    );
    // Row before changes, for the reason NoteDocument.mint gives: a crash
    // between the two leaves a claimed note with no history, which reopens as
    // ours, rather than history no row can name.
    store.catalog.upsert(
      CatalogRow(
        ulid: ulid,
        path: path,
        mergePolicy: policy,
        state: NoteState.live,
        seedClaim: OperationId(store.peerId, document.hlc),
      ),
    );
    note.persist();
    return note;
  }

  /// Reopens the blob note [ulid], rebuilding its register from the op-log.
  ///
  /// Never seeds: an empty op-log this device did not seed is a
  /// [NoteHistoryPendingException], as [storedHistoryOf] explains. Throws
  /// [UnknownNoteException] if the catalog has no row for [ulid], and
  /// [ArgumentError] if the row is a text note.
  static BlobDocument open({
    required MetadataDatabase store,
    required String ulid,
  }) {
    final (:row, :changes, :stored) = storedHistoryOf(store, ulid);
    if (row.mergePolicy != MergePolicy.blobLww) {
      throw ArgumentError.value(
        ulid,
        'ulid',
        'a ${row.mergePolicy.name} note is a text sequence; open it as a '
            'NoteDocument',
      );
    }
    final document = CRDTDocument(
      peerId: store.peerId,
      documentId: ulid,
      initialClock: HybridLogicalClock.now(),
    );
    final register = _registerOn(document);
    document.importChanges(stored);
    return BlobDocument._(ulid, document, register, changes, document.version);
  }

  /// Claims that the file is now [digest]: a last-writer-wins write, stamped
  /// with this device's clock and id, and committed to the op-log.
  ///
  /// This is how an external replacement of an image becomes history — the
  /// scan finds the file's hash no longer matches the catalog's, and records
  /// what it found as a write by this device at the time it noticed. A claim
  /// identical to the current one is not written: it would say nothing the
  /// log does not already say, and the caller has usually just compared the
  /// hashes anyway.
  ///
  /// Returns whether a claim was written.
  bool record(ContentDigest digest) {
    if (digest == state) return false;
    register.set(digest);
    persist();
    return true;
  }

  static CRDTRegisterHandler<ContentDigest> _registerOn(
    CRDTDocument document,
  ) => CRDTRegisterHandler<ContentDigest>(
    document,
    blobHandlerId,
    valueCodec: const ContentDigestCodec(),
    handlerType: blobHandlerType,
  );
}
