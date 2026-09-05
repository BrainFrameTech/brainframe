import 'dart:typed_data';

import 'package:brainframe/engram/crdt/catalog.dart';
import 'package:crdt_lf/crdt_lf.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hlc_dart/hlc_dart.dart';

import '../../crdt/support/peer_ids.dart';

/// The catalog's value types, which are platform-neutral and hold no storage.
void main() {
  OperationId claim(PeerId peer, int millis) =>
      OperationId(peer, HybridLogicalClock(l: millis, c: 0));

  CatalogRow row({
    String ulid = '01JBQ9YQ7C8VF9YB0X5H3TQ2ZK',
    String path = 'inbox/today.md',
    MergePolicy mergePolicy = MergePolicy.fugueText,
    NoteState state = NoteState.live,
    String? materializedHash,
    int? size,
    DateTime? mtimeUtc,
    Uint8List? sketch,
    OperationId? seedClaim,
  }) => CatalogRow(
    ulid: ulid,
    path: path,
    mergePolicy: mergePolicy,
    state: state,
    materializedHash: materializedHash,
    size: size,
    mtimeUtc: mtimeUtc,
    sketch: sketch,
    seedClaim: seedClaim,
  );

  group('MergePolicy', () {
    test('round-trips through its stored spelling', () {
      for (final policy in MergePolicy.values) {
        expect(MergePolicy.parse(policy.name), policy);
      }
    });

    test('an unknown policy is refused, not defaulted', () {
      // Guessing at semantics we do not recognise is how a PNG would get
      // character-merged; the store turns this into a surfaced failure.
      expect(
        () => MergePolicy.parse('vectorInk'),
        throwsA(isA<FormatException>()),
      );
    });

    test('is an open enum, so nothing may assume it holds exactly two', () {
      // Pins the shape rather than the count: a third policy (vector ink) is
      // designed for, so this must not become `expect(values.length, 2)`.
      expect(MergePolicy.values, contains(MergePolicy.fugueText));
      expect(MergePolicy.values, contains(MergePolicy.blobLww));
    });
  });

  group('mergePolicyForPath', () {
    test('text extensions get fugueText', () {
      for (final path in ['a.md', 'a.markdown', 'a.txt', 'a.text']) {
        expect(mergePolicyForPath(path), MergePolicy.fugueText, reason: path);
      }
    });

    test('the extension is matched case-insensitively', () {
      expect(mergePolicyForPath('NOTES.MD'), MergePolicy.fugueText);
      expect(mergePolicyForPath('Notes.Md'), MergePolicy.fugueText);
    });

    test('binary and unknown extensions get blobLww', () {
      for (final path in ['a.png', 'a.pdf', 'a.epub', 'a.zip', 'a.wat']) {
        expect(mergePolicyForPath(path), MergePolicy.blobLww, reason: path);
      }
    });

    test('an unrecognised extension defaults to the recoverable failure', () {
      // The asymmetry in Decision 3: last-writer-wins on text loses an edit
      // that still exists in the loser's history, while character-merging a
      // binary produces a file nobody can recover.
      expect(mergePolicyForPath('a.unheard-of'), MergePolicy.blobLww);
    });

    test('a name with no extension is a blob', () {
      expect(mergePolicyForPath('LICENSE'), MergePolicy.blobLww);
      expect(mergePolicyForPath('notes/LICENSE'), MergePolicy.blobLww);
    });

    test('a dotfile has no extension', () {
      // The leading dot names a hidden file; it does not introduce one.
      expect(mergePolicyForPath('.gitignore'), MergePolicy.blobLww);
      expect(mergePolicyForPath('notes/.gitignore'), MergePolicy.blobLww);
    });

    test('a dotfile that also has an extension keeps it', () {
      expect(mergePolicyForPath('.hidden.md'), MergePolicy.fugueText);
    });

    test('only the last extension counts', () {
      expect(mergePolicyForPath('archive.md.zip'), MergePolicy.blobLww);
      expect(mergePolicyForPath('archive.zip.md'), MergePolicy.fugueText);
    });

    test('a dot in a directory name is not the note\'s extension', () {
      // Otherwise every note under `v1.0/` would be typed by its folder.
      expect(mergePolicyForPath('v1.0/notes'), MergePolicy.blobLww);
      expect(mergePolicyForPath('v1.0/notes.md'), MergePolicy.fugueText);
    });
  });

  group('NoteState', () {
    test('round-trips through its stored spelling', () {
      for (final state in NoteState.values) {
        expect(NoteState.parse(state.name), state);
      }
    });

    test('an unknown state is refused', () {
      expect(
        () => NoteState.parse('archived'),
        throwsA(isA<FormatException>()),
      );
    });

    test('unavailable is distinct from tombstoned', () {
      // A file missing because a drive is unmounted is not a deleted file, and
      // collapsing the two would destroy a note that is merely out of reach.
      expect(NoteState.unavailable, isNot(NoteState.tombstoned));
    });
  });

  group('CatalogRow', () {
    test('a bare row carries no device-local state yet', () {
      final bare = row();

      expect(bare.materializedHash, isNull);
      expect(bare.size, isNull);
      expect(bare.mtimeUtc, isNull);
      expect(bare.sketch, isNull);
    });

    test('no seed claim means no seeder', () {
      // An unclaimed seed: the identity map knows the note, but no surviving
      // op-log ever backed it.
      expect(row().seedClaim, isNull);
      expect(row().seededBy, isNull);
    });

    test('a seed claim exposes the peer that took it', () {
      expect(row(seedClaim: claim(peerA, 10)).seededBy, peerA);
    });

    test('seed claims order by the locked comparator', () {
      // HLC first, peerID second — the library's ordering, reused rather than
      // reimplemented, so the catalog cannot drift from the op-log.
      expect(claim(peerA, 10).compareTo(claim(peerB, 20)), lessThan(0));
      expect(claim(peerC, 20).compareTo(claim(peerA, 10)), greaterThan(0));
      // Equal clocks fall through to the peerID.
      expect(claim(peerA, 10).compareTo(claim(peerB, 10)), lessThan(0));
    });

    test('equal rows are equal, field by field', () {
      final mtime = DateTime.utc(2026, 9, 5, 12);
      final sketch = Uint8List.fromList([1, 2, 3]);
      final a = row(
        materializedHash: 'h',
        size: 12,
        mtimeUtc: mtime,
        sketch: sketch,
        seedClaim: claim(peerA, 10),
      );
      final b = row(
        materializedHash: 'h',
        size: 12,
        mtimeUtc: mtime,
        // A different list with the same bytes: Uint8List equality is
        // identity, so this is what would break a round-trip comparison.
        sketch: Uint8List.fromList([1, 2, 3]),
        seedClaim: claim(peerA, 10),
      );

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('each field participates in equality', () {
      final base = row();

      expect(base, isNot(row(ulid: '01JBQ9YQ7C8VF9YB0X5H3TQ2ZL')));
      expect(base, isNot(row(path: 'inbox/other.md')));
      expect(base, isNot(row(mergePolicy: MergePolicy.blobLww)));
      expect(base, isNot(row(state: NoteState.tombstoned)));
      expect(base, isNot(row(materializedHash: 'h')));
      expect(base, isNot(row(size: 1)));
      expect(base, isNot(row(mtimeUtc: DateTime.utc(2026))));
      expect(base, isNot(row(sketch: Uint8List.fromList([1]))));
      expect(base, isNot(row(seedClaim: claim(peerA, 10))));
    });

    test('sketches of different lengths are not equal', () {
      expect(
        row(sketch: Uint8List.fromList([1, 2])),
        isNot(row(sketch: Uint8List.fromList([1, 2, 3]))),
      );
    });

    test('sketches of equal length but different bytes are not equal', () {
      expect(
        row(sketch: Uint8List.fromList([1, 2, 3])),
        isNot(row(sketch: Uint8List.fromList([1, 2, 4]))),
      );
    });

    test('toString names the note without dumping its device-local state', () {
      final text = row(materializedHash: 'secret-ish').toString();

      expect(text, contains('01JBQ9YQ7C8VF9YB0X5H3TQ2ZK'));
      expect(text, contains('inbox/today.md'));
      expect(text, contains('fugueText'));
      expect(text, contains('live'));
      expect(text, isNot(contains('secret-ish')));
    });
  });
}
