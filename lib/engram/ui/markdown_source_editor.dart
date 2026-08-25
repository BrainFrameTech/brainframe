import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';

/// Cross-platform monospace fallbacks, tried in order. No monospace font is
/// bundled, so this leans on whatever each platform ships; the last entry is
/// the generic family name Android resolves.
const List<String> _monospaceFallback = <String>[
  'Menlo', // macOS / iOS
  'Consolas', // Windows
  'DejaVu Sans Mono', // Linux
  'Courier New',
  'monospace',
];

/// A plain multiline source editor for one Markdown file — the swappable seam
/// (design: "The editing surface (a swappable seam)").
///
/// Its contract is deliberately narrow: [initialText] in, [onChanged] out, plus
/// an optional [focusNode] and [scrollController] the host owns so it can flush
/// saves on focus loss and drive scrolling. Nothing above it knows it is a
/// [TextField], so the internals can later be swapped for a code-editor package
/// behind this one widget without touching the save controller, toggle, or
/// browser.
///
/// Cut / copy / paste come from three triggers. The hotkeys and the right-click
/// menu are Flutter's own; the third, press-and-hold, is not. Flutter restricts
/// its long-press-to-menu gesture to touch input, so on a desktop with a mouse
/// nothing happens — [_LongPressContextMenu] adds it back for pointer devices,
/// leaving touch to the framework so a finger never fires both.
class MarkdownSourceEditor extends StatefulWidget {
  const MarkdownSourceEditor({
    super.key,
    required this.initialText,
    this.onChanged,
    this.focusNode,
    this.scrollController,
    this.controller,
    this.matches = const <TextRange>[],
    this.activeMatch = -1,
  });

  /// The file's source when the editor is first built. If it changes to a
  /// different value (a different file loaded into the same widget slot), the
  /// editor adopts the new text — see [State.didUpdateWidget].
  final String initialText;

  /// Called on every edit with the full current text.
  final ValueChanged<String>? onChanged;

  /// Focus for the underlying field; the host supplies it to flush on focus
  /// loss.
  final FocusNode? focusNode;

  /// Scroll controller for the field's own vertical scrolling.
  final ScrollController? scrollController;

  /// A handle for the one thing the host cannot express declaratively: putting
  /// the caret on a range (see [SourceEditorController]).
  final SourceEditorController? controller;

  /// Ranges to highlight — the find bar's matches.
  ///
  /// Painted by the text controller's own span builder rather than through the
  /// field's selection, so they stay visible while the caret is elsewhere
  /// entirely — which it is throughout a search, sitting in the find field.
  final List<TextRange> matches;

  /// Which of [matches] is the current one: emphasized, and scrolled into view
  /// when it changes. -1 when there is none.
  final int activeMatch;

  @override
  State<MarkdownSourceEditor> createState() => _MarkdownSourceEditorState();
}

/// A handle on a mounted [MarkdownSourceEditor], so its host can place the
/// caret without knowing what widget renders the text.
///
/// Everything else about the editor is declarative — text in, changes out,
/// ranges to highlight — but "put the caret here, now" is an event, not a
/// state, and modelling it as one would mean the host could never move the
/// caret to the same range twice. The attach/detach shape mirrors
/// `EngramBrowserController`.
class SourceEditorController {
  _MarkdownSourceEditorState? _state;

  /// Whether an editor is currently attached — false before the editor mounts
  /// and after it is disposed.
  bool get isAttached => _state != null;

  /// Selects [range] in the editor and gives it focus. A no-op when no editor
  /// is attached; the range is clamped to the text, so a stale one cannot
  /// throw.
  void selectRange(TextRange range) => _state?._selectRange(range);

  void _attach(_MarkdownSourceEditorState state) => _state = state;

  void _detach(_MarkdownSourceEditorState state) {
    if (identical(_state, state)) _state = null;
  }
}

class _MarkdownSourceEditorState extends State<MarkdownSourceEditor> {
  late final _HighlightingTextEditingController _controller =
      _HighlightingTextEditingController(text: widget.initialText);

