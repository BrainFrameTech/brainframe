import 'dart:math';

import 'package:brainframe/engram/crdt/line_chunked_diff.dart';
import 'package:brainframe/engram/text_merge.dart';
import 'package:flutter_test/flutter_test.dart';

/// The three-way merge of the filesystem watcher design, Decision 6: an
/// external change merged into unsaved typing, by the CRDT's rule.
void main() {
  String merge(String base, String mine, String theirs) =>
      threeWayMerge(base: base, mine: mine, theirs: theirs);

  group('when one side did nothing', () {
    test('mine unchanged takes theirs', () {
      expect(merge('a\nb\n', 'a\nb\n', 'a\nB\n'), 'a\nB\n');
    });

    test('theirs unchanged keeps mine', () {
      expect(merge('a\nb\n', 'A\nb\n', 'a\nb\n'), 'A\nb\n');
    });

    test('the same edit on both sides is applied once', () {
      expect(merge('a\nb\n', 'a!\nb\n', 'a!\nb\n'), 'a!\nb\n');
    });
  });

  group('edits that do not overlap are both applied', () {
    test('on different lines', () {
      expect(merge('a\nb\nc\n', 'a\nb\nC\n', 'A\nb\nc\n'), 'A\nb\nC\n');
    });

    test('at different places on one line', () {
      expect(
        merge(
          'the quick fox\n',
          'the quick fox jumps\n',
          'the quick brown fox\n',
        ),
        'the quick brown fox jumps\n',
      );
    });

    test('replacements that only touch', () {
      expect(merge('abcdef', 'abcY', 'Xdef'), 'XY');
    });

    test(
      'an insertion where the other side’s removal starts lands before it',
      () {
        // Theirs removes "cd"; mine inserts at the point that range begins.
        expect(merge('abcdef', 'abZcdef', 'abef'), 'abZef');
      },
    );

    test('an insertion where the other side’s removal ends lands after it', () {
      expect(merge('abcdef', 'abcdZef', 'abef'), 'abZef');
    });
  });

  group('where the edits overlap', () {
    test('two insertions at one point keep both, theirs first', () {
      expect(merge('ab', 'aMb', 'aTb'), 'aTMb');
    });

    test('two rewrites of one span keep both, theirs first', () {
      expect(
        merge('one two three\n', 'one xyz three\n', 'one 45 three\n'),
        'one 45xyz three\n',
      );
    });

    test('typing inside a span the other side removed survives', () {
      // Theirs deletes "drop "; mine had typed inside it.
      expect(
        merge('keep drop keep\n', 'keep drXop keep\n', 'keep keep\n'),
        'keep Xkeep\n',
      );
    });

    test('typing in a note the other side emptied survives', () {
      expect(merge('abc', 'abXc', ''), 'X');
    });

    test('from an empty base, both texts are kept', () {
      expect(merge('', 'M', 'T'), 'TM');
    });

    test('a chain of overlaps is one span', () {
      // Theirs rewrites "bc" and "ef"; mine rewrites "cde", which overlaps
      // both. Every base letter in b..f was removed by one side or the other.
      expect(merge('abcdefg', 'abXfg', 'aPdQg'), 'aPQXg');
    });
  });

  group('line endings', () {
    test('a conversion to CRLF is not an edit', () {
      expect(merge('a\nb\n', 'a\nb!\n', 'a\r\nb\r\n'), 'a\nb!\n');
    });

    test('the result is LF whatever the inputs used', () {
      expect(merge('a\r\nb\r\n', 'A\r\nb\r\n', 'a\r\nB\r\n'), 'A\nB\n');
    });
  });

  group('properties, over random edits', () {
    const alphabet = 'ab \n';
    const runs = 400;

    String randomText(Random random, int length) => String.fromCharCodes([
      for (var i = 0; i < length; i++)
        alphabet.codeUnitAt(random.nextInt(alphabet.length)),
    ]);

    /// [base] with a few random removals and insertions.
    String randomEdit(Random random, String base) {
      var text = base;
      for (var n = random.nextInt(4); n >= 0; n--) {
        final at = text.isEmpty ? 0 : random.nextInt(text.length + 1);
        if (random.nextBool() && at < text.length) {
          final length = 1 + random.nextInt(min(4, text.length - at));
          text = text.replaceRange(at, at + length, '');
        } else {
          text = text.replaceRange(
            at,
            at,
            randomText(random, 1 + random.nextInt(4)),
          );
        }
      }
      return text;
    }

    /// The text each side inserted, as the merge sees it.
    Iterable<String> insertedBy(String base, String edited) => [
      for (final edit in lineChunkedDiff(base, edited))
        if (edit.insert.isNotEmpty) edit.insert,
    ];

    for (var seed = 0; seed < runs; seed += 50) {
      test('seeds $seed..${seed + 49}', () {
        for (var s = seed; s < seed + 50; s++) {
          final random = Random(s);
          final base = randomText(random, random.nextInt(24));
          final mine = randomEdit(random, base);
          final theirs = randomEdit(random, base);
          final merged = merge(base, mine, theirs);
          final why =
              'seed $s: base ${_show(base)}, mine ${_show(mine)}, '
              'theirs ${_show(theirs)} -> ${_show(merged)}';

          for (final run in [
            ...insertedBy(base, mine),
            ...insertedBy(base, theirs),
          ]) {
            expect(merged, contains(run), reason: 'lost a run; $why');
          }
          expect(merge(base, base, theirs), theirs, reason: why);
          expect(merge(base, mine, base), mine, reason: why);
          expect(merge(base, mine, mine), mine, reason: why);
        }
      });
    }

    for (var seed = 0; seed < runs; seed += 50) {
      test('edits either side of an untouched line compose, seeds $seed..'
          '${seed + 49}', () {
        // Mine edits only above a line neither side touches, theirs only
        // below it; the merge must be exactly both edits applied.
        const fence = '|\n';
        for (var s = seed; s < seed + 50; s++) {
          final random = Random(s);
          final above = randomText(random, random.nextInt(16));
          final below = randomText(random, random.nextInt(16));
          final top = above.endsWith('\n') || above.isEmpty
              ? above
              : '$above\n';
          final minesTop = randomEdit(random, top);
          final mineTop = minesTop.endsWith('\n') || minesTop.isEmpty
              ? minesTop
              : '$minesTop\n';
          final theirsBelow = randomEdit(random, below);
          final base = '$top$fence$below';
          final merged = merge(
            base,
            '$mineTop$fence$below',
            '$top$fence$theirsBelow',
          );
          expect(
            merged,
            '$mineTop$fence$theirsBelow',
            reason: 'seed $s: base ${_show(base)}',
          );
        }
      });
    }
  });
}

String _show(String text) => '"${text.replaceAll('\n', r'\n')}"';
