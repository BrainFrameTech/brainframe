/// Merging two edits of one text, for the moment an external change reaches
/// a note whose editor holds unsaved typing (the filesystem watcher design,
/// Decision 6).
///
/// Pure Dart: no filesystem, no UI, no CRDT document. The save path and the
/// editor both call it, which is why it lives here rather than beside either.
library;

import 'crdt/line_chunked_diff.dart';
import 'crdt/line_terminators.dart';

/// Merges [mine] and [theirs], two edits of [base], into one text.
///
/// The rule is the CRDT's, so the result is what two devices editing the same
/// base would converge to:
///
/// - **Nothing either side inserted is lost.** Each side's edits are computed
///   against [base] with [lineChunkedDiff], the diff the save path already
///   uses, and edits of the two sides that do not overlap are both applied.
/// - **Where they overlap, both insertions are kept and the base is gone** —
///   [theirs]' text first, then [mine], so the order is stable and the user's
///   own typing lands nearest where they were typing. The base text in an
///   overlap was removed by at least one side, and a removal wins, as a
///   concurrent delete does in the CRDT.
/// - **An edit both sides made identically is applied once.**
///
/// There are no conflict markers and no failure: the cost of the rule is that
/// two different rewrites of one sentence both appear, which the user can see
/// and edit. Two edits overlap when their base ranges share a character, when
/// both insert at the same point, or when one inserts strictly inside a range
/// the other replaces; edits that merely touch do not.
///
/// All three inputs are normalized to LF first (the CRDT design's Decision
/// 10). Otherwise a file converted to CRLF outside the app would be an edit of
/// every line end, and would collide with any typing at the end of a line.
/// The result is LF, which is how the note is written back anyway.
String threeWayMerge({
  required String base,
  required String mine,
  required String theirs,
}) {
  final original = normalizeTerminators(base);
  final ours = normalizeTerminators(mine);
  final other = normalizeTerminators(theirs);
  if (ours == other) return ours;
  if (ours == original) return other;
  if (other == original) return ours;

  final hunks = [
    for (final hunk in _hunks(lineChunkedDiff(original, other)))
      (hunk, _Side.theirs),
    for (final hunk in _hunks(lineChunkedDiff(original, ours)))
      (hunk, _Side.mine),
  ]..sort(_byPosition);

  final out = StringBuffer();
  var cursor = 0;
  for (final cluster in _clusters(hunks)) {
    out.write(original.substring(cursor, cluster.start));
    out.write(cluster.text);
    cursor = cluster.end;
  }
  out.write(original.substring(cursor));
  return out.toString();
}

/// Which input a hunk came from.
enum _Side { theirs, mine }

/// One side's change to one base range: `base[start, end)` becomes [text].
/// A pure insertion has `start == end`.
class _Hunk {
  _Hunk(this.start, this.end, this.text);

  final int start;
  int end;
  String text;

  bool get isInsertion => start == end;

  bool sameAs(_Hunk other) =>
      start == other.start && end == other.end && text == other.text;
}

/// Coalesces [edits] — ascending, non-overlapping, as [lineChunkedDiff]
/// returns them — into hunks, joining edits that touch: a removal and the
/// insertion at its end are one replacement.
List<_Hunk> _hunks(List<TextEdit> edits) {
  final hunks = <_Hunk>[];
  for (final edit in edits) {
    final last = hunks.isEmpty ? null : hunks.last;
    final _Hunk hunk;
    if (last != null && last.end == edit.offset) {
      hunk = last;
    } else {
      hunk = _Hunk(edit.offset, edit.offset, '');
      hunks.add(hunk);
    }
    hunk
      ..end += edit.removeLength
      ..text += edit.insert;
  }
  return hunks;
}

/// Base order, with an insertion before a replacement starting at the same
/// point — it lands before that range, so it cannot overlap it — and, at one
/// point, theirs before mine.
int _byPosition((_Hunk, _Side) a, (_Hunk, _Side) b) {
  final byStart = a.$1.start.compareTo(b.$1.start);
  if (byStart != 0) return byStart;
  final byWidth = (a.$1.end - a.$1.start).compareTo(b.$1.end - b.$1.start);
  if (byWidth != 0) return byWidth;
  return a.$2.index.compareTo(b.$2.index);
}

/// A run of hunks that overlap one another, replacing `base[start, end)`.
class _Cluster {
  _Cluster(_Hunk first, _Side side) : start = first.start, end = first.end {
    add(first, side);
  }

  final int start;
  int end;
  final List<_Hunk> theirs = [];
  final List<_Hunk> mine = [];

  void add(_Hunk hunk, _Side side) {
    (side == _Side.theirs ? theirs : mine).add(hunk);
    if (hunk.end > end) end = hunk.end;
  }

  /// Whether [hunk], which starts at or after every member, overlaps any.
  ///
  /// A member's start is never after [hunk]'s, so an insertion can only be
  /// strictly inside the cluster's range or at its one insertion point, and
  /// a range can only overlap by starting before the cluster ends.
  bool overlaps(_Hunk hunk) {
    if (end > start) {
      return hunk.isInsertion
          ? start < hunk.start && hunk.start < end
          : hunk.start < end;
    }
    // A cluster of insertions, all at [start]: another there joins it; a
    // range starting there lands after them and does not.
    return hunk.isInsertion && hunk.start == start;
  }

  /// What replaces the cluster's range. Every base character in it was
  /// removed by one side or the other, so it is only the insertions: theirs,
  /// then mine — once, when the two sides made the same edit.
  String get text {
    final out = StringBuffer();
    for (final hunk in theirs) {
      out.write(hunk.text);
    }
    if (!_bothSidesAlike) {
      for (final hunk in mine) {
        out.write(hunk.text);
      }
    }
    return out.toString();
  }

  /// Whether the two sides made exactly the same edits here.
  bool get _bothSidesAlike {
    if (theirs.length != mine.length) return false;
    for (var i = 0; i < mine.length; i++) {
      if (!theirs[i].sameAs(mine[i])) return false;
    }
    return true;
  }
}

/// Groups [hunks], sorted by [_byPosition], into clusters of mutual overlap.
List<_Cluster> _clusters(List<(_Hunk, _Side)> hunks) {
  final clusters = <_Cluster>[];
  for (final (hunk, side) in hunks) {
    final current = clusters.isEmpty ? null : clusters.last;
    if (current != null && current.overlaps(hunk)) {
      current.add(hunk, side);
    } else {
      clusters.add(_Cluster(hunk, side));
    }
  }
  return clusters;
}
