// Smoke test for the crdt_lf_sqlite dependency.
//
// This is deliberately NOT part of the edge-case suite (docs/testing/
// crdt-sync-test-spec.md), which is frozen ground truth about the *data
// model*. This file asserts something different and much narrower: that the
// storage dependency is wired up and actually functions on the host running
// the tests.
//
// It earns its place because crdt_lf_sqlite is the suite's one dependency with
// a NATIVE component. It rides on `sqlite3`, a dart:ffi package that opens a
// real sqlite3 library at runtime. A pub resolution proving the Dart API
// exists says nothing about whether that library can actually be opened — so
// without this test the first thing to discover an unloadable sqlite3 would be
// the sync layer, at runtime. Here it fails loudly at `flutter test` instead.
//
// PLATFORM SCOPE: dart:ffi does not exist on the web, so this package (and
// anything importing it) is desktop/mobile only and must never be reached from
// shared code on a web build.
//
// NO NATIVE-BUNDLING PACKAGE IS NEEDED, and one must not be added.
// `package:sqlite3` v3 ships its own sqlite3 with the app on every platform
// through Dart's build hooks, and prefers it over whatever the operating
// system offers — so every target gets one build with one set of compile-time
// options, rather than whatever each OS happens to provide. The v2-era
// `sqlite3_flutter_libs` existed to fill that gap and is obsolete against v3;
// adding it would ship a second copy of sqlite3 that nothing loads.

import 'package:crdt_lf_sqlite/crdt_lf_sqlite.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/peer_ids.dart';
import 'support/replica.dart';

void main() {
  group('crdt_lf_sqlite dependency smoke test', () {
    // The whole point: opening a database exercises the dart:ffi lookup of the
    // native sqlite3 library. If the platform has no loadable sqlite3 this
    // throws, and it throws HERE rather than inside the future sync layer.
    test('an in-memory database opens and closes (native sqlite3 loads)', () {
      final db = CRDTSqlite.memory();
      addTearDown(db.close);
      expect(db, isNotNull);
    });

    // A change persisted through the storage adapter and reloaded into a fresh
    // document must materialize the same text. This proves the Change <-> blob
    // round trip (crdt_lf's own toBytes/fromBytes, which the adapter stores)
    // survives the database, not merely that a table accepted some bytes.
    test('changes survive a save/load round trip through the database', () {
      final db = CRDTSqlite.memory();
      addTearDown(db.close);

      final author = Replica.named(peerA, label: 'author');
      author.note.insert(0, 'hello engram');

      final changes = db.changeStorageForDocument(kDocumentId);
      changes.saveChanges(author.exportChanges());
      expect(changes.isEmpty, isFalse, reason: 'changes were persisted');

      // A fresh replica that has only ever seen the DATABASE — never the
      // author — must reach the author's exact text.
      final restored = Replica.named(peerB, label: 'restored');
      restored.importChanges(changes.getChanges());
      expect(restored.text, 'hello engram');
      expect(restored.text, author.text);
    });

    // Documents are isolated by the `document_id` column in shared tables, so
    // "one database, many engram notes" has to keep them apart. A leak here
    // would surface as one note's edits bleeding into another.
    test('documents in one database stay isolated from each other', () {
      final db = CRDTSqlite.memory();
      addTearDown(db.close);

      final first = Replica.named(peerA, label: 'first');
      first.note.insert(0, 'note one');
      final second = Replica.named(peerB, label: 'second');
      second.note.insert(0, 'note two');

      db.changeStorageForDocument('doc-one').saveChanges(first.exportChanges());
      db
          .changeStorageForDocument('doc-two')
          .saveChanges(second.exportChanges());

      final loadedFirst = Replica.named(peerC, label: 'loaded-first');
      loadedFirst.importChanges(
        db.changeStorageForDocument('doc-one').getChanges(),
      );
      expect(loadedFirst.text, 'note one');

      final loadedSecond = Replica.named(peerC, label: 'loaded-second');
      loadedSecond.importChanges(
        db.changeStorageForDocument('doc-two').getChanges(),
      );
      expect(loadedSecond.text, 'note two');
    });
  });
}
