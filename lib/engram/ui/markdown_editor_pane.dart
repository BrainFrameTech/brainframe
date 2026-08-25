import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../commands/app_commands.dart';
import '../../l10n/gen/app_localizations.dart';
import '../engram_store.dart';
import 'document_edit_controller.dart';
import 'file_path_breadcrumb.dart';
import 'find_in_page.dart';
import 'markdown_reader.dart';
import 'markdown_source_editor.dart';

/// Which face of the editable pane is showing.
enum _Mode { edit, preview }

/// An editable Markdown pane for a writable engram: an Edit/Preview toggle and a
/// save-status chip in the header, over either the raw source editor (Edit) or
/// the existing read-only reader (Preview).
///
/// Only reached for Markdown files in a writable engram — a read-only engram or
/// a non-Markdown file dispatches elsewhere in `buildFileViewer`. It owns the
/// [DocumentEditController] for the open file for its whole lifetime, switching
/// files through it. Toggling to Preview and losing editor focus both flush, so
/// the reader always renders the current content and edits are never stranded.
///
/// It also owns find-in-page for the open file: the header's magnifying glass
/// and the menu bar's Edit ▸ Find (published through [AppCommands]) open the
/// same [FindInPageBar]. Find searches the document *source*, so opening it
/// from Preview switches back to Edit — a rendered preview has no text offsets
/// to highlight or scroll to.
class MarkdownEditorPane extends StatefulWidget {
  const MarkdownEditorPane({
    super.key,
    required this.store,
    required this.path,
    this.availablePaths = const {},
    this.onNavigateToFile,
  });

  final EngramStore store;
  final String path;
  final Set<String> availablePaths;
  final void Function(String path)? onNavigateToFile;

  @override
  State<MarkdownEditorPane> createState() => _MarkdownEditorPaneState();
}

class _MarkdownEditorPaneState extends State<MarkdownEditorPane> {
  late final DocumentEditController _controller =
      DocumentEditController(store: widget.store);
  final FocusNode _focusNode = FocusNode();
  final ScrollController _scrollController = ScrollController();

  /// The handle used to put the caret on a match when the find bar closes.
  final SourceEditorController _editor = SourceEditorController();

  /// The find bar's own field state, kept for the pane's lifetime so closing
  /// and reopening find offers the previous query again.
  final TextEditingController _findQuery = TextEditingController();
  final FocusNode _findFocus = FocusNode();

  bool _findOpen = false;
  List<TextRange> _matches = const <TextRange>[];

  /// Index into [_matches], or -1 when there is no current match.
  int _activeMatch = -1;

  /// The menu bar's command surface, held from [didChangeDependencies] so
  /// [dispose] can withdraw Find without an inherited-widget lookup.
  AppCommands? _commands;

  _Mode _mode = _Mode.edit;