  /// Ours only when the host supplied none. The press-and-hold menu needs a
  /// node it can reach — it is the handle on the [EditableText] below.
  FocusNode? _ownedFocusNode;

  FocusNode get _focusNode =>
      widget.focusNode ?? (_ownedFocusNode ??= FocusNode());

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(this);
  }

  @override
  void didUpdateWidget(MarkdownSourceEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }
    // A different file (or an external reset) arrived without the widget being
    // recreated. Adopt it, but don't clobber a matching in-progress buffer, and
    // place the caret at the end of the freshly loaded text.
    if (widget.initialText != oldWidget.initialText &&
        widget.initialText != _controller.text) {
      _controller.value = TextEditingValue(
        text: widget.initialText,
        selection: TextSelection.collapsed(offset: widget.initialText.length),
      );
    }
    // Stepping to another match has to bring it on screen: the field scrolls
    // itself for typing and taps, but never for ranges handed to it.
    if (widget.activeMatch != oldWidget.activeMatch ||
        widget.matches != oldWidget.matches) {
      _revealAfterFrame(_activeRange);
    }
  }

  @override
  void dispose() {
    widget.controller?._detach(this);
    _controller.dispose();
    _ownedFocusNode?.dispose();
    super.dispose();
  }

  /// The current match, or null when there is none.
  TextRange? get _activeRange {
    final index = widget.activeMatch;
    if (index < 0 || index >= widget.matches.length) return null;
    return widget.matches[index];
  }

  /// Places the caret over [range] and focuses the field, so the user carries
  /// on typing at the match they just found.
  void _selectRange(TextRange range) {
    final length = _controller.text.length;
    final start = range.start.clamp(0, length);
    final end = range.end.clamp(start, length);
    _focusNode.requestFocus();
    _controller.selection = TextSelection(baseOffset: start, extentOffset: end);
    _revealAfterFrame(TextRange(start: start, end: end));
  }

  /// Scrolls [range] into view once the frame that laid it out has been drawn.
  void _revealAfterFrame(TextRange? range) {
    if (range == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Only the [EditableText] below knows how to turn a text offset into a
      // scroll position; reach it through the focus node's context, the same
      // way the press-and-hold menu reaches it.
      final state = _focusNode.context
          ?.findAncestorStateOfType<EditableTextState>();
      if (state == null) return;
      final offset = range.start.clamp(0, _controller.text.length);
      state.bringIntoView(TextPosition(offset: offset));
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Reduce Motion (and the e-ink target): don't animate the cursor's opacity
    // fade. The blink cadence itself is Flutter's and has no public disable, so
    // this turns off the animation the framework does expose.
    final reduceMotion = MediaQuery.disableAnimationsOf(context);
    // Assigned, not notified: this runs inside build, and a notifying
    // controller would be marking its own listeners dirty mid-build. The field
    // below is (re)built by this very build, so it reads the new ranges anyway.
    _controller.matches = widget.matches;
    _controller.activeMatch = widget.activeMatch;
    _controller.matchStyle = TextStyle(
      backgroundColor: theme.colorScheme.secondaryContainer,
      color: theme.colorScheme.onSecondaryContainer,
    );
    _controller.activeMatchStyle = TextStyle(
      backgroundColor: theme.colorScheme.primary,
      color: theme.colorScheme.onPrimary,
    );
    return Semantics(
      label: AppLocalizations.of(context).markdownEditorLabel,
      textField: true,
      child: _LongPressContextMenu(
        focusNode: _focusNode,
        child: TextField(
          controller: _controller,
          focusNode: _focusNode,
          scrollController: widget.scrollController,
          onChanged: widget.onChanged,
          // Fill the pane and grow with content; the host bounds the height.
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          keyboardType: TextInputType.multiline,
          cursorOpacityAnimates: !reduceMotion,
          // Ambient text scaling and boldText apply automatically; the size is
          // never clamped. Only the family is overridden, to monospace.
          style: theme.textTheme.bodyLarge?.copyWith(
            fontFamily: 'monospace',
            fontFamilyFallback: _monospaceFallback,
            height: 1.4,
          ),
          decoration: const InputDecoration(
            border: InputBorder.none,
            isCollapsed: true,
            contentPadding: EdgeInsets.all(16),
          ),
        ),
      ),
    );
  }
}

