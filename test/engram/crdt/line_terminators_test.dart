import 'package:brainframe/engram/crdt/line_terminators.dart';
import 'package:flutter_test/flutter_test.dart';

/// Decision 10's normalization: what it converts, what it deliberately does
/// not, and the identity guarantee the ingest paths rely on.
void main() {
  group('what it converts', () {
    test('a CRLF terminator becomes LF', () {
      expect(normalizeTerminators('one\r\ntwo\r\n'), 'one\ntwo\n');
    });

    test('every terminator in a large file is converted', () {
      final crlf = '${List.generate(500, (i) => 'line $i').join('\r\n')}\r\n';
      final lf = '${List.generate(500, (i) => 'line $i').join('\n')}\n';

      expect(normalizeTerminators(crlf), lf);
    });

    test('mixed terminators all end up LF', () {
      expect(
        normalizeTerminators('a\r\nb\nc\r\nd'),
        'a\nb\nc\nd',
      );
    });

    test('a CRLF with no trailing newline still converts', () {
      expect(normalizeTerminators('a\r\nb'), 'a\nb');
    });

    test('consecutive CRLFs — a blank line — convert to consecutive LFs', () {
      expect(normalizeTerminators('a\r\n\r\nb'), 'a\n\nb');
    });
  });

  group('what it deliberately leaves alone', () {
    test('a lone carriage return is content, not a terminator', () {
      // The line splitter in the reconciliation diff breaks only on \n, so
      // treating a bare \r as a terminator here would give the system two
      // disagreeing notions of where a line ends.
      expect(normalizeTerminators('a\rb'), 'a\rb');
    });

    test('a trailing lone carriage return survives', () {
      expect(normalizeTerminators('a\r'), 'a\r');
    });

    test('a carriage return before an existing LF pair is not over-eaten', () {
      // '\r\r\n' is a lone \r followed by a CRLF: the terminator goes, the
      // content character stays.
      expect(normalizeTerminators('a\r\r\nb'), 'a\r\nb');
    });

    test('text with no carriage returns is unchanged', () {
      expect(normalizeTerminators('one\ntwo\n'), 'one\ntwo\n');
    });

    test('empty text is unchanged', () {
      expect(normalizeTerminators(''), '');
    });
  });

  group('why there is no guard in front of replaceAll', () {
    test('replaceAll returns the receiver when there is no match', () {
      // The implementation drops a `contains` guard on the grounds that
      // replaceAll already allocates nothing when the pattern is absent. That
      // is a claim about the SDK, and an unpinned claim about a library's
      // behaviour is exactly what put a wrong atomicity guarantee into
      // Decision 6 — so it is pinned rather than trusted. If this fails, the
      // comment in line_terminators.dart is what needs revisiting, not this
      // test: the cost is one allocation per seed, never correctness.
      final text = 'one\ntwo\nthree\n';

      expect(identical(normalizeTerminators(text), text), isTrue);
    });

    test('normalizing is idempotent', () {
      const raw = 'a\r\nb\r\nc';
      final once = normalizeTerminators(raw);

      expect(normalizeTerminators(once), once);
    });
  });

  group('astral-plane characters', () {
    test('an emoji beside a converted terminator is intact', () {
      expect(normalizeTerminators('🎉\r\n🎈'), '🎉\n🎈');
    });

    test('surrogate pairs are never split by the replacement', () {
      final before = '${List.generate(200, (i) => '🎉 line $i').join('\r\n')}\n';
      final after = normalizeTerminators(before);

      // Re-encoding proves no half-pair survived: a split surrogate does not
      // round-trip through runes.
      expect(String.fromCharCodes(after.runes), after);
      expect(after.contains('\r'), isFalse);
      expect('🎉'.allMatches(after).length, 200);
    });
  });
}
