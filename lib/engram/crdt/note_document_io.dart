/// One note's CRDT document, over the device-local op-log.
///
/// `dart:io`-only, because the op-log is SQLite and `crdt_lf_sqlite` rides on
/// `dart:ffi`. Nothing here is exported through `metadata_db.dart`'s seam:
/// a live document cannot exist on web at all, so code that touches one is
/// `dart:io`-only too and imports this file directly, the way
/// `fs_store_io.dart` is imported directly.
library;

import 'package:crdt_lf/crdt_lf.dart';
import 'package:crdt_lf_sqlite/crdt_lf_sqlite.dart';
import 'package:hlc_dart/hlc_dart.dart';

import '../id.dart';
import 'catalog.dart';
import 'metadata_db_io.dart';

/// The handler id for the whole-note Fugue sequence.
///
/// One handler holds the entire file — body and frontmatter as a single
/// sequence — which is the locked storage model the frozen suite in
/// `test/crdt/` is written against. It uses this same id, deliberately: the
/// suite proves properties of the model this file instantiates, and two
/// spellings would let them drift apart.
const String noteHandlerId = 'note';

/// Thrown when a note has no catalog row on this device.
///
/// Distinct from a note whose history has not arrived: this device has never
/// heard of the ULID at all, which means the caller's id came from somewhere
/// that is not the catalog.
class UnknownNoteException implements Exception {
  const UnknownNoteException(this.ulid);

  final String ulid;

  @override
  String toString() => 'UnknownNoteException: no catalog row for note $ulid';
}

/// Thrown when a note's op-log has not reached this device yet.
///
/// The note is *history pending* (design Decision 7): its ULID was adopted
/// from the identity map, but no operations back it here and this device does
/// not hold its seed claim. Such a note is readable and editable as an
/// ordinary file until a log arrives over **#67** — what it must never get is
/// a freshly seeded document, so this raises instead of handing back an empty
/// one that a caller would then fill.
class NoteHistoryPendingException implements Exception {
  const NoteHistoryPendingException(this.ulid);

  final String ulid;

  @override
  String toString() =>
      'NoteHistoryPendingException: note $ulid has no local history, and its '
      'seed claim belongs to another peer';
}

/// A live `CRDTDocument` for one note, persisted to this engram's op-log.
///
/// **Hold one at a time, and [dispose] it.** The Performance envelope puts a
/// Fugue tree at roughly 470 bytes per character, so a document is
/// deliberately expensive to keep open: the note ULID identifies it, the
/// op-log outlives it, and it is rebuilt from storage on demand.
///
/// The `documentId` handed to `crdt_lf` **is** the note ULID. Note identity
/// and CRDT document identity are one string, so nothing has to map between
/// them and nothing can disagree about which document a change belongs to.
class NoteDocument {
  NoteDocument._(
    this.ulid,
    this.document,
    this.text,
    this._changes,
    this._savedVersion,
  );

  /// The note's ULID, which is also the CRDT `documentId`.
  final String ulid;

  /// The underlying document. Exposed for the materializer and the
  /// reconciler, which need the change-level API rather than the text.
  final CRDTDocument document;

  /// The single whole-note Fugue sequence.
  final CRDTFugueTextHandler text;

  final CRDTSqliteChangeStorage _changes;

  /// The document frontier as of the last [_persist].
  ///
  /// Only changes that are not ancestors of this are written on the next save.
  /// The op-log's `INSERT OR REPLACE` makes re-writing a change harmless, so
  /// this is an optimization over a correct baseline rather than a bet on
  /// getting the frontier exactly right — and
  /// [note_document_io_test.dart](../../../test/engram/crdt/note_document_io_test.dart)
  /// pins that the stored change count matches the document's after a run of
  /// edits, which is what would fail if it ever under-saved.
  Set<OperationId> _savedVersion;

  /// The note's current text — body and frontmatter, one sequence.
  String get value => text.value;