  /// The path whose content has been loaded into the controller. Until this
  /// matches [widget.path] the pane shows a loading spinner. The text itself is
  /// not cached here — the controller's live buffer is the source of truth, so
  /// re-entering Edit mode reflects edits made before a Preview round-trip.
  String? _loadedPath;
  Object? _loadError;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onControllerChanged);
    _focusNode.addListener(_onFocusChanged);
    _open(widget.path);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _commands = AppCommandsScope.maybeOf(context);
    // Deferred past the frame: publishing notifies the menu bar, an ancestor,
    // and marking one dirty mid-build is not allowed. Find is published on its
    // own channel because it belongs to the open document, which mounts and
    // unmounts independently of the browser publishing everything else.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _commands?.publishFind(_openFind);
    });
  }

  @override
  void didUpdateWidget(MarkdownEditorPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.path != oldWidget.path) {
      _open(widget.path); // openFile flushes the outgoing file first
      // Matches belong to the file they were found in; _open recomputes them
      // against the new text once it has loaded. (No setState here — the pane
      // is already rebuilding, which is why didUpdateWidget was called.)
      _matches = const <TextRange>[];
      _activeMatch = -1;
    }
  }

  Future<void> _open(String path) async {
    try {
      final text = await widget.store.readString(path);
      await _controller.openFile(path, text);
      if (!mounted || widget.path != path) return;
      setState(() {
        _loadedPath = path;
        _loadError = null;
        _mode = _Mode.edit; // a freshly opened file starts in Edit
        // A find left open carries its query to the new file.
        if (_findOpen) _search(_findQuery.text, keepActive: false);
      });
    } catch (error) {
      if (!mounted || widget.path != path) return;
      setState(() => _loadError = error);
    }
  }

  void _onControllerChanged() {
    if (mounted) setState(() {}); // refresh the save-status chip
  }

  void _onFocusChanged() {
    if (!_focusNode.hasFocus) _controller.flush(); // focus-loss flush point
  }

  /// Records an edit, and keeps the find highlights honest while the user types
  /// into a document that is being searched.
  void _onEdit(String text) {
    _controller.edit(text);
    if (_findOpen) setState(() => _search(_findQuery.text));
  }

  Future<void> _setMode(_Mode mode) async {
    if (mode == _mode) return;
    // Toggling to Preview flushes first so the reader renders current content.
    if (mode == _Mode.preview) await _controller.flush();
    if (mounted) setState(() => _mode = mode);
  }

  // ------------------------------------------------------------------ Find

  /// Opens the find bar (or refocuses it, when it is already open) and puts the
  /// caret in the query field with the previous query selected, so typing
  /// replaces it and Ctrl/Cmd+F twice is never a trap.
  ///
  /// Find works on the source, so this leaves Preview.
  void _openFind() {
    // The menu bar can only hold this callback until the end of the frame this
    // pane was disposed in (see [dispose]); ignore an invocation that lands in
    // that window rather than calling setState on a dead State.
    if (!mounted) return;
    if (_mode == _Mode.preview) unawaited(_setMode(_Mode.edit));
    setState(() {
      _findOpen = true;
      _search(_findQuery.text, keepActive: false);
    });
    _findFocus.requestFocus();
    _findQuery.selection = TextSelection(
      baseOffset: 0,
      extentOffset: _findQuery.text.length,
    );
  }

  /// Closes the find bar, handing the caret back to the document — on the match
  /// the user stopped at, so they can carry on editing right there.
  void _closeFind() {
    final landing = (_activeMatch >= 0 && _activeMatch < _matches.length)
        ? _matches[_activeMatch]
        : null;
    setState(() {
      _findOpen = false;
      _matches = const <TextRange>[];
      _activeMatch = -1;
    });
    if (landing != null) {
      _editor.selectRange(landing);
    } else {
      _focusNode.requestFocus();
    }
  }

  /// Recomputes [_matches] for [query]. Call inside a [setState].
  ///
  /// [keepActive] holds the current match index steady where it still exists,
  /// so an edit elsewhere in the document does not throw the user back to the
  /// first match; a new query always starts at the first one.
  void _search(String query, {bool keepActive = true}) {
    _matches = findMatches(_controller.text, query);
    if (_matches.isEmpty) {
      _activeMatch = -1;
    } else if (!keepActive || _activeMatch < 0) {
      _activeMatch = 0;
    } else {
      _activeMatch = _activeMatch.clamp(0, _matches.length - 1);
    }
  }

  void _onQueryChanged(String query) =>
      setState(() => _search(query, keepActive: false));

  /// Steps [delta] matches, wrapping at both ends — past the last match is the
  /// first one, which is what a reader stepping through a document expects.
  void _step(int delta) {
    if (_matches.isEmpty) return;
    setState(() {
      _activeMatch = (_activeMatch + delta) % _matches.length;
      if (_activeMatch < 0) _activeMatch += _matches.length;
    });
  }

  @override
  void dispose() {
    // Deferred to the end of the frame for the same reason publishing is:
    // dispose runs with the tree locked, and withdrawing notifies the menu bar
    // above us, which cannot be marked dirty mid-unmount.
    final commands = _commands;
    final published = _openFind;
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => commands?.withdrawFind(published),
    );
    _focusNode.removeListener(_onFocusChanged);
    _focusNode.dispose();
    _findQuery.dispose();
    _findFocus.dispose();
    _scrollController.dispose();
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (_loadError != null) {
      return Center(
        child: Text(l10n.readerOpenError(widget.path),
            textAlign: TextAlign.center),
      );
    }
    if (_loadedPath != widget.path) {
      return Center(
        child: Semantics(
          label: l10n.readerLoading,
          child: const CircularProgressIndicator.adaptive(),
        ),
      );
    }
    // Ctrl/Cmd+S flushes now — the keyboard equivalent of the save-status chip.
    // Both modifiers are bound so it works on every desktop platform; a focused
    // editor field lets the key event reach here.
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyS, control: true): _saveNow,
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true): _saveNow,
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(
            path: widget.path,
            mode: _mode,
            status: _controller.status,
            findOpen: _findOpen,
            onModeChanged: _setMode,
            onSaveNow: _saveNow,
            onFind: _openFind,
          ),
          if (_findOpen)
            FindInPageBar(
              controller: _findQuery,
              focusNode: _findFocus,
              matchCount: _matches.length,
              activeMatch: _activeMatch,
              onChanged: _onQueryChanged,
              onNext: () => _step(1),
              onPrevious: () => _step(-1),
              onClose: _closeFind,
            ),
          Expanded(child: _content()),
        ],
      ),
    );
  }

  void _saveNow() => unawaited(_controller.flush());

  Widget _content() {
    switch (_mode) {
      case _Mode.edit:
        return MarkdownSourceEditor(
          key: ValueKey(widget.path),
          // The controller's buffer, not the on-open snapshot: re-entering Edit
          // after a Preview round-trip must show the in-progress edits.
          initialText: _controller.text,
          onChanged: _onEdit,
          focusNode: _focusNode,
          scrollController: _scrollController,
          controller: _editor,
          matches: _matches,
          activeMatch: _activeMatch,
        );
      case _Mode.preview:
        return MarkdownReader(
          store: widget.store,
          path: widget.path,
          availablePaths: widget.availablePaths,
          onNavigateToFile: widget.onNavigateToFile,
        );
    }
  }
}

