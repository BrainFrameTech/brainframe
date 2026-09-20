import 'dart:math' as math;

import 'package:crdt_lf/crdt_lf.dart' show DiffOp, DiffSegment;

/// The default ceiling on the frontier cells a diff may keep for backtracking.
///
/// 4 M cells is 32 MB of 64-bit ints, held for the duration of one diff and
/// garbage the moment it returns. With windowed rows the trace costs (D+1)²
/// cells, so this admits an edit distance of about 2000 inside one region:
/// every edit a person makes by hand, and a tool's dispersed edit — trailing
/// whitespace stripped from 500 lines is D = 1500 — over a note of ordinary
/// size. What it refuses is a region rewritten almost entirely, and the
/// callers have cheaper answers for that (see `lineChunkedDiff`).
const int defaultMyersTraceCellBudget = 4 * 1024 * 1024;

/// Myers diff with a memory ceiling.
///
/// Same output as crdt_lf's `myersDiff` — coalesced [DiffSegment]s of equal,
/// insert and remove, over UTF-16 code units, with the common prefix and
/// suffix trimmed first — and the same algorithm underneath, with one
/// difference that is the reason this file exists.
///
/// Textbook Myers keeps a copy of its frontier after every step of the edit
/// distance so it can backtrack: memory is O((N+M)·D). That is invisible
/// for the edits the diff is normally fed — a word, a line, a paragraph —
/// and catastrophic for the one it is occasionally fed: a note that has
/// been almost entirely replaced. An 8190-character line diffed against 58
/// characters is D ≈ 8100 steps over a frontier of 16,000 entries, and
/// crdt_lf's implementation allocated **1.07 GB** to answer it. On a desktop
/// that is a one-second blip nobody notices; on a 448 MB Raspberry Pi it is
/// the whole machine, and the kernel killed the app on every open of that
/// engram (the note the flutter-pi backslash bug had inflated, trimmed on
/// disk but still 8190 characters in the op-log).
///
/// Two changes keep the same answer for the common case and bound the rare
/// one:
///
/// - Each kept frontier row holds only the window the step used (2d+1
///   entries) rather than the whole array, so the trace costs (D+1)² cells
///   rather than D·2(N+M). For a small edit in a long line that is the
///   difference between a few hundred cells and tens of thousands.
/// - The rows are counted against [maxTraceCells]. The step that would
///   exceed it does not run: the diff gives up on the middle and reports it
///   as one removal and one insertion, between the equal prefix and suffix.
///   For CRDT purposes that is what a near-total rewrite *is* — there are no
///   surviving elements for a concurrent edit to land beside — so the
///   fallback loses nothing the fine script would have kept.
///
/// Segments are returned in old-text order; `remove` precedes `insert` for
/// one changed region, which is the order `lineChunkedDiff` pairs them in.
///
/// **Offsets are UTF-16 code units** — what `String` indexes by and what the
/// CRDT handler makes one element per — but **no edit ever splits a
/// surrogate pair**: the search compares code points, and the prefix and
/// suffix trims back off rather than stop inside a pair. That is the one
/// place this deliberately differs from crdt_lf's `myersDiff`, which would
/// turn "😀 → 😁" into "keep the high surrogate, replace the low one" — right
/// on one replica, and a lone surrogate (`�` on disk) once merged with a
/// concurrent deletion of the pair. Grapheme clusters are not kept whole;
/// the handler's element is the code unit, so that is not a property this
/// layer could promise on its own.
///
/// This is [myersDiffWithinBudget] with the coarse answer filled in. A caller
/// with a cheaper middle ground — `lineChunkedDiff` can pair changed lines
/// off against each other before giving up on a region — uses the nullable
/// form and decides for itself.
List<DiffSegment> boundedMyersDiff(
  String oldText,
  String newText, {
  int maxTraceCells = defaultMyersTraceCellBudget,
}) =>
    myersDiffWithinBudget(oldText, newText, maxTraceCells: maxTraceCells) ??
    coarseDiff(oldText, newText);

/// The diff, or null when it would need more than [maxTraceCells] cells of
/// trace. The trivial cases — equal, one side empty, a pure insertion or
/// removal after trimming — need no search and are always answered.
List<DiffSegment>? myersDiffWithinBudget(
  String oldText,
  String newText, {
  int maxTraceCells = defaultMyersTraceCellBudget,
}) => _diff(oldText, newText, maxTraceCells);

/// The coarse script: equal prefix, the middle removed and re-inserted whole,
/// equal suffix. What a diff reports for a region past its budget.
List<DiffSegment> coarseDiff(String oldText, String newText) =>
    _diff(oldText, newText, -1)!;