  /// Mints a new note: a fresh ULID, a seeded document, and a catalog row.
  ///
  /// **This is the only place a document is ever seeded.** Seeding builds the
  /// per-character `(peerId, counter)` element identities that Fugue merges
  /// on, so a second device seeding the same ULID produces a disjoint
  /// character universe and the eventual merge concatenates both texts rather
  /// than recognising them as one — content duplication that looks like a
  /// successful merge. Pinned by
  /// [independent_seed_duplication_test.dart](../../../test/crdt/independent_seed_duplication_test.dart).
  ///
  /// The seed claim is recorded on the catalog row as this device took it, so
  /// a later adopting device can tell that a history exists somewhere.
  ///
  /// [path] is engram-relative; its extension derives the merge policy, fixed
  /// here at creation. Throws if a findable note already holds that path — the
  /// catalog's own constraint, surfaced rather than merged.
  static NoteDocument mint({
    required MetadataDatabase store,
    required String path,
    String content = '',
  }) {
    final ulid = newUlid();
    final document = CRDTDocument(
      peerId: store.peerId,
      documentId: ulid,
      initialClock: HybridLogicalClock.now(),
    );
    final text = CRDTFugueTextHandler(document, noteHandlerId);
    if (content.isNotEmpty) text.insert(0, content);

    // An empty saved frontier, not the document's current one: the seed
    // change already exists by this point, and treating it as saved would
    // persist a catalog row whose history was never written.
    final note = NoteDocument._(
      ulid,
      document,
      text,
      store.crdt.changeStorageForDocument(ulid),
      const <OperationId>{},
    );
    // The row goes in before the changes so that a crash between the two
    // leaves a note with a seed claim and no history — which reopens as our
    // own empty note — rather than history no row can name.
    store.catalog.upsert(
      CatalogRow(
        ulid: ulid,
        path: path,
        mergePolicy: mergePolicyForPath(path),
        state: NoteState.live,
        seedClaim: OperationId(store.peerId, document.hlc),
      ),
    );
    note._persist();
    return note;
  }

  /// Reopens the note [ulid], rebuilding its document from the op-log.
  ///
  /// Never seeds. An empty op-log is only acceptable when this device holds
  /// the note's seed claim — an empty note we minted ourselves — and is
  /// otherwise a [NoteHistoryPendingException]. That distinction is the guard
  /// the design asks for, in code rather than in prose: the failure it
  /// prevents duplicates content while looking like a clean merge.
  ///
  /// Throws [UnknownNoteException] if the catalog has no row for [ulid].
  static NoteDocument open({
    required MetadataDatabase store,
    required String ulid,
  }) {
    final row = store.catalog.byUlid(ulid);
    if (row == null) throw UnknownNoteException(ulid);

    final changes = store.crdt.changeStorageForDocument(ulid);
    final stored = changes.getChanges();
    if (stored.isEmpty && row.seededBy != store.peerId) {
      throw NoteHistoryPendingException(ulid);
    }

    // A fresh clock is safe: applying a change always advances the document's
    // clock past it, so importing the stored log leaves this document ordered
    // after everything it just read.
    final document = CRDTDocument(
      peerId: store.peerId,
      documentId: ulid,
      initialClock: HybridLogicalClock.now(),
    );
    final text = CRDTFugueTextHandler(document, noteHandlerId);
    document.importChanges(stored);

    // Everything just imported is by definition already in the op-log, so the
    // frontier after the import is exactly what has been saved.
    return NoteDocument._(ulid, document, text, changes, document.version);
  }

  /// Inserts [value] at [index], and commits the operation to the op-log.
  void insert(int index, String value) {
    text.insert(index, value);
    _persist();
  }

  /// Deletes [count] characters at [index], and commits the operation.
  void delete(int index, int count) {
    text.delete(index, count);
    _persist();
  }

  /// Writes everything not yet in the op-log.
  ///
  /// Called after every mutation, so a document that is disposed — or a
  /// process that dies — never leaves an edit only in memory. Durability is
  /// the whole point of this step: the alternative is an editor whose history
  /// exists until the app closes.
  void _persist() {
    final pending = document.exportChanges(from: _savedVersion);
    if (pending.isEmpty) return;
    _changes.saveChanges(pending);
    _savedVersion = document.version;
  }

  /// Releases the document. Idempotent; the note's history stays in the
  /// op-log, and [open] rebuilds from it.
  void dispose() => document.dispose();
}
