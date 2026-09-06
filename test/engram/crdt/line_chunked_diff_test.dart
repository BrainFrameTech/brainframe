import 'dart:math';

import 'package:brainframe/engram/crdt/line_chunked_diff.dart';
import 'package:crdt_lf/crdt_lf.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hlc_dart/hlc_dart.dart';

import '../../crdt/support/peer_ids.dart';

/// The line-chunked diff: minimal edits, bounded refinement, and the
/// concurrent-edit property a single-replica test cannot see.
void main() {
  const documentId = 'note';
  const handlerId = 'note';

  (CRDTDocument, CRDTFugueTextHandler) replica(PeerId peer, {String? seed}) {
    final document = CRDTDocument(
      peerId: peer,
      documentId: documentId,
      initialClock: HybridLogicalClock(l: 100000000000000, c: 0),
    );
    final text = CRDTFugueTextHandler(document, handlerId);
    if (seed != null && seed.isNotEmpty) text.insert(0, seed);
    return (document, text);
  }

  /// Applies [edits] to a plain string, mirroring what the handler does.
  String applyToString(String old, List<TextEdit> edits) {
    final buffer = StringBuffer();
    var cursor = 0;
    for (final edit in edits) {
      buffer.write(old.substring(cursor, edit.offset));
      cursor = edit.offset;
      if (edit.removeLength > 0) {
        cursor += edit.removeLength;
      } else {
        buffer.write(edit.insert);
      }
    }
    buffer.write(old.substring(cursor));
    return buffer.toString();
  }

  /// Total code units the script touches — the measure of its minimality.
  int churn(List<TextEdit> edits) => edits.fold(
    0,
    (sum, edit) => sum + edit.removeLength + edit.insert.length,
  );

  group('the script reproduces the new text', () {
    void roundTrips(String before, String after, {String? reason}) {
      final edits = lineChunkedDiff(before, after);
      expect(applyToString(before, edits), after, reason: reason);
    }

    test('identical texts need no edits', () {
      expect(lineChunkedDiff('same\ntext\n', 'same\ntext\n'), isEmpty);
    });

    test('an empty old text is one insertion', () {
      expect(lineChunkedDiff('', 'hello'), [const TextEdit.insert(0, 'hello')]);
    });

    test('an empty new text is one removal', () {
      expect(lineChunkedDiff('hello', ''), [const TextEdit.remove(0, 5)]);
    });

    test('a word changed inside a line', () {
      roundTrips('one\ntwo\nthree\n', 'one\nTWO\nthree\n');
    });

    test('a line inserted in the middle', () {
      roundTrips('a\nb\n', 'a\nnew\nb\n');
    });

    test('a line removed from the middle', () {
      roundTrips('a\nmiddle\nb\n', 'a\nb\n');
    });

    test('a line appended with no trailing newline', () {
      roundTrips('a\nb', 'a\nb\nc');
    });

    test('a trailing newline added', () {
      roundTrips('a\nb', 'a\nb\n');
    });

    test('a trailing newline removed', () {
      roundTrips('a\nb\n', 'a\nb');
    });

    test('leading lines removed', () {
      roundTrips('x\ny\na\nb\n', 'a\nb\n');
    });

    test('everything replaced', () {
      roundTrips('a\nb\nc\n', 'x\ny\nz\n');
    });

    test('a blank line among content', () {
      roundTrips('a\n\nb\n', 'a\n\n\nb\n');
    });

    test('duplicate lines are handled', () {
      // Repeated content is where a line-keyed alignment is most likely to
      // pair the wrong instances; the result must still be exact.
      roundTrips('x\nx\nx\n', 'x\ny\nx\nx\n');
    });

    test('random edits always round-trip', () {
      // The offsets are the fragile part: every edit is expressed against the
      // old text, so a shift computed wrongly produces a plausible-looking
      // script that reconstructs the wrong string.
      final random = Random(20260906);
      const alphabet = ['alpha', 'beta', 'gamma', '', 'delta', 'x'];
      for (var trial = 0; trial < 300; trial++) {
        String build() => [
          for (var i = 0; i < random.nextInt(12); i++)
            alphabet[random.nextInt(alphabet.length)],
        ].join('\n');
        final before = build();
        final after = build();
        roundTrips(before, after, reason: '"$before" -> "$after"');
      }
    });
  });

  group('a whole-file line-ending change stays cheap', () {
    // These exercise `lineChunkedDiff` directly, which is a diff between two
    // strings and normalizes nothing. Reconciliation no longer reaches it with
    // mixed terminators — `applyExternalText` normalizes first, and the group
    // below asserts that costs *nothing* rather than a little — so this is a
    // property of the algorithm rather than of the path a real edit takes. It
    // stays because it is the sharpest measurement of the chunking: the input
    // where prefix trimming buys nothing and D would otherwise grow with the
    // line count.
    String body(String terminator) => List.generate(
      500,
      (i) => 'line $i with some words in it',
    ).join(terminator);

    test('only the terminators are touched', () {
      final edits = lineChunkedDiff(body('\r\n'), body('\n'));

      // Chunking by line means each refinement sees one line, so the script
      // touches only the 499 carriage returns rather than the whole note.
      expect(churn(edits), 499);
      expect(edits.every((edit) => edit.removeLength == 1), isTrue);
    });

    test('the result is exact', () {
      final before = body('\r\n');
      final after = body('\n');

      expect(applyToString(before, lineChunkedDiff(before, after)), after);
    });

    test('the reverse direction is equally cheap', () {
      final edits = lineChunkedDiff(body('\n'), body('\r\n'));

      expect(churn(edits), 499);
      expect(edits.every((edit) => edit.insert == '\r'), isTrue);
    });

    test('trailing-whitespace stripping is cheap too', () {
      // Same shape as a line-ending change: dispersed, semantically trivial,
      // and fatal to a whole-note diff.
      final before = List.generate(500, (i) => 'line $i   ').join('\n');
      final after = List.generate(500, (i) => 'line $i').join('\n');

      expect(churn(lineChunkedDiff(before, after)), 1500);
      expect(applyToString(before, lineChunkedDiff(before, after)), after);
    });
  });

  group('a line-ending change reconciles to nothing', () {
    // Decision 10's whole purpose, at the door that decides it. "Cheap" is not
    // the bar here: operations are permanent, carry the reconciling device's
    // peerID, and propagate — so a line-ending round trip must cost zero, and
    // the op-log is what has to be measured, not the materialized value.
    test('a CRLF file produces no operations', () {
      final (document, text) = replica(peerA, seed: 'one\ntwo\nthree\n');
      final before = document.exportChanges().length;

      applyExternalText(document, text, 'one\r\ntwo\r\nthree\r\n');

      expect(document.exportChanges().length, before);
      expect(text.value, 'one\ntwo\nthree\n');
    });

    test('a 500-line round trip adds nothing to the log', () {
      final body = List.generate(500, (i) => 'line $i').join('\n');
      final (document, text) = replica(peerA, seed: '$body\n');
      final before = document.exportChanges().length;

      applyExternalText(
        document,
        text,
        '${List.generate(500, (i) => 'line $i').join('\r\n')}\r\n',
      );

      // The unnormalized path would put 500 insertions here, permanently.
      expect(document.exportChanges().length, before);
      expect(text.value.contains('\r'), isFalse);
    });

    test('a real edit alongside a line-ending change costs only the edit', () {
      final (document, text) = replica(peerA, seed: 'one\ntwo\nthree\n');

      applyExternalText(document, text, 'one\r\nTWO\r\nthree\r\n');

      // The terminators are free; the changed word is not.
      expect(text.value, 'one\nTWO\nthree\n');
    });

    test('nothing is attributed to the reconciling device', () {
      // The two-device form: a single-replica test cannot see that the
      // reconciler stamped its own peerID on a hundred edits nobody made.
      final (documentA, textA) = replica(peerA, seed: 'one\ntwo\n');
      final (documentB, textB) = replica(peerB);
      documentB.importChanges(documentA.exportChanges());

      final beforeA = documentA.exportChanges().length;
      textB.insert(textB.value.length, 'three\n');
      applyExternalText(documentA, textA, 'one\r\ntwo\r\n');

      expect(
        documentA.exportChanges().length,
        beforeA,
        reason: 'A generated no operations for a line-ending change',
      );

      documentA.importChanges(documentB.exportChanges());
      documentB.importChanges(documentA.exportChanges());

      expect(textA.value, textB.value);
      expect(textA.value, 'one\ntwo\nthree\n');
    });

    test('a lone carriage return is still content and still diffs', () {
      // Normalization takes \r\n and nothing else, so a bare \r is a real
      // edit and must survive as one.
      final (document, text) = replica(peerA, seed: 'a\nb\n');

      applyExternalText(document, text, 'a\rX\nb\n');

      expect(text.value, 'a\rX\nb\n');
    });
  });

  group('minimal, never replace-all', () {
    test('an untouched line is not rewritten', () {
      final edits = lineChunkedDiff(
        'keep me\nchange me\nkeep me too\n',
        'keep me\nCHANGED\nkeep me too\n',
      );

      // Nothing outside the changed line may appear in the script; anything
      // that does is an element tombstoned for no reason.
      expect(churn(edits), lessThan('change me\nCHANGED\n'.length));
    });

    test('a one-character insertion costs one character', () {
      final edits = lineChunkedDiff('hello world\n', 'hello  world\n');

      expect(churn(edits), 1);
    });

    test('appending a line leaves the existing ones alone', () {
      final edits = lineChunkedDiff('a\nb\n', 'a\nb\nc\n');

      expect(edits, [const TextEdit.insert(4, 'c\n')]);
    });
  });

  group('TextEdit', () {
    test('equal edits are equal', () {
      const a = TextEdit.insert(3, 'x');
      const b = TextEdit.insert(3, 'x');

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('each field participates in equality', () {
      const base = TextEdit.insert(3, 'x');

      expect(base, isNot(const TextEdit.insert(4, 'x')));
      expect(base, isNot(const TextEdit.insert(3, 'y')));
      expect(base, isNot(const TextEdit.remove(3, 1)));
    });

    test('the length delta is signed by direction', () {
      expect(const TextEdit.insert(0, 'abc').lengthDelta, 3);
      expect(const TextEdit.remove(0, 3).lengthDelta, -3);
    });

    test('toString says which kind of edit it is', () {
      expect(const TextEdit.remove(3, 2).toString(), contains('remove'));
      expect(const TextEdit.insert(3, 'ab').toString(), contains('insert'));
    });
  });

  group('concurrent insertions survive an external edit', () {
    test('device B\'s insertion is not discarded by A\'s reconcile', () {
      // The test a single-replica suite cannot write, and the one that fails
      // for a delete-everything-then-insert implementation: that converges,
      // but it tombstones every element B was concurrently editing.
      final (documentA, textA) = replica(peerA, seed: 'one\ntwo\nthree\n');
      final (documentB, textB) = replica(peerB);
      documentB.importChanges(documentA.exportChanges());

      // B appends a line locally, offline.
      textB.insert(textB.value.length, 'four\n');

      // Meanwhile the file behind A was edited outside the app.
      applyExternalText(documentA, textA, 'one\nTWO\nthree\n');

      documentA.importChanges(documentB.exportChanges());
      documentB.importChanges(documentA.exportChanges());

      expect(textA.value, textB.value, reason: 'replicas converge');
      expect(
        textA.value,
        contains('four\n'),
        reason: "B's concurrent insertion must survive A's reconcile",
      );
      expect(textA.value, contains('TWO'));
    });

    test('an edit inside the same line as a concurrent one survives', () {
      final (documentA, textA) = replica(peerA, seed: 'alpha beta gamma\n');
      final (documentB, textB) = replica(peerB);
      documentB.importChanges(documentA.exportChanges());

      // B edits the tail of the line; A's file grew a new word at the head.
      textB.insert('alpha beta '.length, 'DELTA ');
      applyExternalText(documentA, textA, 'ALPHA alpha beta gamma\n');

      documentA.importChanges(documentB.exportChanges());
      documentB.importChanges(documentA.exportChanges());

      expect(textA.value, textB.value);
      expect(textA.value, contains('DELTA'));
      expect(textA.value, contains('ALPHA'));
    });

    test('an edit arriving as CRLF preserves a concurrent insertion', () {
      // The common path: a file edited in a Windows tool syncs back with both
      // a real change and rewritten terminators, while another device is still
      // editing it. The terminators normalize away and must not drag the real
      // edit — or B's insertion — with them. A no-terminator version of this
      // is in "a line-ending change reconciles to nothing"; what is distinct
      // here is the two arriving together.
      final (documentA, textA) = replica(peerA, seed: 'one\ntwo\n');
      final (documentB, textB) = replica(peerB);
      documentB.importChanges(documentA.exportChanges());

      textB.insert(textB.value.length, 'three\n');
      applyExternalText(documentA, textA, 'one\r\nTWO\r\n');

      documentA.importChanges(documentB.exportChanges());
      documentB.importChanges(documentA.exportChanges());

      expect(textA.value, textB.value, reason: 'replicas converge');
      expect(textA.value, contains('three'), reason: "B's insertion survives");
      expect(textA.value, contains('TWO'), reason: "A's external edit lands");
      expect(textA.value.contains('\r'), isFalse);
    });
  });

  group('astral-plane characters', () {
    test('an emoji survives an edit beside it', () {
      // myersDiff works on UTF-16 code units, so a boundary can fall between
      // the halves of a surrogate pair. The materialized string still
      // reconstructs — this asserts that rather than reasoning about it.
      final (document, text) = replica(peerA, seed: 'a 👋 b\n');

      applyExternalText(document, text, 'a 👋 c\n');

      expect(text.value, 'a 👋 c\n');
    });

    test('an emoji is inserted intact', () {
      final (document, text) = replica(peerA, seed: 'hello\n');

      applyExternalText(document, text, 'hello 👋\n');

      expect(text.value, 'hello 👋\n');
      expect(text.value.runes.length, 'hello 👋\n'.runes.length);
    });

    test('an emoji is removed without leaving half of one', () {
      final (document, text) = replica(peerA, seed: 'a 👋 b\n');

      applyExternalText(document, text, 'a  b\n');

      expect(text.value, 'a  b\n');
    });

    test('line keys never split a surrogate pair', () {
      // Lines are keyed by a code point below the surrogate block, so a key is
      // never half a pair even when the note is entirely emoji.
      final before = List.generate(200, (i) => '👋 line $i').join('\r\n');
      final after = List.generate(200, (i) => '👋 line $i').join('\n');

      expect(applyToString(before, lineChunkedDiff(before, after)), after);
    });

    test('a note of astral characters round-trips', () {
      final (document, text) = replica(peerA, seed: '𝄞𝄞𝄞\n𝄞𝄞\n');

      applyExternalText(document, text, '𝄞𝄞𝄞\n𝄞𝄞𝄞𝄞\n');

      expect(text.value, '𝄞𝄞𝄞\n𝄞𝄞𝄞𝄞\n');
    });
  });

  group('the note is never left half edited', () {
    test('a failure while diffing applies nothing', () {
      // The script is computed in full before the first mutation, so there is
      // no window in which some operations exist and the rest do not. This is
      // the guarantee — runInTransaction commits in a finally and rolls
      // nothing back, so it cannot be the one providing it.
      final (document, text) = replica(peerA, seed: 'original\n');

      expect(
        () => applyExternalText(document, text, throw StateError('read fail')),
        throwsStateError,
      );
      expect(text.value, 'original\n');
    });

    test('applying nothing changes nothing', () {
      final (document, text) = replica(peerA, seed: 'unchanged\n');
      final before = document.exportChanges().length;

      applyExternalText(document, text, 'unchanged\n');

      expect(text.value, 'unchanged\n');
      expect(
        document.exportChanges().length,
        before,
        reason: 'an unchanged file must not register an operation',
      );
    });

    test('the whole script surfaces as one update', () async {
      // What the transaction actually buys. It does not merge the script into
      // a single Change — each segment stays its own operation — and it is not
      // a rollback, since its commit runs in a finally. It batches: the
      // changes are created together at commit and one notification is
      // emitted, so nothing downstream observes a note mid-reconcile.
      final (document, text) = replica(peerA, seed: 'a\nb\nc\n');
      var updates = 0;
      final subscription = document.updates.listen((_) => updates++);
      addTearDown(subscription.cancel);

      applyExternalText(document, text, 'A\nb\nC\n');
      await Future<void>.delayed(Duration.zero);

      expect(text.value, 'A\nb\nC\n');
      expect(updates, 1, reason: 'four operations, one notification');
    });

    test('each segment is still its own operation', () {
      // Stated so the batching above is not mistaken for compaction: two
      // replaced lines are four operations, and the reconcile is not one
      // atomic Change that a peer either has or lacks.
      final (document, text) = replica(peerA, seed: 'a\nb\nc\n');
      final before = document.exportChanges().length;

      applyExternalText(document, text, 'A\nb\nC\n');

      expect(document.exportChanges().length, greaterThan(before + 1));
    });
  });

  group('applied through the handler', () {
    test('the document reaches the new text', () {
      final (document, text) = replica(peerA, seed: 'one\ntwo\nthree\n');

      applyExternalText(document, text, 'one\ntwo point five\nthree\nfour\n');

      expect(text.value, 'one\ntwo point five\nthree\nfour\n');
    });

    test('a sequence of external edits accumulates correctly', () {
      final (document, text) = replica(peerA, seed: 'a\n');

      applyExternalText(document, text, 'a\nb\n');
      applyExternalText(document, text, 'a\nb\nc\n');
      applyExternalText(document, text, 'a\nB\nc\n');

      expect(text.value, 'a\nB\nc\n');
    });

    test('an edit script applied to an empty document', () {
      final (document, text) = replica(peerA);

      applyExternalText(document, text, 'first\ncontent\n');

      expect(text.value, 'first\ncontent\n');
    });

    test('a document emptied by an external edit', () {
      final (document, text) = replica(peerA, seed: 'to be removed\n');

      applyExternalText(document, text, '');

      expect(text.value, isEmpty);
    });
  });
}
