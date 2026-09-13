/// The editor's status bar: what the note weighs, and how close it is to
/// the limit (the note size ceiling design, Decision 5).
///
/// Three labeled counts — bytes as the file would be on disk, words, lines —
/// and, in the slot beside them, one of: nothing; a warning that the note is
/// near the limit, which is a button to a fuller explanation; the wall —
/// the note is over the limit — which is a button to the decision; or, for
/// a plain-file note, the line that says which regime it is in. That slot is
/// the one place a user can find out whether a note keeps a history, which
/// is why it is here and not in the tree. The wall is the same surface as
/// the warning, whichever door the note came through: typing past the
/// limit, a refused paste, or an edit made outside the app (Decision 4).
///
/// **Counted at most once per [repaintInterval], not once per keystroke.**
/// The editor notifies on every edit; counting 128 KiB of text is a few
/// milliseconds, which is nothing on a desktop and something on a Pi at
/// typing speed. A burst of typing is one count, taken when the burst has
/// paused for the interval, and the bar is never more than that far behind.
/// Nothing animates: a state change is a repaint, which is what e-ink and
/// Reduce Motion both ask for.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../l10n/gen/app_localizations.dart';
import '../crdt/catalog.dart';

/// What the bar shows about a note's text.
class NoteCounts {
  const NoteCounts({
    required this.bytes,
    required this.words,
    required this.lines,
  });

  /// Counts [text]: bytes as the file would be on disk (UTF-8; the buffer
  /// is LF-normalized, so this is exact — Decision 1), words as runs of
  /// non-whitespace, lines as LF count plus one, or zero for nothing at all.
  ///
  /// Words are whitespace runs and nothing cleverer. That is honest for
  /// Latin scripts and meaningless for CJK, which has no spaces; accepted,
  /// because bytes is the count that matters for the limit and words is a
  /// courtesy. Dart has no word segmenter, and none is worth a dependency.
  factory NoteCounts.of(String text) => NoteCounts(
    bytes: noteSizeInBytes(text),
    words: _word.allMatches(text).length,
    lines: text.isEmpty ? 0 : _newline.allMatches(text).length + 1,
  );

  static final RegExp _word = RegExp(r'\S+');
  static final RegExp _newline = RegExp('\n');

  final int bytes;
  final int words;
  final int lines;

  @override
  bool operator ==(Object other) =>
      other is NoteCounts &&
      other.bytes == bytes &&
      other.words == words &&
      other.lines == lines;

  @override
  int get hashCode => Object.hash(bytes, words, lines);

  @override
  String toString() => 'NoteCounts($bytes bytes, $words words, $lines lines)';
}

/// [value] with the locale's thousands separators — the form the ceiling is
/// stated in, so a user can compare it against a file manager.
String formatDecimal(BuildContext context, int value) =>
    NumberFormat.decimalPattern(
      Localizations.localeOf(context).toString(),
    ).format(value);

/// The bar itself. See the library comment.
class NoteStatusBar extends StatefulWidget {
  const NoteStatusBar({
    super.key,
    required this.text,
    required this.ceilingBytes,
    this.plainFile = false,
    this.onWarningPressed,
    this.onWallPressed,
    this.repaintInterval = const Duration(milliseconds: 150),
  });

  /// The note's current text — the editor's buffer.
  final String text;

  /// The engram's note size ceiling, in bytes on disk (Decision 7): what
  /// the warning is measured against, and what is shown beside the bytes
  /// once the warning is on.
  final int ceilingBytes;

  /// Whether the note is a plain file — `blobLww` at a text path — in which
  /// case the regime line replaces the warning: a plain file has no limit,
  /// and no history to lose to one.
  final bool plainFile;

  /// Opens the explanation of the warning. Null disables the button.
  final VoidCallback? onWarningPressed;

  /// Opens the decision when the note is over the limit. Null disables the
  /// button.
  final VoidCallback? onWallPressed;

  /// The least time between two counts of an edited text.
  final Duration repaintInterval;

  @override
  State<NoteStatusBar> createState() => _NoteStatusBarState();
}

class _NoteStatusBarState extends State<NoteStatusBar> {
  late NoteCounts _counts = NoteCounts.of(widget.text);
  Timer? _recount;

  @override
  void didUpdateWidget(NoteStatusBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.text == oldWidget.text) return;
    // One count per burst: the first change arms the timer, later ones
    // ride on it, and the count that fires sees whatever the text is then.
    _recount ??= Timer(widget.repaintInterval, () {
      _recount = null;
      if (!mounted) return;
      final counts = NoteCounts.of(widget.text);
      if (counts != _counts) setState(() => _counts = counts);
    });
  }

  @override
  void dispose() {
    _recount?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final counts = _counts;
    final wall = !widget.plainFile && counts.bytes > widget.ceilingBytes;
    final warning =
        !widget.plainFile &&
        !wall &&
        counts.bytes >= noteSizeWarningBytes(widget.ceilingBytes);
    final style = TextStyle(fontSize: 12, color: scheme.onSurfaceVariant);
    final bytes = warning || wall
        ? l10n.statusBytesOfLimit(
            formatDecimal(context, counts.bytes),
            formatDecimal(context, widget.ceilingBytes),
          )
        : l10n.statusBytes(formatDecimal(context, counts.bytes));
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerLow,
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              [
                bytes,
                l10n.statusWords(formatDecimal(context, counts.words)),
                l10n.statusLines(formatDecimal(context, counts.lines)),
              ].join(' · '),
              style: style,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (widget.plainFile)
            Semantics(
              liveRegion: true,
              child: Text(l10n.statusPlainFile, style: style),
            )
          else if (wall)
            Semantics(
              liveRegion: true,
              button: true,
              enabled: widget.onWallPressed != null,
              label: l10n.statusOverLimitLabel(
                formatDecimal(context, counts.bytes),
                formatDecimal(context, widget.ceilingBytes),
              ),
              child: ExcludeSemantics(
                child: TextButton.icon(
                  onPressed: widget.onWallPressed,
                  icon: Icon(Icons.block, size: 16, color: scheme.error),
                  label: Text(
                    l10n.statusOverLimit,
                    style: style.copyWith(
                      color: scheme.error,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            )
          else if (warning)
            Semantics(
              liveRegion: true,
              button: true,
              enabled: widget.onWarningPressed != null,
              label: l10n.statusNearLimitLabel(
                formatDecimal(context, counts.bytes),
                formatDecimal(context, widget.ceilingBytes),
              ),
              child: ExcludeSemantics(
                child: TextButton.icon(
                  onPressed: widget.onWarningPressed,
                  icon: Icon(
                    Icons.warning_amber_rounded,
                    size: 16,
                    color: scheme.error,
                  ),
                  label: Text(
                    l10n.statusNearLimit,
                    style: style.copyWith(color: scheme.error),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
