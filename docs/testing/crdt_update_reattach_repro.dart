// ignore_for_file: avoid_print
// Minimal repro: an insert whose neighbours are concurrently deleted SURVIVES
// (reattaches to the nearest living anchor), but an `update` of a concurrently
// deleted element LOSES its replacement. Same position, same concurrent delete.
//
// Run:  dart run docs/testing/crdt_update_reattach_repro.dart
// crdt_lf 3.4.2. Expected/actual printed below.
import 'package:crdt_lf/crdt_lf.dart';

String converge({required bool useUpdate}) {
  final a = CRDTDocument(peerId: PeerId.parse('aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'));
  final b = CRDTDocument(peerId: PeerId.parse('bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb'));
  final ta = CRDTFugueTextHandler(a, 'note');
  final tb = CRDTFugueTextHandler(b, 'note');

  ta.insert(0, 'hello world');            // seed on A
  b.importChanges(a.exportChanges());      // A and B both hold "hello world"

  ta.delete(6, 5);                         // A deletes "world"
  if (useUpdate) {
    tb.update(7, '0');                     // B: replace the 'o' with '0'
  } else {
    tb.insert(7, '0');                     // B: insert '0' next to the 'o'
  }

  a.importChanges(b.exportChanges());      // exchange both ways -> converge
  b.importChanges(a.exportChanges());
  assert(ta.value == tb.value);            // convergence holds either way
  return ta.value;
}

void main() {
  print('insert : "${converge(useUpdate: false)}"   (expected "hello 0")');
  print('update : "${converge(useUpdate: true)}"    (expected "hello 0", the replacement is lost)');
}
