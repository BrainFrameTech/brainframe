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

  group('memory stays bounded', () {
    // The merge diffs through lineChunkedDiff, whose Myers is capped at a
    // 32 MB trace. An uncapped Myers is quadratic in memory on a *dispersed*
    // edit — changes scattered through one long region, so trimming the
    // common prefix and suffix buys nothing. Measured with crdt_lf's
    // myersDiff on one line of scattered changes: ~40 MB at 2000 characters,
    // ~500 MB at 8000. At the 64,000 below it would want tens of gigabytes,
    // where the merge takes ~80 ms and no more memory than a small note.
    //
    // So these are the guard: if the merge ever reached an uncapped diff,
    // they would exhaust memory or time out rather than pass — on any
    // machine, not only the 448 MB board where it matters most. Both inputs
    // are under the 128 KiB note ceiling, so a real note can take this shape.
    const bounded = Timeout(Duration(seconds: 10));

    /// One line of [length] characters, each `a` or `b` at random.
    String scattered(int seed, int length) {
      final random = Random(seed);
      return String.fromCharCodes([
        for (var i = 0; i < length; i++) 0x61 + random.nextInt(2),
      ]);
    }

    test('one long line changed throughout, typed in the middle', () {
      final base = scattered(1, 64000);
      final theirs = scattered(2, 64000);
      final mine = base.replaceRange(32000, 32000, 'X');
      // Theirs is past the budget, so the line goes coarse — one removal and
      // one insertion, keeping only what the two share at either end — and
      // mine's typing inside it survives, after theirs' text. Where exactly
      // depends on that shared end; what must hold is that the typing is the
      // only thing added to theirs.
      final merged = merge(base, mine, theirs);
      expect(merged.length, theirs.length + 1);
      expect(merged.replaceFirst('X', ''), theirs);
    }, timeout: bounded);

    test(
      'every line of a large file replaced, with a line typed below',
      () {
        // The same hazard one level up: 3000 distinct lines against 3000
        // others is past the budget at line level too, so the lines are paired
        // off — against typing the rewrite does not touch.
        final old = List.generate(3000, (i) => 'old line $i\n').join();
        final replaced = List.generate(3000, (i) => 'new line $i\n').join();
        expect(merge(old, '${old}typed\n', replaced), '${replaced}typed\n');
      },
      timeout: bounded,
    );
  });

  group('the note the backslash bug inflated', () {
    // 8190 bytes on one line, cut back to 58 outside the app — the note
    // that took the Pi down. Its edit is one contiguous run, so prefix and
    // suffix trimming make it cheap for any diff; it is here as the real
    // note, for what the merge makes of it, not as a memory guard.
    const short = '- https://sourcesofinsight.com/leadership-books/\\n\\nl-las';
    final long =
        '- https://sourcesofinsight.com/leadership-books/'
        '${'\\' * 8100}n\\nl-las';

    test('cut back outside, typed at the end in the app', () {
      // The removal does not reach the end, so both land.
      expect(merge(long, '${long}X', short), '${short}X');
    });

    test('cut back outside, typed inside what was cut', () {
      // The typing survives, and the note comes back short, not long.
      final at = long.length ~/ 2;
      final merged = merge(long, long.replaceRange(at, at, 'X'), short);
      expect(merged, contains('X'));
      expect(merged.length, lessThan(short.length + 10));
    });
  });

  group('offsetMapping (the caret, Decision 7)', () {
    int map(String before, String after, int offset) =>
        offsetMapping(before, after)(offset);

    test('identical text maps every position to itself', () {
      expect(map('abc', 'abc', 2), 2);
    });

    test('a position before a change stays', () {
      expect(map('hello world', 'hello world!', 3), 3);
    });

    test('a position after a change shifts by what it added or removed', () {
      expect(map('hello world', 'oh, hello world', 5), 9);
      expect(map('oh, hello world', 'hello world', 9), 5);
    });

    test('a position exactly where text is inserted stays before it', () {
      // The user keeps typing where they were when text lands at the caret.
      expect(map('ab', 'aXb', 1), 1);
    });

    test('a position inside a replaced span moves to the end of it', () {
      expect(map('one two three', 'one 45 three', 5), 6);
    });

    test('a position inside a removed span moves to where it was', () {
      expect(map('keep drop keep', 'keep keep', 7), 5);
    });

    test('positions are mapped by one diff, however many', () {
      final mapping = offsetMapping('a\nb\nc\n', 'A\na\nb\nc\nd\n');
      // 0 is where "A\n" is inserted, so it stays; the rest shift past it.
      expect([0, 1, 2, 6].map(mapping).toList(), [0, 3, 4, 8]);
    });

    test('line endings are exact, not normalized', () {
      // A field holding CRLF maps into one holding LF position by position.
      expect(map('a\r\nb\r\n', 'a\nb\n', 3), 2);
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
