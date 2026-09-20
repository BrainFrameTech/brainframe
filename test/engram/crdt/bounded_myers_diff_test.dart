import 'dart:math';

import 'package:brainframe/engram/crdt/bounded_myers_diff.dart';
import 'package:brainframe/engram/crdt/line_chunked_diff.dart';
import 'package:crdt_lf/crdt_lf.dart';
import 'package:flutter_test/flutter_test.dart';

/// The bounded Myers diff: the same answer as crdt_lf's within budget, a
/// correct coarse answer past it, and the memory case it was written for.
void main() {
  /// Replays [segments] against [old], the way a consumer of the segments
  /// would, and returns the text they describe.
  String replay(String old, List<DiffSegment> segments) {
    final buffer = StringBuffer();
    var cursor = 0;
    for (final s in segments) {
      expect(s.oldStart, cursor, reason: 'segments must be contiguous');
      switch (s.op) {
        case DiffOp.equal:
          expect(old.substring(s.oldStart, s.oldEnd), s.text);
          buffer.write(s.text);
          cursor = s.oldEnd;
        case DiffOp.remove:
          expect(old.substring(s.oldStart, s.oldEnd), s.text);
          cursor = s.oldEnd;
        case DiffOp.insert:
          expect(s.oldEnd, s.oldStart);
          buffer.write(s.text);
      }
    }
    buffer.write(old.substring(cursor));
    return buffer.toString();
  }

  group('within budget it is crdt_lf\'s diff', () {
    const cases = <(String, String)>[
      ('', ''),
      ('a', 'a'),
      ('', 'abc'),
      ('abc', ''),
      ('abc', 'abd'),
      ('kitten', 'sitting'),
      ('one two three', 'one three'),
      ('one three', 'one two three'),
      ('aaaa', 'aaaaa'),
      ('prefix MIDDLE suffix', 'prefix middle suffix'),
      ('- https://x/\n\nl-las', '- https://x/\\n\\nl-las'),
    ];

    for (final (old, new_) in cases) {
      test(
        '${old.replaceAll('\n', r'\n')} → ${new_.replaceAll('\n', r'\n')}',
        () {
          final ours = boundedMyersDiff(old, new_);
          expect(ours, myersDiff(old, new_));
          expect(replay(old, ours), new_);
        },
      );
    }

    test('random edits agree with crdt_lf and round-trip', () {
      final random = Random(20260920);
      const alphabet = 'ab\n ';
      String randomText(int length) => String.fromCharCodes([
        for (var i = 0; i < length; i++)
          alphabet.codeUnitAt(random.nextInt(alphabet.length)),
      ]);
      for (var round = 0; round < 300; round++) {
        final old = randomText(random.nextInt(24));
        final new_ = randomText(random.nextInt(24));
        final ours = boundedMyersDiff(old, new_);
        expect(ours, myersDiff(old, new_), reason: '"$old" → "$new_"');
        expect(replay(old, ours), new_);
      }
    });
  });

  group('past budget it is one removal and one insertion', () {
    test('the frontier rows are what is counted', () {
      // "abc" → "xyz" after trimming (nothing to trim) is D = 6: rows of
      // 1, 3, 5, 7, 9, 11, 13 cells = 49. One cell short and it gives up.
      const old = 'abc';
      const new_ = 'xyz';
      expect(
        boundedMyersDiff(old, new_, maxTraceCells: 49),
        myersDiff(old, new_),
      );
      final coarse = boundedMyersDiff(old, new_, maxTraceCells: 48);
      expect(coarse, [
        const DiffSegment(
          op: DiffOp.remove,
          text: 'abc',
          oldStart: 0,
          oldEnd: 3,
          newStart: 0,
          newEnd: 0,
        ),
        // The insertion sits at the end of the removed span, as a coalesced
        // script places an insertion that follows a removal.
        const DiffSegment(
          op: DiffOp.insert,
          text: 'xyz',
          oldStart: 3,
          oldEnd: 3,
          newStart: 0,
          newEnd: 3,
        ),
      ]);
      expect(replay(old, coarse), new_);
    });

    test('the equal prefix and suffix survive the fallback', () {
      const old = 'keep THIS PART GOES away keep';
      const new_ = 'keep new keep';
      final coarse = boundedMyersDiff(old, new_, maxTraceCells: 1);
      expect(coarse.map((s) => s.op), [
        DiffOp.equal,
        DiffOp.remove,
        DiffOp.insert,
        DiffOp.equal,
      ]);
      expect(coarse.first.text, 'keep ');
      expect(coarse.last.text, ' keep');
      expect(replay(old, coarse), new_);
    });

    test('a budget of zero still answers every trivial case', () {
      expect(boundedMyersDiff('', '', maxTraceCells: 0), isEmpty);
      expect(
        boundedMyersDiff('same', 'same', maxTraceCells: 0).single.op,
        DiffOp.equal,
      );
      expect(
        boundedMyersDiff('', 'new', maxTraceCells: 0).single.op,
        DiffOp.insert,
      );
      expect(
        boundedMyersDiff('old', '', maxTraceCells: 0).single.op,
        DiffOp.remove,
      );
      // A pure insertion or removal after trimming needs no search at all.
      expect(boundedMyersDiff('ab', 'aXb', maxTraceCells: 0).map((s) => s.op), [
        DiffOp.equal,
        DiffOp.insert,
        DiffOp.equal,
      ]);
    });
  });

  group('the case it was written for', () {
    // The note the flutter-pi backslash bug inflated: one line whose newlines
    // became literal backslash-n pairs and then doubled with every edit,
    // 8190 bytes on disk before the user cut it back to 58. In the op-log it
    // is still the long version, so the scan diffs long against short.
    final short = '- https://sourcesofinsight.com/leadership-books/\\n\\nl-las';
    final long =
        '- https://sourcesofinsight.com/leadership-books/'
        '${'\\' * 8100}n\\nl-las';

    test('stays within the default budget instead of needing a gigabyte', () {
      // Textbook Myers here is D ≈ 8100 steps × a 16,000-entry frontier —
      // 1.07 GB, measured. Two million cells is 16 MB, and the fallback
      // needs none of them.
      final segments = boundedMyersDiff(long, short);
      expect(replay(long, segments), short);
      // Prefix kept, the run of backslashes removed as one, tail kept.
      expect(segments.where((s) => s.op == DiffOp.remove).length, 1);
      expect(
        segments.where((s) => s.op == DiffOp.insert).length,
        lessThanOrEqualTo(1),
      );
    });

    test('through the line-chunked diff it is a handful of edits', () {
      final edits = lineChunkedDiff(long, short);
      // One line against one line: the whole-region pass is over budget, the
      // pairing pass is the same single pair, and that pair goes coarse.
      expect(edits.length, lessThanOrEqualTo(2));
      var applied = long;
      for (final e in edits.reversed) {
        applied = applied.replaceRange(
          e.offset,
          e.offset + e.removeLength,
          e.insert,
        );
      }
      expect(applied, short);
    });

    test('the line pass is bounded too, and pairs lines off', () {
      // Every line of a large file replaced: the hazard one level up. 3000
      // distinct lines against 3000 other distinct lines is D = 6000 at
      // line level — (6001)² cells, well past budget — so the line pass goes
      // coarse, the region is the whole file, the whole-region character
      // diff is over budget too, and the lines are paired off: 3000 pairs,
      // each a three-character edit. Correct, and still minimal — 3000
      // removals and 3000 insertions of one word, not 60,000 characters.
      final old = List.generate(3000, (i) => 'old line $i\n').join();
      final new_ = List.generate(3000, (i) => 'new line $i\n').join();
      final edits = lineChunkedDiff(old, new_);
      expect(edits.length, 6000);
      expect(
        edits
            .map((e) => e.removeLength + e.insert.length)
            .reduce((a, b) => a + b),
        6 * 3000,
      );
      var applied = old;
      for (final e in edits.reversed) {
        applied = applied.replaceRange(
          e.offset,
          e.offset + e.removeLength,
          e.insert,
        );
      }
      expect(applied, new_);
    });
  });
}
