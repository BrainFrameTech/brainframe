import 'dart:convert';
import 'dart:typed_data';

import 'package:brainframe/engram/crdt/catalog.dart';
import 'package:brainframe/engram/crdt/drift.dart';
import 'package:brainframe/engram/engram_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// Decision 5's comparisons: the hash that decides, and the pre-filter that is
/// only ever allowed to say "maybe".
void main() {
  CatalogRow rowWith({String? hash, int? size, DateTime? mtimeUtc}) =>
      CatalogRow(
        ulid: '01JBFRAMEEXAMPLEULID000000',
        path: 'inbox/today.md',
        mergePolicy: MergePolicy.fugueText,
        state: NoteState.live,
        materializedHash: hash,
        size: size,
        mtimeUtc: mtimeUtc,
      );

  final noon = DateTime.utc(2026, 9, 7, 12);

  group('contentHash', () {
    test('is stable for the same bytes', () {
      final bytes = Uint8List.fromList(utf8.encode('# Today\n'));

      expect(contentHash(bytes), contentHash(Uint8List.fromList(bytes)));
    });

    test('differs for a one-character change', () {
      expect(
        contentHashOfString('# Today\n'),
        isNot(contentHashOfString('# Todau\n')),
      );
    });

    test('a line-ending difference is a different hash', () {
      // The file on disk really did change bytes; normalization happens above
      // this layer, never inside the change detector.
      expect(
        contentHashOfString('a\nb\n'),
        isNot(contentHashOfString('a\r\nb\r\n')),
      );
    });

    test('the string and byte forms agree', () {
      const text = 'frontmatter: yes\n\nbody 🎉\n';

      expect(
        contentHashOfString(text),
        contentHash(Uint8List.fromList(utf8.encode(text))),
      );
    });

    test('is lowercase hex of the expected width', () {
      expect(contentHashOfString('x'), matches(RegExp(r'^[0-9a-f]{64}$')));
    });
  });

  group('hasDrifted decides', () {
    test('a matching hash is not drift', () {
      final hash = contentHashOfString('same\n');

      expect(hasDrifted(rowWith(hash: hash), hash), isFalse);
    });

    test('a different hash is drift', () {
      expect(
        hasDrifted(rowWith(hash: contentHashOfString('old\n')),
            contentHashOfString('new\n')),
        isTrue,
      );
    });

    test('a row this device never materialized is drift', () {
      // There is no output of ours for the file to match, so the file is not
      // ours to trust.
      expect(hasDrifted(rowWith(), contentHashOfString('anything\n')), isTrue);
    });
  });

  group('mayHaveDrifted only ever says maybe', () {
    test('identical size and mtime rules the file out', () {
      final row = rowWith(hash: 'h', size: 10, mtimeUtc: noon);

      expect(
        mayHaveDrifted(row, FileFingerprint(size: 10, mtimeUtc: noon)),
        isFalse,
      );
    });

    test('a changed size is not ruled out', () {
      final row = rowWith(hash: 'h', size: 10, mtimeUtc: noon);

      expect(
        mayHaveDrifted(row, FileFingerprint(size: 11, mtimeUtc: noon)),
        isTrue,
      );
    });

    test('a changed mtime is not ruled out', () {
      final row = rowWith(hash: 'h', size: 10, mtimeUtc: noon);

      expect(
        mayHaveDrifted(
          row,
          FileFingerprint(
            size: 10,
            mtimeUtc: noon.add(const Duration(seconds: 1)),
          ),
        ),
        isTrue,
      );
    });

    test('a same-size same-second edit is NOT ruled out by the hash test', () {
      // The pre-filter cannot see this one — that is precisely why Decision 5
      // forbids it being the sole test. Same size, same instant, different
      // content: trivially achievable by a script, and the hash is what
      // catches it.
      final row = rowWith(
        hash: contentHashOfString('aaaa\n'),
        size: 5,
        mtimeUtc: noon,
      );
      final unchangedStat = FileFingerprint(size: 5, mtimeUtc: noon);

      expect(
        mayHaveDrifted(row, unchangedStat),
        isFalse,
        reason: 'the cheap half sees nothing',
      );
      expect(
        hasDrifted(row, contentHashOfString('bbbb\n')),
        isTrue,
        reason: 'the hash is what actually catches it',
      );
    });

    test('sub-millisecond precision does not defeat the pre-filter', () {
      // The catalog stores mtime_utc as milliseconds; a filesystem reports
      // microseconds. Comparing them directly means a round-tripped row never
      // matches a fresh stat, so the pre-filter can never rule anything out
      // and quietly becomes "always hash" — present, and doing nothing.
      final stored = DateTime.fromMillisecondsSinceEpoch(
        noon.millisecondsSinceEpoch,
        isUtc: true,
      );
      final fromFilesystem = stored.add(const Duration(microseconds: 375));

      expect(
        mayHaveDrifted(
          rowWith(hash: 'h', size: 10, mtimeUtc: stored),
          FileFingerprint(size: 10, mtimeUtc: fromFilesystem),
        ),
        isFalse,
      );
    });

    test('a whole millisecond apart is still not ruled out', () {
      final stored = DateTime.fromMillisecondsSinceEpoch(
        noon.millisecondsSinceEpoch,
        isUtc: true,
      );

      expect(
        mayHaveDrifted(
          rowWith(hash: 'h', size: 10, mtimeUtc: stored),
          FileFingerprint(
            size: 10,
            mtimeUtc: stored.add(const Duration(milliseconds: 1)),
          ),
        ),
        isTrue,
      );
    });

    test('a missing stat is not ruled out', () {
      expect(
        mayHaveDrifted(rowWith(hash: 'h', size: 10, mtimeUtc: noon), null),
        isTrue,
      );
    });

    test('a row with no recorded hash is not ruled out', () {
      expect(
        mayHaveDrifted(
          rowWith(size: 10, mtimeUtc: noon),
          FileFingerprint(size: 10, mtimeUtc: noon),
        ),
        isTrue,
      );
    });

    test('a row with no recorded size or mtime is not ruled out', () {
      // Missing information costs a hash rather than a missed edit.
      expect(
        mayHaveDrifted(
          rowWith(hash: 'h', mtimeUtc: noon),
          FileFingerprint(size: 10, mtimeUtc: noon),
        ),
        isTrue,
      );
      expect(
        mayHaveDrifted(
          rowWith(hash: 'h', size: 10),
          FileFingerprint(size: 10, mtimeUtc: noon),
        ),
        isTrue,
      );
    });
  });

  group('FileFingerprint', () {
    test('equal fingerprints are equal', () {
      expect(
        FileFingerprint(size: 1, mtimeUtc: noon),
        FileFingerprint(size: 1, mtimeUtc: noon),
      );
    });

    test('each field participates in equality', () {
      expect(
        FileFingerprint(size: 1, mtimeUtc: noon),
        isNot(FileFingerprint(size: 2, mtimeUtc: noon)),
      );
      expect(
        FileFingerprint(size: 1, mtimeUtc: noon),
        isNot(
          FileFingerprint(size: 1, mtimeUtc: noon.add(const Duration(days: 1))),
        ),
      );
    });

    test('toString names both halves', () {
      expect(
        FileFingerprint(size: 12, mtimeUtc: noon).toString(),
        allOf(contains('12'), contains('2026')),
      );
    });
  });
}
