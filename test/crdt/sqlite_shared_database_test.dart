// crdt_lf_sqlite must co-exist inside a database BrainFrame owns.
//
// The companion smoke test (sqlite_storage_smoke_test.dart) only asks whether
// the dependency functions at all, using a database the library creates and
// owns end to end. This file asserts a stronger property that BrainFrame's
// storage design depends on: the CRDT oplog is **not** entitled to a private
// database file. `CRDTSqlite.fromDatabase` takes a connection the consumer
// already opened and manages, and its DDL is `CREATE TABLE IF NOT EXISTS`, so
// the CRDT tables can be injected into an existing schema without disturbing
// it.
//
// Why this matters here rather than later: an engram's device-local
// `metadata.db` holds BrainFrame's own tables *and* the CRDT persistence
// tables together on one connection, so the catalog and the op-log commit
// inside one transaction boundary. If the library instead demanded exclusive
// ownership of a database, that design would have to change — and the time to
// find that out is now, while the dependency is one line in pubspec.yaml, not
// after the sync layer is written against the assumption.
//
// CORRECTION: an earlier version of this header said one file per engram is
// what makes an engram "copyable, backup-able, and syncable as a unit". It is
// not. `metadata.db` lives in the platform app-data directory and never
// travels — a live database in a synced folder is corrupted rather than merely
// stale. What travels with an engram is the markdown plus the small identity
// map in `.brainframe/shared/`. See docs/design/note-identity-and-crdt.md,
// Decision 2.
//
// So these tests pin co-existence in both directions: BrainFrame's tables and
// data survive the CRDT schema being injected, the CRDT data round-trips
// through the shared connection, and both survive a close/reopen of the same
// file. Injection is also asserted to be repeatable, since every open of an
// existing engram will re-run it.

import 'dart:io';

import 'package:crdt_lf_sqlite/crdt_lf_sqlite.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sq;

import 'support/peer_ids.dart';
import 'support/replica.dart';

/// A stand-in for a BrainFrame-owned table living in the same database as the
/// CRDT oplog — deliberately not CRDT-related, so any interference between the
/// two schemas shows up as this table's data going missing or changing.
///
/// `bf_`-prefixed because every table BrainFrame creates is (see
/// lib/engram/crdt/schema.dart). This test is the reason the rule exists: it
/// is the one place where both schemas are visible side by side, and an
/// unprefixed `notes` here would model precisely the collision the prefix
/// prevents.
const String kNotesDdl = '''
CREATE TABLE bf_notes (
  path     TEXT PRIMARY KEY,
  title    TEXT NOT NULL
);
''';

/// Every table name in [db], excluding SQLite's own internal bookkeeping.
Set<String> tableNames(sq.Database db) {
  final rows = db.select(
    "SELECT name FROM sqlite_master WHERE type = 'table' "
    "AND name NOT LIKE 'sqlite_%' ORDER BY name",
  );
  return {for (final row in rows) row['name'] as String};
}

/// Reads back the stand-in consumer table as path -> title.
Map<String, String> readNotes(sq.Database db) {
  final rows = db.select('SELECT path, title FROM bf_notes ORDER BY path');
  return {
    for (final row in rows) row['path'] as String: row['title'] as String,
  };
}