/// The pane header: the file-path breadcrumb, the find button, the save-status
/// chip, and the Edit/Preview toggle.
class _Header extends StatelessWidget {
  const _Header({
    required this.path,
    required this.mode,
    required this.status,
    required this.findOpen,
    required this.onModeChanged,
    required this.onSaveNow,
    required this.onFind,
  });

  final String path;
  final _Mode mode;
  final SaveStatus status;
  final bool findOpen;
  final ValueChanged<_Mode> onModeChanged;
  final VoidCallback onSaveNow;
  final VoidCallback onFind;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 16, 8),
      child: Row(
        children: [
          Expanded(child: FilePathBreadcrumb(path: path)),
          // Toggled rather than a plain button: with the bar open, the glass
          // stays lit so it reads as the thing that opened it.
          Semantics(
            toggled: findOpen,
            child: IconButton(
              icon: const Icon(Icons.search),
              isSelected: findOpen,
              tooltip: l10n.findInPageTooltip,
              onPressed: onFind,
            ),
          ),
          const SizedBox(width: 4),
          _SaveStatusChip(status: status, onSaveNow: onSaveNow),
          const SizedBox(width: 12),
          _ModeToggle(mode: mode, onChanged: onModeChanged),
        ],
      ),
    );
  }
}

/// The Edit/Preview segmented toggle.
class _ModeToggle extends StatelessWidget {
  const _ModeToggle({required this.mode, required this.onChanged});

  final _Mode mode;
  final ValueChanged<_Mode> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Semantics(
      container: true,
      label: l10n.editorModeGroupLabel,
      child: SegmentedButton<_Mode>(
        showSelectedIcon: false,
        segments: <ButtonSegment<_Mode>>[
          ButtonSegment(
            value: _Mode.edit,
            label: Text(l10n.editorModeEdit),
            icon: const Icon(Icons.edit_outlined),
          ),
          ButtonSegment(
            value: _Mode.preview,
            label: Text(l10n.editorModePreview),
            icon: const Icon(Icons.visibility_outlined),
          ),
        ],
        selected: {mode},
        onSelectionChanged: (selection) => onChanged(selection.first),
      ),
    );
  }
}

/// The save-status chip: shows `saved` / `saving` / `unsaved` / `error`, and is
/// a tappable "save now" button when there is something to write.
class _SaveStatusChip extends StatelessWidget {
  const _SaveStatusChip({required this.status, required this.onSaveNow});

  final SaveStatus status;
  final VoidCallback onSaveNow;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final (label, icon) = _describe(l10n);
    // Only dirty/error are worth a manual flush; saved is nothing to do and
    // saving is already in flight.
    final canSaveNow = status == SaveStatus.dirty || status == SaveStatus.error;
    final color = status == SaveStatus.error ? theme.colorScheme.error : null;

    return Semantics(
      button: canSaveNow,
      label: canSaveNow ? '$label, ${l10n.saveNowTooltip}' : label,
      child: Tooltip(
        message: canSaveNow ? l10n.saveNowTooltip : label,
        child: InkWell(
          onTap: canSaveNow ? onSaveNow : null,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: color),
                const SizedBox(width: 4),
                Text(label,
                    style: theme.textTheme.labelMedium?.copyWith(color: color)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  (String, IconData) _describe(AppLocalizations l10n) {
    switch (status) {
      case SaveStatus.saved:
        return (l10n.saveStatusSaved, Icons.check_circle_outline);
      case SaveStatus.saving:
        return (l10n.saveStatusSaving, Icons.sync);
      case SaveStatus.dirty:
        return (l10n.saveStatusUnsaved, Icons.edit_note_outlined);
      case SaveStatus.error:
        return (l10n.saveStatusError, Icons.error_outline);
    }
  }
}