/// [maxTraceCells] < 0 asks for the coarse answer outright; otherwise the
/// search runs within the budget and null reports that it could not.
List<DiffSegment>? _diff(String oldText, String newText, int maxTraceCells) {
  if (oldText == newText) {
    if (oldText.isEmpty) return const [];
    return [_equal(oldText, 0, oldText.length, 0, newText.length)];
  }
  if (oldText.isEmpty) return [_insert(newText, 0, 0, newText.length)];
  if (newText.isEmpty) return [_remove(oldText, 0, oldText.length, 0)];

  final prefixLen = _commonPrefix(oldText, newText);
  final suffixLen = _commonSuffix(oldText, newText, prefixLen);
  final oldMidEnd = oldText.length - suffixLen;
  final newMidEnd = newText.length - suffixLen;

  final segments = <DiffSegment>[];
  if (prefixLen > 0) {
    segments.add(
      _equal(oldText.substring(0, prefixLen), 0, prefixLen, 0, prefixLen),
    );
  }

  final aMid = oldText.substring(prefixLen, oldMidEnd);
  final bMid = newText.substring(prefixLen, newMidEnd);
  if (aMid.isEmpty && bMid.isNotEmpty) {
    segments.add(_insert(bMid, prefixLen, prefixLen, newMidEnd));
  } else if (bMid.isEmpty && aMid.isNotEmpty) {
    segments.add(_remove(aMid, prefixLen, oldMidEnd, prefixLen));
  } else if (aMid.isNotEmpty || bMid.isNotEmpty) {
    // The search runs over code points, so a surrogate pair is one symbol
    // and no edit can ever split one; the offsets it reports are mapped
    // back to code units, which is what the CRDT and its callers count in.
    final a = _Symbols(aMid);
    final b = _Symbols(bMid);
    final edits = maxTraceCells < 0
        ? null
        : _shortestEditScript(a.points, b.points, maxTraceCells);
    if (edits == null) {
      if (maxTraceCells >= 0) return null;
      // The region as a whole, removed and re-inserted. The insertion sits
      // at the end of the removed span in old-text coordinates, as a
      // coalesced script places an insertion that follows a removal.
      segments
        ..add(_remove(aMid, prefixLen, oldMidEnd, prefixLen))
        ..add(_insert(bMid, oldMidEnd, prefixLen, newMidEnd));
    } else {
      segments.addAll(_coalesce(a, b, edits, prefixLen, prefixLen));
    }
  }

  if (suffixLen > 0) {
    segments.add(
      _equal(
        oldText.substring(oldMidEnd),
        oldMidEnd,
        oldText.length,
        newMidEnd,
        newText.length,
      ),
    );
  }
  return segments;
}

DiffSegment _equal(String text, int os, int oe, int ns, int ne) => DiffSegment(
  op: DiffOp.equal,
  text: text,
  oldStart: os,
  oldEnd: oe,
  newStart: ns,
  newEnd: ne,
);

DiffSegment _insert(String text, int at, int ns, int ne) => DiffSegment(
  op: DiffOp.insert,
  text: text,
  oldStart: at,
  oldEnd: at,
  newStart: ns,
  newEnd: ne,
);

DiffSegment _remove(String text, int os, int oe, int at) => DiffSegment(
  op: DiffOp.remove,
  text: text,
  oldStart: os,
  oldEnd: oe,
  newStart: at,
  newEnd: at,
);

bool _isHighSurrogate(int unit) => unit >= 0xD800 && unit <= 0xDBFF;
bool _isLowSurrogate(int unit) => unit >= 0xDC00 && unit <= 0xDFFF;

/// Whether a boundary at [i] in [text] would fall between the two halves of
/// a surrogate pair.
bool _splitsPair(String text, int i) =>
    i > 0 &&
    i < text.length &&
    _isHighSurrogate(text.codeUnitAt(i - 1)) &&
    _isLowSurrogate(text.codeUnitAt(i));

/// The common prefix in code units, never ending inside a surrogate pair.
///
/// Every emoji in a block shares its high surrogate, so "one emoji changed
/// to another" is precisely the edit a plain code-unit prefix would cut in
/// half — keeping the high surrogate and diffing the low one alone. The
/// resulting script is still correct on one replica; merged with a
/// concurrent deletion of the whole pair it leaves a lone surrogate behind,
/// which is not valid text. So the trim backs off to the pair's start.
int _commonPrefix(String a, String b) {
  final n = math.min(a.length, b.length);
  var i = 0;
  while (i < n && a.codeUnitAt(i) == b.codeUnitAt(i)) {
    i++;
  }
  if (_splitsPair(a, i) || _splitsPair(b, i)) i--;
  return i;
}

/// The common suffix in code units, never starting inside a surrogate pair.
int _commonSuffix(String a, String b, int skipPrefix) {
  final aLen = math.max(0, a.length - skipPrefix);
  final bLen = math.max(0, b.length - skipPrefix);
  var i = 0;
  while (i < aLen &&
      i < bLen &&
      a.codeUnitAt(a.length - 1 - i) == b.codeUnitAt(b.length - 1 - i)) {
    i++;
  }
  if (_splitsPair(a, a.length - i) || _splitsPair(b, b.length - i)) i--;
  return i;
}

/// A string as the symbols the search compares — code points — with the
/// code-unit offset of each, so results can be reported in code units.
class _Symbols {
  _Symbols(String text) {
    var offset = 0;
    for (final point in text.runes) {
      points.add(point);
      offsets.add(offset);
      offset += point > 0xFFFF ? 2 : 1;
    }
    offsets.add(offset);
  }

