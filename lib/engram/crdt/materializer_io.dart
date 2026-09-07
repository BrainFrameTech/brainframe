/// The only writer of a note path (Decision 4), and the write ordering that
/// makes a crash mid-save recoverable (Decision 5).
///
/// `dart:io`-only by way of [NoteDocument], which needs the SQLite op-log.
/// Named `_io` for that reason rather than the `materializer.dart` the plan's
/// file layout sketched, matching `note_document_io.dart`: a live document
/// cannot exist on web at all, so everything that touches one imports directly
/// rather than through a seam.
///
/// **The file is a projection.** The CRDT is the authority for a `fugueText`
/// note and the `.md` file is what that value looks like on disk. Nothing else
/// in the app calls `writeString` on a note path — the one bounded exception is
/// a history-pending note, whose op-log has not arrived, and which is written
/// directly the way notes were written before this design. That exception
/// cannot reach this file: [NoteDocument.open] refuses to open a
/// history-pending note at all, so there is no document here to materialize.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../engram_store.dart';
import 'catalog.dart';
import 'drift.dart';
import 'metadata_db_io.dart';
import 'note_document_io.dart';

/// Writes [note]'s current value to its file and records what was written.
///
/// The order is **materialize → write file → commit catalog row**, and it is
/// never reordered. A crash between the write and the commit leaves the file
/// changed and the recorded hash stale, so the next scan reports drift on a
/// file we wrote, re-diffs our own output against the CRDT, finds no semantic
/// difference, and re-records the hash — a redundant diff, not lost data.
/// Committing the hash *before* the write inverts that into silent loss: the
/// catalog would claim bytes that a crash stopped us from writing, and the next
/// scan would see no drift and never reconcile the edit still sitting on disk.
///
/// **Unconditional, and deliberately so.** There is no "has anything changed?"
/// gate here, and callers must not add one. Since Decision 10, a file whose
/// terminators are not canonical reconciles to *zero* operations and still
/// needs rewriting, so "did reconciliation produce operations?" no longer
/// implies "the file is already correct". A caller that skips this on that
/// basis leaves the hash stale and reports drift on the same file on every scan
/// for the rest of its life, silently. Before Decision 10 that shortcut
/// happened to be safe; it is not now.
///
/// Returns the committed row, so a caller holding a stale one does not have to
/// re-read the catalog to see what was recorded.
///
/// Throws [UnknownNoteException] if the catalog has no row for the note.
Future<CatalogRow> materializeNote({
  required MetadataDatabase store,
  required EngramStore engram,
  required NoteDocument note,
}) async {
  final row = store.catalog.byUlid(note.ulid);
  if (row == null) throw UnknownNoteException(note.ulid);

  // 1. Materialize. The projection is the sequence's value verbatim — no
  //    re-serialization on the way out, which is what keeps it byte-stable.
  //    Frontmatter is text inside the sequence, never a parsed structure, so
  //    there is nothing here that could reorder a key or requote a value.
  final bytes = Uint8List.fromList(utf8.encode(note.value));
  final hash = contentHash(bytes);

  // 2. Write the file. The store's write is atomic, so a reader sees the whole
  //    old file or the whole new one.
  await engram.writeBytes(row.path, bytes);

  // 3. Commit the row, describing exactly what step 2 put on disk. The mtime
  //    is read back rather than guessed, because the filesystem sets it.
  final stat = await engram.statFile(row.path);
  final committed = CatalogRow(
    ulid: row.ulid,
    path: row.path,
    mergePolicy: row.mergePolicy,
    state: row.state,
    materializedHash: hash,
    size: bytes.length,
    // Null if the file vanished between the write and the stat. That degrades
    // to a pre-filter that always says "maybe" and therefore always hashes —
    // a wasted read, never a missed edit, which is the direction this whole
    // decision leans.
    mtimeUtc: stat?.mtimeUtc,
    sketch: row.sketch,
    seedClaim: row.seedClaim,
  );
  // One statement, so it is atomic without an explicit transaction. If this
  // ever grows to touch a second row, it needs one — the design asks for the
  // catalog update to be a unit, and today that is true by construction.
  store.catalog.upsert(committed);
  return committed;
}

/// Whether the file behind [row] has changed since this device last wrote it.
///
/// Encodes Decision 5's two-stage test so a caller cannot accidentally perform
/// only the cheap half: the size/mtime pre-filter can rule the file *out*, and
/// anything it does not rule out is hashed. A missing file counts as drift —
/// what to do about it is Decision 7's question, not this one's.
Future<bool> noteFileHasDrifted(EngramStore engram, CatalogRow row) async {
  final stat = await engram.statFile(row.path);
  if (stat == null) return true;
  if (!mayHaveDrifted(row, stat)) return false;
  return hasDrifted(row, contentHash(await engram.readBytes(row.path)));
}
