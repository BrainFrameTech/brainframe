import 'package:flutter/widgets.dart';

/// Drives the desktop Edit menu's Cut / Copy / Paste / Select all against
/// whichever text field the user is working in.
///
/// The clipboard hotkeys themselves need none of this — Flutter's
/// `DefaultTextEditingShortcuts` already binds Ctrl/Cmd+X/C/V/A inside a
/// focused field on every platform, and rebinding them here would only shadow
/// that. The
/// menu items are the reason this exists, and they have a problem the hotkeys
/// do not: opening a Material menu moves focus onto the menu, so by the time an
/// item is tapped, "the focused field" is gone.
///
/// So the tracker remembers the last editable that held focus and falls back to
/// it *only while a menu is open* ([menuOpened] / [menuClosed]). Focus landing
/// somewhere real with no menu open — a file-tree row, say — clears it, and the
/// Edit items correctly grey out. Menu internals take focus after the open
/// callback has run, so they never look like a real focus move.
///
/// On macOS the menu bar belongs to the OS and takes no Flutter focus at all,
/// so the tracker simply reports the focused field there.
class TextEditingCommands extends ChangeNotifier {
  TextEditingCommands({FocusManager? focusManager})
    : _focusManager = focusManager ?? FocusManager.instance {
    _focusManager.addListener(_handleFocusChanged);
    _handleFocusChanged();
  }

  final FocusManager _focusManager;

  /// The editable holding focus right now, or null if focus is elsewhere.
  EditableTextState? _focused;

  /// The last editable to hold focus, consulted only while [_menuOpen].
  EditableTextState? _remembered;

  bool _menuOpen = false;

  /// The controller whose selection changes we are subscribed to, so the menu's
  /// enabled/disabled state follows the selection without polling.
  TextEditingController? _watched;

  bool _canCut = false;
  bool _canCopy = false;
  bool _canPaste = false;
  bool _canSelectAll = false;

  /// Whether there is a selection to cut from an editable field.
  bool get canCut => _canCut;

  /// Whether there is a selection to copy.
  bool get canCopy => _canCopy;

  /// Whether a writable field is available to paste into. The clipboard's own
  /// contents are deliberately not probed: that is an async platform round-trip
  /// per menu build, and pasting nothing is harmless.
  bool get canPaste => _canPaste;

  /// Whether there is text to select. Unlike [canCopy] this needs no existing
  /// selection — that is the whole point of it — but an empty field still has
  /// nothing to act on, and a read-only one (Preview) has nothing selectable.
  bool get canSelectAll => _canSelectAll;

  /// The field the Edit menu acts on, or null when there is none.
  EditableTextState? get target {
    final focused = _focused;
    if (focused != null && focused.mounted) return focused;
    if (!_menuOpen) return null;
    final remembered = _remembered;
    return (remembered != null && remembered.mounted) ? remembered : null;
  }

  /// Announces that a menu has opened, so focus moving into it is not mistaken
  /// for the user leaving the text field.
  void menuOpened() {
    if (_menuOpen) return;
    _menuOpen = true;
    _recompute();
  }

  void menuClosed() {
    if (!_menuOpen) return;
    _menuOpen = false;
    _recompute();
  }

  /// The field a command acts on.
  ///
  /// Unlike [target] this does not require a menu to still be open, because by
  /// the time an item's `onPressed` runs, its menu has already reported itself
  /// closed — `onClose` fires *first*. Gating the action on [target] therefore
  /// let Cut and Copy light up correctly and then quietly do nothing, since the
  /// field had been forgotten a callback earlier. The enabled state stays
  /// menu-gated; only the action reaches back like this, and it can only be
  /// reached from an item that was enabled a moment ago.
  EditableTextState? get _actionTarget {
    final focused = _focused;
    if (focused != null && focused.mounted) return focused;
    final remembered = _remembered;
    return (remembered != null && remembered.mounted) ? remembered : null;
  }