  final points = <int>[];

  /// Code-unit offset of symbol i; one extra entry for the end.
  final offsets = <int>[];
}

enum _EditKind { delete, insert }

class _Edit {
  const _Edit(this.kind, this.x, this.y);

  final _EditKind kind;
  final int x;
  final int y;
}

/// Myers' shortest edit script over two code-unit sequences, or null when
/// the trace it would need exceeds [maxTraceCells].
///
/// Row d of the trace is the frontier window for k in [-d, d]: 2d+1 entries,
/// indexed by k + d. The window is all the backtrack reads, since step d only
/// ever consults row d-1 at k ± 1.
List<_Edit>? _shortestEditScript(List<int> a, List<int> b, int maxTraceCells) {
  final n = a.length;
  final m = b.length;
  final maxD = n + m;
  final offset = maxD;
  final v = List<int>.filled(2 * maxD + 1, 0);
  final trace = <List<int>>[];
  var cells = 0;

  for (var d = 0; d <= maxD; d++) {
    final rowLength = 2 * d + 1;
    if (cells + rowLength > maxTraceCells) return null;
    var finished = false;
    for (var k = -d; k <= d; k += 2) {
      final kIndex = k + offset;
      int x;
      if (k == -d || (k != d && v[kIndex - 1] < v[kIndex + 1])) {
        x = v[kIndex + 1];
      } else {
        x = v[kIndex - 1] + 1;
      }
      var y = x - k;
      while (x < n && y < m && a[x] == b[y]) {
        x++;
        y++;
      }
      v[kIndex] = x;
      if (x >= n && y >= m) finished = true;
    }
    trace.add(v.sublist(offset - d, offset + d + 1));
    cells += rowLength;
    if (finished) break;
  }
  return _reconstructEdits(trace, n, m);
}

List<_Edit> _reconstructEdits(List<List<int>> trace, int n, int m) {
  var x = n;
  var y = m;
  final result = <_Edit>[];
  for (var d = trace.length - 1; d > 0; d--) {
    final prev = trace[d - 1];
    final prevD = d - 1;
    // prev[k + prevD] is the previous row's frontier at diagonal k.
    final k = x - y;
    int prevK;
    if (k == -d || (k != d && prev[k - 1 + prevD] < prev[k + 1 + prevD])) {
      prevK = k + 1;
    } else {
      prevK = k - 1;
    }
    final prevX = prev[prevK + prevD];
    final prevY = prevX - prevK;
    while (x > prevX && y > prevY) {
      x--;
      y--;
    }
    if (x == prevX) {
      result.add(_Edit(_EditKind.insert, x, y - 1));
      y--;
    } else {
      result.add(_Edit(_EditKind.delete, x - 1, y));
      x--;
    }
  }
  return result.reversed.toList();
}

List<DiffSegment> _coalesce(
  _Symbols a,
  _Symbols b,
  List<_Edit> edits,
  int oldOffset,
  int newOffset,
) {
  final out = <DiffSegment>[];
  // Positions in symbols; every offset reported below goes through the
  // symbol tables to become a code-unit offset.
  var ax = 0;
  var by = 0;
  int oldAt(int symbol) => oldOffset + a.offsets[symbol];
  int newAt(int symbol) => newOffset + b.offsets[symbol];

  void push(DiffOp op, String text, int os, int oe, int ns, int ne) {
    if (text.isEmpty) return;
    if (out.isNotEmpty && out.last.op == op) {
      final last = out.last;
      out[out.length - 1] = DiffSegment(
        op: op,
        text: last.text + text,
        oldStart: last.oldStart,
        oldEnd: oe,
        newStart: last.newStart,
        newEnd: ne,
      );
      return;
    }
    out.add(
      DiffSegment(
        op: op,
        text: text,
        oldStart: os,
        oldEnd: oe,
        newStart: ns,
        newEnd: ne,
      ),
    );
  }

  for (final e in edits) {
    if (ax < e.x && by < e.y) {
      push(
        DiffOp.equal,
        String.fromCharCodes(a.points.getRange(ax, e.x)),
        oldAt(ax),
        oldAt(e.x),
        newAt(by),
        newAt(e.y),
      );
      ax = e.x;
      by = e.y;
    }
    if (e.kind == _EditKind.delete) {
      push(
        DiffOp.remove,
        String.fromCharCode(a.points[ax]),
        oldAt(ax),
        oldAt(ax + 1),
        newAt(by),
        newAt(by),
      );
      ax++;
    } else {
      push(
        DiffOp.insert,
        String.fromCharCode(b.points[by]),
        oldAt(ax),
        oldAt(ax),
        newAt(by),
        newAt(by + 1),
      );
      by++;
    }
  }
  // With the common suffix trimmed, the script always ends in an edit, so
  // there is never a trailing equal run left to emit.
  assert(
    ax == a.points.length && by == b.points.length,
    'edit script did not cover both inputs',
  );
  return out;
}
