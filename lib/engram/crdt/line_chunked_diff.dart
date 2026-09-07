/// Turning an externally edited file back into a minimal set of CRDT
/// operations, without handing a whole note to `myersDiff`.
///
/// Pure Dart: no filesystem, no UI, and `crdt_lf` itself is pure. This is the
/// one place the design deliberately wraps the library rather than calling it
/// directly, and the reason is a missing guard rather than a disagreement
/// about the algorithm.
///
/// **Minimal, never replace-all.** Deleting everything and inserting the new
/// text converges, passes a two-replica test, and is catastrophically wrong:
/// it tombstones every element another device might concurrently be editing,
/// so every concurrent remote insertion is discarded. Nothing about it looks
/// broken until a second device exists.
///
/// **But `CRDTFugueTextHandler.change` must never be handed a whole note.** It
/// calls `myersDiff` on the entire text, which trims the common prefix and
/// suffix and then runs Myers on the remainder with no size guard, snapshotting
/// the frontier once per edit-distance step — memory `O(D × (n + m))`, a
/// product rather than a sum.
///
/// The trigger is not a large note but a **dispersed** edit: one whose changes
/// are spread through the file rather than gathered in one place. Prefix and
/// suffix trimming then buys nothing, `D` grows with the line count, and a
/// 100 KB note of ~2000 lines wants roughly 6.4 GB to express a change that is
/// semantically trivial. Trailing-whitespace stripping across a file, a
/// markdown reflow, and an indentation change all have this shape, and "edited
/// in another tool and synced back" is the case this whole design exists to
/// serve — so these are the common path, not an exotic one.
///
/// So: **chunk by line, refine by character.** Line sequences are diffed
/// first, and `myersDiff` is called only within a changed region, which bounds
/// `D` to one region instead of the note.
///
/// **The line-ending case is handled upstream and no longer arrives here.**
/// Decision 10 normalizes terminators to LF on ingest, so a CRLF round-trip —
/// historically the worst instance of this hazard, and the source of the
/// 6.4 GB figure — produces no operations at all rather than cheap ones. That
/// removes the most vivid example, not the hazard: the dispersed edits above
/// reach this code unchanged, and nothing upstream bounds them.
library;

import 'package:crdt_lf/crdt_lf.dart';

import 'line_terminators.dart';

/// One character-level edit against the old text.
///
/// Either a removal or an insertion, never both — that is the shape
/// `myersDiff` emits, and keeping it means the applier never has to decide
/// which half of a replacement goes first.
class TextEdit {
  const TextEdit.remove(this.offset, this.removeLength) : insert = '';

  const TextEdit.insert(this.offset, this.insert) : removeLength = 0;

  /// Offset into the **old** text. The applier shifts this by the edits
  /// already applied.
  final int offset;

  /// Number of code units removed at [offset].
  final int removeLength;

  /// Text inserted at [offset].
  final String insert;

  /// How much this edit changes the document's length.
  int get lengthDelta => insert.length - removeLength;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TextEdit &&
          other.offset == offset &&
          other.removeLength == removeLength &&
          other.insert == insert;

  @override
  int get hashCode => Object.hash(offset, removeLength, insert);

  @override
  String toString() => removeLength > 0
      ? 'TextEdit.remove($offset, $removeLength)'
      : 'TextEdit.insert($offset, ${insert.length} chars)';
}

