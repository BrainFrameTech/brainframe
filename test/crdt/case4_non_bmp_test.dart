// Edge Case 4 — Non-BMP (surrogate-pair) content survives serialization.
//
// Motivated by crdt_lf issue #103: non-BMP characters corrupting to U+FFFD
// across serialize/deserialize (fixed in 3.4.2). ASCII fixtures never exercise
// the surrogate path, so this class of bug slips through Cases 1–3 entirely.
// The corruption is invisible in-memory on the originating replica and only
// appears after a serialize/deserialize round-trip (to another replica OR to a
// snapshot and back); the corrupted output is still well-formed UTF-16, so only
// an EXACT-VALUE assertion catches it — a validity check never would.
//
// This is a permanent regression guard: run against every crdt_lf version bump.

import 'dart:typed_data';

import 'package:crdt_lf/crdt_lf.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/peer_ids.dart';
import 'support/replica.dart';

// Code units of the reference characters, asserted explicitly so a regression
// to "��" ([65533, 65533]) fails loudly rather than plausibly.
const List<int> grinningFaceUnits = [55357, 56832]; // U+1F600 😀
const List<int> replacementUnits = [65533, 65533]; // U+FFFD U+FFFD (corruption)

void main() {
  group('Edge Case 4 — non-BMP survives serialization', () {
    test('4a — sequence insert survives to a second replica (binary)', () {
      for (final sample in <String>[
        '😀', // U+1F600 emoji
        '𠀀', // U+20000 CJK Extension B ideograph
        '👨‍👩‍👧', // ZWJ family sequence
      ]) {
        final a = Replica.named(peerA);
        a.note.insert(0, sample);

        // Cross the byte-level serialization boundary into a fresh replica.
        final b = Replica.named(peerB);
        b.doc.binaryImportChanges(a.doc.binaryExportChanges());

        expect(
          b.text,
          a.text,
          reason: 'replica B must match A exactly for "$sample"',
        );
        expect(b.text, sample);
        expect(
          b.text.codeUnits,
          a.text.codeUnits,
          reason: 'code units must round-trip byte-for-byte',
        );
      }

      // Spell out the emoji case against the exact expected/forbidden units.
      final a = Replica.named(peerA);
      a.note.insert(0, '😀');
      final b = Replica.named(peerB);
      b.doc.binaryImportChanges(a.doc.binaryExportChanges());
      expect(b.text.codeUnits, grinningFaceUnits);
      expect(b.text.codeUnits, isNot(replacementUnits));
    });

    test('4b — edit that splits a surrogate pair round-trips', () {
      // "a😀b" -> "a😃b": per diff this touches only the low surrogate.
      final a = Replica.named(peerA);
      a.note.insert(0, 'a😀b');
      a.note.change('a😃b');
      expect(a.text, 'a😃b', reason: 'originating replica edits correctly');

      final b = Replica.named(peerB);
      b.doc.binaryImportChanges(a.doc.binaryExportChanges());
      expect(b.text, 'a😃b');
      expect(b.text.codeUnits, 'a😃b'.codeUnits);
    });

    test('4c — single-doc snapshot round-trip (persistence path)', () {
      // Simulates a restart / load-from-disk entirely in memory: the snapshot
      // bytes live in a variable, no file is written. Same peerID + documentId.
      final a = Replica.named(peerA);
      a.note.insert(0, '😀');

      final snapshotBytes = a.doc.takeSnapshot(pruneHistory: false).toBytes();

      final reloaded = CRDTDocument(peerId: peerA, documentId: kDocumentId);
      final reloadedNote = CRDTFugueTextHandler(reloaded, kHandlerId);
      reloaded.importSnapshot(
        Snapshot.fromBytes(Uint8List.fromList(snapshotBytes)),
      );

      expect(reloadedNote.value, '😀');
      expect(reloadedNote.value.codeUnits, grinningFaceUnits);
    });
  });
}