void main() {
  group('crdt_lf_sqlite shares a consumer-managed database', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('brainframe_crdt_sqlite');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    // The core assertion, in one pass over a real file: BrainFrame creates and
    // populates its own table FIRST, the CRDT schema is injected into that same
    // live connection SECOND, and afterwards the file holds both — the original
    // rows untouched and the CRDT changes readable.
    test('injects its schema into an existing database without disturbing it',
        () {
      final path = '${tempDir.path}/engram.db';
      final db = sq.sqlite3.open(path);
      addTearDown(db.close);

      // 1. BrainFrame's own schema and data exist first.
      db
        ..execute(kNotesDdl)
        ..execute(
          'INSERT INTO bf_notes (path, title) VALUES (?, ?)',
          ['inbox/today.md', 'Today'],
        )
        ..execute(
          'INSERT INTO bf_notes (path, title) VALUES (?, ?)',
          ['refs/crdt.md', 'CRDT notes'],
        );
      expect(tableNames(db), {'bf_notes'});

      // 2. The CRDT schema is injected into that SAME connection.
      final crdt = CRDTSqlite.fromDatabase(db);

      // Both schemas now co-exist — the consumer table was not dropped,
      // renamed, or replaced.
      expect(
        tableNames(db),
        {'bf_notes', 'changes', 'snapshots'},
        reason: 'CRDT tables are added alongside the consumer table',
      );

      // 3. The consumer's rows survived injection byte for byte.
      expect(readNotes(db), {
        'inbox/today.md': 'Today',
        'refs/crdt.md': 'CRDT notes',
      });

      // 4. CRDT data round-trips through the shared connection.
      final author = Replica.named(peerA, label: 'author');
      author.note.insert(0, 'shared database note');
      crdt
          .changeStorageForDocument(kDocumentId)
          .saveChanges(author.exportChanges());

      final restored = Replica.named(peerB, label: 'restored');
      restored.importChanges(
        crdt.changeStorageForDocument(kDocumentId).getChanges(),
      );
      expect(restored.text, 'shared database note');

      // 5. Writing CRDT data did not disturb the consumer table either, and
      // the consumer can still write to its own table afterwards.
      expect(readNotes(db).length, 2);
      db.execute(
        'INSERT INTO bf_notes (path, title) VALUES (?, ?)',
        ['inbox/later.md', 'Later'],
      );
      expect(readNotes(db).length, 3);
    });

    // Durability across sessions: close the file, reopen it, and BOTH halves
    // are still there. This is the assertion that would fail if the CRDT
    // tables lived somewhere else, or if either schema were only ever
    // in-memory. (Reopening on *this* device, not handing the file to a peer —
    // see the correction in the header.)
    test('both schemas survive a close and reopen of the same file', () {
      final path = '${tempDir.path}/engram.db';

      // --- session one: write both halves, then close the file entirely. ---
      final first = sq.sqlite3.open(path);
      first
        ..execute(kNotesDdl)
        ..execute(
          'INSERT INTO bf_notes (path, title) VALUES (?, ?)',
          ['inbox/today.md', 'Today'],
        );
      final firstCrdt = CRDTSqlite.fromDatabase(first);
      final author = Replica.named(peerA, label: 'author');
      author.note.insert(0, 'durable across reopen');
      firstCrdt
          .changeStorageForDocument(kDocumentId)
          .saveChanges(author.exportChanges());
      firstCrdt.close();

      // --- session two: a fresh connection to the same path. ---
      final second = sq.sqlite3.open(path);
      addTearDown(second.close);

      expect(
        tableNames(second),
        {'bf_notes', 'changes', 'snapshots'},
        reason: 'both schemas persisted to the file',
      );
      expect(readNotes(second), {'inbox/today.md': 'Today'});

      // Re-injecting on every open is the real usage pattern (the app cannot
      // know whether this engram has been opened before), so it must be
      // idempotent — CREATE TABLE IF NOT EXISTS, never a destructive reset.
      final secondCrdt = CRDTSqlite.fromDatabase(second);
      expect(
        readNotes(second),
        {'inbox/today.md': 'Today'},
        reason: 're-injection must not clear consumer data',
      );

      final restored = Replica.named(peerB, label: 'restored');
      restored.importChanges(
        secondCrdt.changeStorageForDocument(kDocumentId).getChanges(),
      );
      expect(
        restored.text,
        'durable across reopen',
        reason: 'CRDT changes survived the close/reopen cycle',
      );
    });

    // Deleting one document's CRDT data is a real operation BrainFrame will
    // perform (Housekeeping "forget", engram cleanup). It must stay scoped to
    // the CRDT tables and never reach into the consumer's schema.
    test('deleting a document\'s CRDT data leaves consumer tables intact', () {
      final db = sq.sqlite3.openInMemory();
      addTearDown(db.close);
      db
        ..execute(kNotesDdl)
        ..execute(
          'INSERT INTO bf_notes (path, title) VALUES (?, ?)',
          ['inbox/today.md', 'Today'],
        );

      final crdt = CRDTSqlite.fromDatabase(db);
      final author = Replica.named(peerA, label: 'author');
      author.note.insert(0, 'doomed');
      crdt.changeStorageForDocument('doc-one').saveChanges(
            author.exportChanges(),
          );

      final other = Replica.named(peerB, label: 'other');
      other.note.insert(0, 'survivor');
      crdt.changeStorageForDocument('doc-two').saveChanges(
            other.exportChanges(),
          );

      crdt.deleteDocumentData('doc-one');

      expect(crdt.changeStorageForDocument('doc-one').isEmpty, isTrue);
      expect(
        crdt.changeStorageForDocument('doc-two').isEmpty,
        isFalse,
        reason: 'a sibling document is untouched',
      );
      expect(
        readNotes(db),
        {'inbox/today.md': 'Today'},
        reason: 'consumer tables are outside the CRDT delete scope',
      );
      expect(tableNames(db), {'bf_notes', 'changes', 'snapshots'});
    });
  });
}