/// The minimal edit script taking [oldText] to [newText], in ascending order
/// of offset in [oldText].
///
/// Lines are aligned on their content, ignoring the terminator. Aligned lines
/// whose full text differs, and runs with no counterpart, are each refined
/// with `myersDiff` over that region alone.
///
/// **Excluding the terminator from the key still pays when every terminator is
/// already LF**, which after Decision 10 is the only input that reaches here.
/// A file that gains or loses its trailing newline changes the last line from
/// `bravo` to `bravo\n`; keyed on content those align and the refinement costs
/// one character, while a terminator-inclusive key would fail to align them
/// and delete-and-reinsert the whole line — tombstoning every element in it,
/// which is the concurrent-edit hazard this file exists to avoid, in
/// miniature.
///
/// **No normalization happens here.** This is a diff between two strings and
/// nothing more, which is what lets it be tested without a store; the callers
/// normalize, and [applyExternalText] is the one that matters.
List<TextEdit> lineChunkedDiff(String oldText, String newText) {
  if (identical(oldText, newText) || oldText == newText) return const [];
  if (oldText.isEmpty) {
    return [TextEdit.insert(0, newText)];
  }
  if (newText.isEmpty) {
    return [TextEdit.remove(0, oldText.length)];
  }

  final oldLines = _splitLines(oldText);
  final newLines = _splitLines(newText);
  final keys = _LineKeys();

  final edits = <TextEdit>[];
  final segments = myersDiff(
    keys.stringFor(oldText, oldLines),
    keys.stringFor(newText, newLines),
  );

  for (var i = 0; i < segments.length; i++) {
    final segment = segments[i];
    switch (segment.op) {
      case DiffOp.equal:
        // Aligned line for aligned line. The contents matched — possibly only
        // by hash — so each pair is still compared in full, and a pair that
        // differs is refined on its own. This is the path a CRLF round-trip
        // takes: every line aligns, and each refinement sees one line.
        for (var k = 0; k < segment.oldEnd - segment.oldStart; k++) {
          final before = oldLines[segment.oldStart + k];
          final after = newLines[segment.newStart + k];
          final beforeText = before.textIn(oldText);
          final afterText = after.textIn(newText);
          if (beforeText != afterText) {
            _refine(edits, beforeText, afterText, before.start);
          }
        }
      case DiffOp.remove:
        final removedFrom = oldLines[segment.oldStart].start;
        final removedTo = oldLines[segment.oldEnd - 1].end;
        // A removal immediately followed by an insertion is one changed
        // region, and refining the pair is what keeps the edit minimal:
        // emitting them whole would tombstone every element in it, which is
        // replace-all at the scale of a region.
        final next = i + 1 < segments.length ? segments[i + 1] : null;
        if (next != null && next.op == DiffOp.insert) {
          _refine(
            edits,
            oldText.substring(removedFrom, removedTo),
            newText.substring(
              newLines[next.newStart].start,
              newLines[next.newEnd - 1].end,
            ),
            removedFrom,
          );
          i++; // The insertion was consumed as the other half of this region.
        } else {
          edits.add(TextEdit.remove(removedFrom, removedTo - removedFrom));
        }
      case DiffOp.insert:
        // A lone insertion: no removed region to pair with, so it lands at the
        // old-text position the diff reports.
        final at = segment.oldStart < oldLines.length
            ? oldLines[segment.oldStart].start
            : oldText.length;
        edits.add(
          TextEdit.insert(
            at,
            newText.substring(
              newLines[segment.newStart].start,
              newLines[segment.newEnd - 1].end,
            ),
          ),
        );
    }
  }
  return edits;
}

/// Refines one changed region character by character, appending to [edits].
///
/// This is the only call to `myersDiff`, and it never sees more than one
/// region — which is the entire point of the line pass above.
void _refine(List<TextEdit> edits, String before, String after, int base) {
  for (final segment in myersDiff(before, after)) {
    switch (segment.op) {
      case DiffOp.equal:
        break;
      case DiffOp.remove:
        edits.add(
          TextEdit.remove(base + segment.oldStart, segment.text.length),
        );
      case DiffOp.insert:
        edits.add(TextEdit.insert(base + segment.oldStart, segment.text));
    }
  }
}

