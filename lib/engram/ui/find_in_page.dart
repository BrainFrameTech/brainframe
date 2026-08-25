import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/gen/app_localizations.dart';

/// Every non-overlapping occurrence of [query] in [text], in document order.
///
/// Matching is plain substring matching, case-insensitive by default — no
/// regular expressions and no whole-word rule, which is what "find in page"
/// means to a reader typing a few letters. An empty [query] matches nothing
/// (rather than every position), so an empty find field highlights nothing.
///
/// Overlaps are impossible by construction: the scan resumes at the end of the
/// match it just took, so `aa` in `aaaa` yields two matches, not three.
///
/// Kept top-level and pure so the search itself is unit-testable without a
/// widget in sight.
List<TextRange> findMatches(
  String text,
  String query, {
  bool caseSensitive = false,
}) {
  if (query.isEmpty || text.isEmpty) return const <TextRange>[];
  final haystack = caseSensitive ? text : text.toLowerCase();
  final needle = caseSensitive ? query : query.toLowerCase();
  // The offsets found in the folded text are handed straight to the editor to
  // highlight in the *unfolded* text, so the fold must not move any character:
  // Dart's case mapping is per-code-unit, and this is the invariant that
  // relies on it.
  assert(haystack.length == text.length && needle.length == query.length);

  final matches = <TextRange>[];
  var start = haystack.indexOf(needle);
  while (start >= 0) {
    final end = start + needle.length;
    matches.add(TextRange(start: start, end: end));
    start = haystack.indexOf(needle, end);
  }
  return matches;
}

/// The find bar shown under the editor header: a query field, a match counter,
/// previous/next steppers and a close button.
///
/// Deliberately stateless — the host owns the query [controller], the [focusNode]
/// and the match bookkeeping, because it is the host that must also highlight
/// the matches in the document and decide what happens when the bar closes.
///
/// Keyboard: Enter steps to the next match, Shift+Enter to the previous one,
/// and Escape closes the bar — the conventions every find bar is expected to
/// honor, so a keyboard user never needs the buttons.
class FindInPageBar extends StatelessWidget {
  const FindInPageBar({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.matchCount,
    required this.activeMatch,
    required this.onChanged,
    required this.onNext,
    required this.onPrevious,
    required this.onClose,
  });

  /// The query field's controller, owned by the host so the query survives the
  /// bar being closed and reopened.
  final TextEditingController controller;

  /// Focus for the query field, so the host can put the caret in it on open.
  final FocusNode focusNode;

  /// How many matches the current query has in the document.
  final int matchCount;

  /// The zero-based index of the highlighted match, or -1 when there is none.
  final int activeMatch;

  final ValueChanged<String> onChanged;
  final VoidCallback onNext;
  final VoidCallback onPrevious;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final hasMatches = matchCount > 0;

    return Semantics(
      container: true,
      label: l10n.findInPageTooltip,
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.escape): onClose,
          // Enter is handled by the field's onSubmitted (which keeps focus);
          // only the shifted form needs binding here.
          const SingleActivator(LogicalKeyboardKey.enter, shift: true):
              _stepPrevious,
        },
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  onChanged: onChanged,
                  onSubmitted: (_) => _stepNext(),
                  // Supplying this at all suppresses the field's default
                  // "submitting is finishing" behavior, which unfocuses on
                  // Enter. Here Enter means "next match", so the caret has to
                  // stay in the query field — otherwise it works exactly once.
                  onEditingComplete: () {},
                  // Enter means "next match", so the field must not consume it
                  // as a newline.
                  maxLines: 1,
                  textInputAction: TextInputAction.search,
                  decoration: InputDecoration(
                    isDense: true,
                    labelText: l10n.findFieldLabel,
                    prefixIcon: const Icon(Icons.search, size: 20),
                    border: const OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // A live region so a screen reader announces the count changing
              // as the user types, without them having to hunt for it.
              Semantics(
                liveRegion: true,
                child: Text(
                  _counterText(l10n),
                  style: theme.textTheme.labelMedium,
                ),
              ),
              const SizedBox(width: 4),
              IconButton(
                icon: const Icon(Icons.keyboard_arrow_up),
                tooltip: l10n.findPrevious,
                onPressed: hasMatches ? onPrevious : null,
              ),
              IconButton(
                icon: const Icon(Icons.keyboard_arrow_down),
                tooltip: l10n.findNext,
                onPressed: hasMatches ? onNext : null,
              ),
              IconButton(
                icon: const Icon(Icons.close),
                tooltip: l10n.findClose,
                onPressed: onClose,
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _stepNext() {
    if (matchCount > 0) onNext();
  }

  void _stepPrevious() {
    if (matchCount > 0) onPrevious();
  }

  /// `3 of 12` while there are matches, "No results" once the query has text
  /// but nothing matches, and nothing at all for an empty query — an empty
  /// field has not failed to find anything yet.
  String _counterText(AppLocalizations l10n) {
    if (controller.text.isEmpty) return '';
    if (matchCount == 0) return l10n.findNoMatches;
    return l10n.findMatchCount(activeMatch + 1, matchCount);
  }
}
