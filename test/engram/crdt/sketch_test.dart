import 'dart:io';
import 'dart:typed_data';

import 'package:brainframe/engram/crdt/sketch.dart';
import 'package:flutter_test/flutter_test.dart';

/// The content sketch, and the measurements behind its constants.
///
/// The fixture half is the record the plan asks for: the shingle size, width,
/// and cutoff were chosen against `test/fixtures/engram`, and these assertions
/// are what would fail if the fixture drifted under them or the constants were
/// changed without re-measuring.
void main() {
  group('format', () {
    test('a sketch is the version byte plus 128 four-byte slots', () {
      final sketch = computeSketch('one two three four five');
      expect(sketch.length, 1 + sketchWidth * 4);
      expect(sketch[0], sketchVersion);
    });

    test('the same text always yields the same sketch', () {
      // The constants are part of the format: a sketch written today must
      // compare with one computed later.
      expect(computeSketch('a b c d e f'), computeSketch('a b c d e f'));
    });

    test('an empty or whitespace-only note has no slots', () {
      expect(computeSketch(''), [sketchVersion]);
      expect(computeSketch(' \n\t\n'), [sketchVersion]);
    });

    test('line terminators do not matter', () {
      expect(
        computeSketch('a b c\nd e f\n'),
        computeSketch('a b c\r\nd e f\r\n'),
      );
    });

    test('a note shorter than one shingle still sketches', () {
      final one = computeSketch('hello');
      final two = computeSketch('hello world');
      expect(one.length, 1 + sketchWidth * 4);
      expect(sketchSimilarity(one, one), 1);
      expect(sketchSimilarity(one, two), 0);
    });
  });

  group('similarity', () {
    test('identical text is 1', () {
      final s = computeSketch('the quick brown fox jumps over the lazy dog');
      expect(sketchSimilarity(s, s), 1);
    });

    test('unrelated text is near 0', () {
      final a = computeSketch(List.generate(60, (i) => 'alpha$i').join(' '));
      final b = computeSketch(List.generate(60, (i) => 'beta$i').join(' '));
      expect(sketchSimilarity(a, b), lessThan(0.05));
    });

    test('never matches when either side cannot be read', () {
      final s = computeSketch('some words here to sketch');
      expect(sketchSimilarity(null, s), 0);
      expect(sketchSimilarity(s, null), 0);
      expect(sketchSimilarity(s, computeSketch('')), 0, reason: 'empty');
      expect(
        sketchSimilarity(s, Uint8List.fromList([sketchVersion + 1, 1, 2])),
        0,
        reason: 'another version',
      );
      expect(
        sketchSimilarity(s, Uint8List.fromList([sketchVersion, 1, 2, 3])),
        0,
        reason: 'malformed',
      );
      expect(sketchSimilarity(s, Uint8List(0)), 0, reason: 'no bytes');
    });

    test('is symmetric', () {
      final a = computeSketch('one two three four five six seven');
      final b = computeSketch('one two three four nine ten eleven');
      expect(sketchSimilarity(a, b), sketchSimilarity(b, a));
    });
  });

  group('the constants, against the fixture engram', () {
    final texts = <String, String>{};
    setUpAll(() {
      final files =
          Directory('test/fixtures/engram')
              .listSync(recursive: true)
              .whereType<File>()
              .where(
                (f) =>
                    !f.path.contains('/.brainframe/') &&
                    (f.path.endsWith('.md') || f.path.endsWith('.txt')),
              )
              .toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      for (final file in files) {
        texts[file.path] = file.readAsStringSync();
      }
      expect(texts.length, greaterThan(20), reason: 'the fixture moved?');
    });

    test('no two distinct notes come near the cutoff', () {
      // The false-match direction: above the cutoff, two unrelated notes
      // would have their histories merged, silently.
      final sketches = {
        for (final e in texts.entries) e.key: computeSketch(e.value),
      };
      final keys = sketches.keys.toList();
      var worst = 0.0;
      for (var i = 0; i < keys.length; i++) {
        for (var j = i + 1; j < keys.length; j++) {
          final s = sketchSimilarity(sketches[keys[i]], sketches[keys[j]]);
          if (s > worst) worst = s;
        }
      }
      expect(worst, lessThan(0.15));
      expect(worst, lessThan(renameSimilarityCutoff / 3));
    });

    /// [edit] applied to every fixture note; the lowest similarity seen.
    double worstCase(List<String> Function(List<String> lines) edit) {
      var worst = 1.0;
      for (final text in texts.values) {
        final edited = edit(text.split('\n')).join('\n');
        final s = sketchSimilarity(computeSketch(text), computeSketch(edited));
        if (s < worst) worst = s;
      }
      return worst;
    }

    test('a note with a paragraph appended is still recognised', () {
      final worst = worstCase(
        (lines) => [
          ...lines,
          '',
          'A new paragraph added after the rename, with a few sentences of',
          'material that was not there before and says something new.',
        ],
      );
      expect(worst, greaterThanOrEqualTo(renameSimilarityCutoff));
    });

    test('a note with its first fifth deleted is still recognised', () {
      final worst = worstCase((lines) => lines.sublist(lines.length ~/ 5));
      expect(worst, greaterThanOrEqualTo(renameSimilarityCutoff));
    });

    test('a note with every third line rewritten is not, by design', () {
      // The missed-match direction, on record: this much rewriting has
      // replaced most of the note's shingles, and the cost of missing it is
      // one note's history, surfaced. The alternative bias is the silent one.
      final worst = worstCase((lines) {
        final out = [...lines];
        for (var i = 0; i < out.length; i += 3) {
          if (out[i].trim().isNotEmpty) out[i] = 'rewritten line $i entirely';
        }
        return out;
      });
      expect(worst, lessThan(renameSimilarityCutoff));
    });
  });
}
