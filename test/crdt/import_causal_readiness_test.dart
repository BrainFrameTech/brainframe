// Characterization test for `crdt_lf`'s import contract.
//
// This is NOT part of the frozen edge-case suite. It pins the behaviour of a
// dependency that Decision 9 of docs/design/note-identity-and-crdt.md relies
// on: what `CRDTDocument.importChanges` does with a change whose causal
// ancestors are absent.
//
// The answer shapes the importer. `importChanges` catches every exception a
// change raises — `CausallyNotReadyException` included — and skips it, so an
// unready change is silently DROPPED rather than buffered or reported. The
// only signal available to a caller is the returned count of applied changes.
//
// If a future version of `crdt_lf` starts buffering, throwing, or reporting
// these, this test fails and the importer's retry logic should be revisited.
import 'package:crdt_lf/crdt_lf.dart';
import 'package:flutter_test/flutter_test.dart';

const _peerA = '784ff372-6f0a-4fe9-8e63-19b72fd18c23';
const _peerB = 'a90dfced-cbf0-4a49-9c64-f5b7b62fdc18';
const _peerC = 'c1d2e3f4-5a6b-4c7d-8e9f-0a1b2c3d4e5f';

CRDTDocument _doc(String uuid) => CRDTDocument(peerId: PeerId.parse(uuid));

void main() {
  /// Three sequential single-change edits on one document, returned oldest
  /// first. Each depends on the one before it.
  late List<Change> first;
  late List<Change> second;
  late List<Change> third;

  setUp(() {
    final doc = _doc(_peerA);
    final text = CRDTFugueTextHandler(doc, 'text');
    text.insert(0, 'one');
    first = doc.exportChanges();
    text.insert(3, 'two');
    second =
        doc.exportChanges().where((c) => !first.contains(c)).toList();
    text.insert(6, 'three');
    third = doc
        .exportChanges()
        .where((c) => !first.contains(c) && !second.contains(c))
        .toList();
  });

  test('a causally-unready change is dropped, not buffered or thrown', () {
    final doc = _doc(_peerB);
    final text = CRDTFugueTextHandler(doc, 'text');

    // Importing a change whose dependencies are absent does not throw...
    final applied = doc.importChanges(third);

    // ...it reports that nothing was applied, and leaves the document empty.
    expect(applied, 0);
    expect(text.value, isEmpty);
    expect(doc.version, isEmpty);
  });

  test('supplying the ancestors later does not heal a dropped change', () {
    final doc = _doc(_peerB);
    final text = CRDTFugueTextHandler(doc, 'text');

    doc.importChanges(third);
    final applied = doc.importChanges([...first, ...second]);

    // The ancestors apply, but the earlier orphan is gone rather than queued:
    // it is not replayed once its dependencies arrive.
    expect(applied, 2);
    expect(text.value, 'onetwo');

    // It is recoverable only by offering it again.
    expect(doc.importChanges(third), 1);
    expect(text.value, 'onetwothree');
  });

  test('a complete batch applies regardless of the order it is offered in',
      () {
    final doc = _doc(_peerC);
    final text = CRDTFugueTextHandler(doc, 'text');

    // Deliberately reversed: newest first, oldest last, in a single call.
    final reversed = [...third, ...second, ...first];
    final applied = doc.importChanges(reversed);

    // importChanges topologically sorts the batch, so a self-contained set is
    // order-independent. This is what lets Decision 9 import a whole peer file
    // as one batch and never produce an orphan.
    expect(applied, 3);
    expect(text.value, 'onetwothree');
  });
}