/// Applies [newText] to [text] as a minimal set of operations.
///
/// The script is computed **in full before the first mutation**, so a failure
/// while diffing leaves the note untouched rather than half edited. That
/// ordering is what provides the guarantee, and it is worth being exact about
/// why it has to: `runInTransaction` is not a rollback. Its `commit` runs in a
/// `finally`, so a throw part-way through the script still flushes the
/// operations already registered.
///
/// What the transaction does provide is that the whole script's `Change`
/// objects are created together at commit and surface as **one** update
/// notification rather than one per segment — so nothing downstream sees a
/// note mid-reconcile. It does not merge the script into a single `Change`;
/// each segment is still its own operation.
///
/// Operations carry this device's peerID, because we genuinely do not know who
/// made the external edit. They are indistinguishable from local edits, which
/// is the honest answer rather than a limitation.
///
/// **[newText] is normalized to LF before it is diffed** (Decision 10). This is
/// the reconciliation door in the plan's list, and it is the one that decides
/// whether a file arriving from a Windows tool costs anything: normalized, a
/// pure line-ending change diffs to nothing and **no operations are generated
/// at all**, so the log does not grow and no edit is misattributed to whichever
/// device happened to reconcile.
///
/// Unconditional, the way `NoteDocument.insert` is — but not because a policy
/// was checked. This function is handed a [CRDTFugueTextHandler] rather than a
/// note, deliberately, since that is what lets it be tested against bare
/// replicas with no store behind them; there is no merge policy in scope here
/// to consult. What keeps a `blobLww` note safe is Decision 3: its op-log
/// carries a hash and a stamp, never the bytes, so its sequence is empty and
/// nothing calls this for one. That is a property of the caller, not a guard
/// here.
void applyExternalText(
  CRDTDocument document,
  CRDTFugueTextHandler text,
  String newText,
) {
  // The handler's value is already LF — every door into a sequence normalizes
  // — so normalizing the incoming side is what makes the two comparable.
  final edits = lineChunkedDiff(text.value, normalizeTerminators(newText));
  if (edits.isEmpty) return;
  document.runInTransaction(() => applyTextEdits(text, edits));
}

/// Applies [edits] to [text], shifting each offset by the edits before it.
///
/// [edits] are offsets into the text as it was when they were computed, so the
/// running shift is what converts them to positions in the text as it is now —
/// the same bookkeeping `CRDTFugueTextHandler.change` does, over a script it
/// did not produce by diffing the whole note.
void applyTextEdits(CRDTFugueTextHandler text, List<TextEdit> edits) {
  var shift = 0;
  for (final edit in edits) {
    if (edit.removeLength > 0) {
      text.delete(edit.offset + shift, edit.removeLength);
    } else {
      text.insert(edit.offset + shift, edit.insert);
    }
    shift += edit.lengthDelta;
  }
}

/// One line: where it starts, where its terminator starts, and where it ends.
class _Line {
  const _Line(this.start, this.contentEnd, this.end);

  final int start;
  final int contentEnd;
  final int end;

  String contentIn(String text) => text.substring(start, contentEnd);

  String textIn(String text) => text.substring(start, end);
}

/// Splits [text] into lines, keeping terminators so the parts rejoin exactly.
///
/// A line's *content* excludes its terminator, which is what lets `\r\n` and
/// `\n` versions of one line align with each other.
List<_Line> _splitLines(String text) {
  final lines = <_Line>[];
  var start = 0;
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) != 0x0a) continue;
    final hasCarriageReturn = i > start && text.codeUnitAt(i - 1) == 0x0d;
    lines.add(_Line(start, hasCarriageReturn ? i - 1 : i, i + 1));
    start = i + 1;
  }
  if (start < text.length) lines.add(_Line(start, text.length, text.length));
  return lines;
}

/// Maps line contents to single code units, so the line pass can reuse
/// `myersDiff` rather than a second Myers implementation living here.
///
/// Distinct contents get distinct units until the budget is exhausted, after
/// which they wrap and collide. A collision costs alignment quality and never
/// correctness: two lines that map alike are still compared in full by the
/// equal-run walk, and a pair that differs is refined like any other.
class _LineKeys {
  /// Code points below the surrogate block, so no key is ever half a pair.
  static const int _budget = 0xd800;

  final Map<String, int> _ids = {};

  String stringFor(String text, List<_Line> lines) {
    final units = <int>[];
    for (final line in lines) {
      final content = line.contentIn(text);
      units.add((_ids[content] ??= _ids.length) % _budget);
    }
    return String.fromCharCodes(units);
  }
}
