// Characterization test for the hazard that motivates Decision 9's seed claim.
//
// This is NOT part of the frozen edge-case suite. It pins a property of
// `crdt_lf` that makes an otherwise reasonable design catastrophic: adopting a
// note's ULID from the identity map does NOT make two devices' documents
// compatible. Fugue merges on *element* identity — the per-character
// `(peerId, counter)` pairs that live only in the op-log — so two devices that
// independently seed one document id hold disjoint character universes, and
// the merge correctly concludes they are concurrent insertions of both texts.
//
// The result is duplicated content rather than lost history, which is strictly
// worse than the divergent-ULID case it was meant to fix. Hence the rule in
// Decision 7: a device never seeds a document under a ULID it did not mint,
// and Decision 9's seed claim decides who may.
import 'package:crdt_lf/crdt_lf.dart';
import 'package:flutter_test/flutter_test.dart';

const _peerA = '784ff372-6f0a-4fe9-8e63-19b72fd18c23';
const _peerB = 'a90dfced-cbf0-4a49-9c64-f5b7b62fdc18';

(CRDTDocument, CRDTFugueTextHandler) _seeded(String peer, String text) {
  final doc = CRDTDocument(peerId: PeerId.parse(peer));
  final handler = CRDTFugueTextHandler(doc, 'text')..insert(0, text);
  return (doc, handler);
}

void main() {
  test('two devices seeding one document id duplicate its content', () {
    const markdown = 'Hello world';
    final (docA, textA) = _seeded(_peerA, markdown);
    final (docB, textB) = _seeded(_peerB, markdown);

    // Each device believes it holds the note identified by one shared ULID.
    expect(textA.value, markdown);
    expect(textB.value, markdown);

    // #67 delivers each peer's changes to the other under that one id.
    docA.importChanges(docB.exportChanges());
    docB.importChanges(docA.exportChanges());

    // They converge — on the concatenation. Identical text is not identical
    // identity, and nothing in the merge can tell that these were meant to be
    // the same characters.
    expect(textA.value, markdown * 2);
    expect(textA.value, textB.value);
  });

  test('a device that adopts without seeding merges cleanly', () {
    const markdown = 'Hello world';
    final (docA, textA) = _seeded(_peerA, markdown);

    // Device B adopted the ULID but did NOT seed: no handler, no operations.
    // It receives A's log first, which is the rule Decision 7 enforces.
    final docB = CRDTDocument(peerId: PeerId.parse(_peerB));
    final textB = CRDTFugueTextHandler(docB, 'text');
    docB.importChanges(docA.exportChanges());

    expect(textB.value, markdown);

    // B's later edit builds on A's element identities, so it merges rather
    // than duplicating.
    textB.insert(markdown.length, '!');
    docA.importChanges(docB.exportChanges());

    expect(textA.value, 'Hello world!');
    expect(textA.value, textB.value);
  });
}
