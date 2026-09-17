/// A note's log, replayed one change at a time so each can be shown as
/// what it did to the text.
///
/// A stored `Change` is opaque bytes: the operation inside is decoded by the
/// handler that applies it, and the readable form of a Fugue insertion is
/// not "element (peer, counter) after element (peer, counter)" but the text
/// that appeared. So the monitor rebuilds the document the way the app does
/// — a `CRDTDocument` with the note handler — and imports changes one at a
/// time in causal order, describing the difference in the value after each.
/// A blob's log is a register of digests and is described as such.
library;

import 'package:brainframe/engram/crdt/blob_document_io.dart';
import 'package:brainframe/engram/crdt/catalog.dart';
import 'package:brainframe/engram/crdt/drift.dart';
import 'package:brainframe/engram/crdt/note_document_io.dart';
import 'package:crdt_lf/crdt_lf.dart';
import 'package:hlc_dart/hlc_dart.dart';

import 'store.dart';

/// The longest run of inserted or deleted text shown verbatim; beyond it
/// the middle is elided, since a 40 KB seed is one line of the story.
const int maxShownRun = 72;

/// Replays one document's log and describes each change.
class NoteReplay {
  NoteReplay(this.documentId, {required this.mergePolicy})
    : _document = CRDTDocument(
        // Any peer will do: this document only ever imports, never authors.
        peerId: PeerId.parse('00000000-0000-4000-8000-000000000000'),
        documentId: documentId,
        initialClock: HybridLogicalClock.now(),
      ) {
    if (mergePolicy == MergePolicy.fugueText.name) {
      _text = CRDTFugueTextHandler(_document, noteHandlerId);
    } else {
      _register = CRDTRegisterHandler<ContentDigest>(
        _document,
        blobHandlerId,
        valueCodec: const ContentDigestCodec(),
        handlerType: blobHandlerType,
      );
    }
  }

  final String documentId;

  /// `fugueText` or `blobLww`, as the catalog spells it.
  final String mergePolicy;

  final CRDTDocument _document;
  CRDTFugueTextHandler? _text;
  CRDTRegisterHandler<ContentDigest>? _register;

  /// The document's text after everything applied so far — empty for a blob.
  String get value => _text?.value ?? '';

  /// Applies [stored] and returns what it did, in a phrase — or why it
  /// could not be applied. A change whose dependencies have not arrived is
  /// dropped by `crdt_lf` rather than buffered, which is precisely the
  /// import contract the design pins; the monitor says so instead of
  /// showing nothing.
  String apply(StoredChange stored) {
    final text = _text;
    if (text != null) {
      final before = text.value;
      final applied = _document.importChanges([stored.change]);
      if (applied == 0) return 'not applied — dependencies missing';
      return describeDelta(before, text.value);
    }
    final register = _register!;
    final before = register.value;
    final applied = _document.importChanges([stored.change]);
    if (applied == 0) return 'not applied — dependencies missing';
    final after = register.value;
    if (after == null) return 'cleared';
    final claim = 'claim ${after.hash.substring(0, 12)} (${after.size} bytes)';
    return before == null
        ? claim
        : '$claim, was ${before.hash.substring(0, 12)}';
  }

  void dispose() => _document.dispose();
}

/// A phrase for the difference between [before] and [after]: the inserted
/// and deleted runs around the common prefix and suffix, and the line the
/// edit starts on. Exact for a single contiguous edit — which is what one
/// change from the editor or the reconciler's line-chunked diff is — and a
/// fair summary of anything else.
String describeDelta(String before, String after) {
  if (before == after) return 'no change';
  var prefix = 0;
  final shortest = before.length < after.length ? before.length : after.length;
  while (prefix < shortest && before[prefix] == after[prefix]) {
    prefix++;
  }
  var suffix = 0;
  while (suffix < shortest - prefix &&
      before[before.length - 1 - suffix] == after[after.length - 1 - suffix]) {
    suffix++;
  }
  final deleted = before.substring(prefix, before.length - suffix);
  final inserted = after.substring(prefix, after.length - suffix);
  final line = '\n'.allMatches(before.substring(0, prefix)).length + 1;
  final parts = <String>[
    if (deleted.isNotEmpty) '-${_quote(deleted)}',
    if (inserted.isNotEmpty) '+${_quote(inserted)}',
  ];
  final where = prefix == 0 && before.isEmpty ? 'seed' : 'L$line';
  return '${parts.join(' ')} @$where';
}

String _quote(String run) {
  final shown = run.length <= maxShownRun
      ? run
      : '${run.substring(0, maxShownRun ~/ 2)}…'
            '${run.substring(run.length - maxShownRun ~/ 2)}';
  final escaped = shown
      .replaceAll('\\', r'\\')
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\r')
      .replaceAll('\t', r'\t')
      .replaceAll('"', r'\"');
  return run.length <= maxShownRun
      ? '"$escaped"'
      : '"$escaped" (${run.length} chars)';
}