/// Adds press-and-hold as a way to open a text field's selection menu.
///
/// Flutter builds its long-press-to-menu gesture for touch only
/// (`TextSelectionGestureDetectorBuilder` restricts the recognizer to
/// [PointerDeviceKind.touch]), so holding a mouse button down over a field does
/// nothing on desktop. This restores it for pointer devices — and *only* those,
/// leaving touch to the framework, so a finger never fires two menus at once.
///
/// The menu shown is the field's own [EditableTextState.showToolbar], so all
/// three triggers — hotkey, right-click and press-and-hold — offer the same
/// adaptive Cut / Copy / Paste / Select All, styled for the platform.
class _LongPressContextMenu extends StatefulWidget {
  const _LongPressContextMenu({required this.focusNode, required this.child});

  /// The field's focus node — the handle on the [EditableText] under it.
  final FocusNode focusNode;

  final Widget child;

  @override
  State<_LongPressContextMenu> createState() => _LongPressContextMenuState();
}

class _LongPressContextMenuState extends State<_LongPressContextMenu> {
  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      gestures: <Type, GestureRecognizerFactory>{
        LongPressGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
              () => LongPressGestureRecognizer(
                debugOwner: this,
                // A trackpad *click* arrives as a mouse press; the trackpad
                // kind is for pan/zoom, so it has no place here. Stylus is
                // included because the framework's touch-only recognizer
                // leaves pen input with no long press either.
                supportedDevices: const <PointerDeviceKind>{
                  PointerDeviceKind.mouse,
                  PointerDeviceKind.stylus,
                },
              ),
              (instance) => instance.onLongPressStart = _handleLongPress,
            ),
      },
      child: widget.child,
    );
  }

  void _handleLongPress(LongPressStartDetails details) {
    if (widget.focusNode.hasFocus) {
      _showMenu(details.globalPosition);
      return;
    }
    // A field only has a selection overlay to show once it has focus, so wait
    // for the focus change to land before asking for the menu.
    widget.focusNode.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showMenu(details.globalPosition);
    });
  }

  void _showMenu(Offset globalPosition) {
    final state = widget.focusNode.context
        ?.findAncestorStateOfType<EditableTextState>();
    if (state == null) return;
    // Select the word under the pointer first, exactly as the framework's own
    // long press does, so the menu opens anchored to real content rather than
    // wherever the caret happened to be.
    final render = state.renderEditable;
    render.handleTapDown(TapDownDetails(globalPosition: globalPosition));
    render.selectWord(cause: SelectionChangedCause.longPress);
    state.showToolbar();
  }
}

/// A text controller that paints [matches] behind the text.
///
/// [TextEditingController.buildTextSpan] is the one hook a field gives for
/// styling ranges of its own content, and unlike the field's selection it is
/// painted whether or not the field has focus — which is the whole reason find
/// highlights use it: while the user is typing a query, focus is in the find
/// field, and an unfocused [TextField] paints no selection at all.
class _HighlightingTextEditingController extends TextEditingController {
  _HighlightingTextEditingController({super.text});

  List<TextRange> matches = const <TextRange>[];
  int activeMatch = -1;
  TextStyle? matchStyle;
  TextStyle? activeMatchStyle;

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (matches.isEmpty) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    // The composing underline is dropped while matches are shown: an IME
    // composition and a highlight over the same characters would fight for the
    // same span, and the highlight is what the user is looking at.
    final spans = <TextSpan>[];
    var cursor = 0;
    for (var i = 0; i < matches.length; i++) {
      // Clamp: the text can change between a search and the next repaint.
      final start = matches[i].start.clamp(0, text.length);
      final end = matches[i].end.clamp(start, text.length);
      if (start < cursor) continue;
      if (start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, start)));
      }
      spans.add(
        TextSpan(
          text: text.substring(start, end),
          style: i == activeMatch ? activeMatchStyle : matchStyle,
        ),
      );
      cursor = end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }
    return TextSpan(style: style, children: spans);
  }
}