  void cut() {
    final state = _actionTarget;
    if (state == null || state.widget.readOnly) return;
    if (state.widget.obscureText || !_hasSelection(state)) return;
    _restoreFocus(state);
    state.cutSelection(SelectionChangedCause.toolbar);
  }

  void copy() {
    final state = _actionTarget;
    if (state == null || state.widget.obscureText) return;
    if (!_hasSelection(state)) return;
    _restoreFocus(state);
    state.copySelection(SelectionChangedCause.toolbar);
  }

  void paste() {
    final state = _actionTarget;
    if (state == null || state.widget.readOnly) return;
    _restoreFocus(state);
    state.pasteText(SelectionChangedCause.toolbar);
  }

  void selectAll() {
    final state = _actionTarget;
    if (state == null || state.textEditingValue.text.isEmpty) return;
    if (state.widget.readOnly) return;
    _restoreFocus(state);
    state.selectAll(SelectionChangedCause.toolbar);
  }

  /// Returns the caret to the field the command acted on, so the user carries
  /// on typing where they left off rather than in the dismissed menu.
  void _restoreFocus(EditableTextState state) {
    final focusNode = state.widget.focusNode;
    if (!focusNode.hasFocus) focusNode.requestFocus();
  }

  void _handleFocusChanged() {
    final primary = _focusManager.primaryFocus;
    final editable = primary?.context
        ?.findAncestorStateOfType<EditableTextState>();
    if (editable != null) _remembered = editable;
    // Focus settling on some other real control with no menu open is the user
    // genuinely leaving the field; forget it so the Edit items grey out.
    //
    // Merely *losing* focus is not that, and the difference matters: on desktop
    // a text field unfocuses itself whenever a click lands outside it, so
    // clicking the menu bar with a mouse empties the focus a gesture *before*
    // the menu opens and can announce itself. Clearing here would throw away
    // the very field the menu is about to act on — which is exactly what left
    // Cut and Copy greyed out with a live selection on screen. An unfocus like
    // that parks primary focus on the enclosing scope rather than on a control,
    // and that is what tells the two apart.
    if (editable == null && !_menuOpen && _isControl(primary)) {
      _remembered = null;
    }
    _focused = editable;
    // Follow the remembered field's controller too, so a selection change is
    // still seen while focus is parked on a scope mid-click.
    _watch((editable ?? _remembered)?.widget.controller);
    _recompute();
  }

  /// Whether [node] is a control that can hold focus in its own right, as
  /// opposed to a [FocusScopeNode] — where focus lands when a field is simply
  /// unfocused and nothing has claimed it.
  static bool _isControl(FocusNode? node) =>
      node != null && node is! FocusScopeNode;

  void _watch(TextEditingController? controller) {
    if (identical(_watched, controller)) return;
    _watched?.removeListener(_recompute);
    _watched = controller;
    _watched?.addListener(_recompute);
  }

  void _recompute() {
    final state = target;
    final canCopy = state != null && !state.widget.obscureText && _hasSelection(state);
    final canCut = canCopy && !state.widget.readOnly;
    final canPaste = state != null && !state.widget.readOnly;
    final canSelectAll =
        state != null &&
        !state.widget.readOnly &&
        state.textEditingValue.text.isNotEmpty;
    if (canCut == _canCut &&
        canCopy == _canCopy &&
        canPaste == _canPaste &&
        canSelectAll == _canSelectAll) {
      return;
    }
    _canCut = canCut;
    _canCopy = canCopy;
    _canPaste = canPaste;
    _canSelectAll = canSelectAll;
    notifyListeners();
  }

  bool _hasSelection(EditableTextState state) {
    final selection = state.textEditingValue.selection;
    return selection.isValid && !selection.isCollapsed;
  }

  @override
  void dispose() {
    _focusManager.removeListener(_handleFocusChanged);
    _watched?.removeListener(_recompute);
    super.dispose();
  }
}
