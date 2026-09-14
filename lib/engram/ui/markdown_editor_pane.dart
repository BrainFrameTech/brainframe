import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../commands/app_commands.dart';
import '../../commands/pending_saves.dart';
import '../../l10n/gen/app_localizations.dart';
import '../crdt/catalog.dart';
import '../metadata.dart';
import '../engram_store.dart';
import '../note_reconciler.dart';
import '../note_writer.dart';
import 'document_edit_controller.dart';
import 'file_path_breadcrumb.dart';
import 'find_in_page.dart';
import 'markdown_reader.dart';
import 'markdown_source_editor.dart';
import 'note_status_bar.dart';

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
///
/// It is also where the third of the scan's triggers lives (Decision 6): a
/// note is reconciled immediately before it is opened, so what the editor
/// reads already includes any edit made to the file outside the app. And it
/// listens for the other two — a note reconciled *while open*, by the resume
/// scan — and reloads, because a buffer that no longer matches the file would
/// otherwise save over the merged edit.
class MarkdownEditorPane extends StatefulWidget {
  const MarkdownEditorPane({
    super.key,
    required this.store,
    required this.path,
    this.writer,
    this.reconciler,
    this.availablePaths = const {},
    this.onNavigateToFile,
    this.noteSizeCeilingBytes = defaultNoteSizeCeilingBytes,
    this.pendingSaves,
  });

  /// The registry the controller reports unwritten and withheld work to.
  /// Null means the app-wide one; a test injects its own.
  final PendingSaves? pendingSaves;

  final EngramStore store;
  final String path;

  /// The engram's note size ceiling, in bytes on disk, for the status bar's
  /// warning (the note size ceiling design, Decisions 5 and 7).
  final int noteSizeCeilingBytes;

  /// How a save reaches storage, or null to write straight to [store].
  ///
  /// Supplied by the browser when the engram has an op-log behind it. Null is
  /// the honest default rather than a degraded one: a read-only engram, and a
  /// platform with no SQLite, both write directly and always will.
  final NoteWriter? writer;

  /// How to reconcile a file that changed outside the app, or null when
  /// nothing can have: no op-log, so nothing to drift from.
  final NoteReconciler? reconciler;
  final Set<String> availablePaths;
  final void Function(String path)? onNavigateToFile;

  @override
  State<MarkdownEditorPane> createState() => _MarkdownEditorPaneState();
}

class _MarkdownEditorPaneState extends State<MarkdownEditorPane> {
  late final DocumentEditController _controller = DocumentEditController(
    writer: widget.writer ?? DirectNoteWriter(widget.store),
    pendingSaves: widget.pendingSaves,
  );
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

  /// The note grew past the size limit outside the app and is awaiting the
  /// user's decision in Housekeeping (the note size ceiling design,
  /// Decision 4): shown read-only, with no editor and nothing to save.
  bool _awaitingDecision = false;

  /// The note is a plain file — no history, whole-file saves — and the
  /// status bar says so in the slot the size warning would take.
  bool _plainFile = false;

  /// The text of a note awaiting a decision, for the status bar's counts;
  /// the controller never holds it (there must be no buffer a save could
  /// reach), and the reader reads the file for itself.
  String _awaitingText = '';

  /// A paste that would have taken the note past the limit, taken back out
  /// of the field and held here until the user says undo or convert.
  String? _pendingPaste;

  StreamSubscription<String>? _reconciled;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onControllerChanged);
    _focusNode.addListener(_onFocusChanged);
    _reconciled = widget.reconciler?.reconciled.listen(_onReconciled);
    // Anything that would leave this note — closing the window, selecting
    // another file, switching engrams — asks the registry first, and the
    // registry asks here: the wall's own dialog, and whether it settled.
    _controller.resolveWithheld = _resolveWall;
    _open(widget.path);
  }

  /// A file that changed on disk while the buffer was over the limit: the
  /// reload is held back rather than dropping the buffer, and applied once
  /// the user rolls back — which is the moment the file is what they want.
  bool _reloadDeferred = false;

  Future<bool> _resolveWall() async {
    if (!_controller.isWithheld) return true;
    if (!mounted) return false;
    await _askAboutWall();
    return !_controller.isWithheld;
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
    if (widget.reconciler != oldWidget.reconciler) {
      _reconciled?.cancel();
      _reconciled = widget.reconciler?.reconciled.listen(_onReconciled);
    }
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
      // Reconcile before reading, so the text the editor adopts is the note's
      // history and not a file that got ahead of it. The controller's current
      // file is a different path (or this one, already open, which openFile
      // ignores), so there is no buffer over this note to flush first.
      await widget.reconciler?.reconcile(path);
      // The reconciliation just ran may have found the note over the
      // ceiling, or it may have been waiting since an earlier scan; either
      // way it is read-only until the user decides, and the controller
      // never sees it — there must be no buffer a save could reach.
      final awaiting = await _isAwaitingDecision(path);
      final plainFile =
          !awaiting && (await widget.reconciler?.isPlainFile(path) ?? false);
      var awaitingText = '';
      if (awaiting) {
        awaitingText = await widget.store.readString(path);
      } else {
        final text = await widget.store.readString(path);
        // The limit before the text, so a file already over it (which the
        // scan should have caught first) is withheld from the outset. No
        // limit for a plain file, or where there is no catalog to protect.
        _controller.sizeLimitBytes = plainFile || widget.reconciler == null
            ? null
            : widget.noteSizeCeilingBytes;
        await _controller.openFile(path, text);
      }
      if (!mounted || widget.path != path) return;
      setState(() {
        _awaitingDecision = awaiting;
        _awaitingText = awaitingText;
        _pendingPaste = null;
        _plainFile = plainFile;
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

  Future<bool> _isAwaitingDecision(String path) async {
    final reconciler = widget.reconciler;
    if (reconciler == null) return false;
    for (final note in await reconciler.awaitingDecision()) {
      if (note.path == path) return true;
    }
    return false;
  }

  Future<void> _explainNearLimit() async {
    final l10n = AppLocalizations.of(context);
    await showAdaptiveDialog<void>(
      context: context,
      builder: (context) => AlertDialog.adaptive(
        title: Text(l10n.nearLimitTitle),
        content: Text(
          l10n.nearLimitBody(
            formatDecimal(context, NoteCounts.of(_controller.text).bytes),
            formatDecimal(context, widget.noteSizeCeilingBytes),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.ok),
          ),
        ],
      ),
    );
  }

  void _onControllerChanged() {
    if (mounted) setState(() {}); // refresh the save-status chip
  }

  /// A note was reconciled somewhere. If it is the one on screen, its file no
  /// longer matches the buffer, and the buffer has to yield.
  void _onReconciled(String path) {
    // Only a note that has finished loading: one mid-open reads the
    // reconciled file anyway, and one that has moved on is not ours.
    if (path != widget.path || _loadedPath != path) return;
    // A note that was awaiting a decision has just been reconstructed: it
    // is editable again, and the controller never loaded it, so this is an
    // open rather than a reload.
    if (_awaitingDecision) {
      unawaited(_open(path));
      return;
    }
    // Over the limit the buffer is the only copy of what the user typed;
    // a reload would replace it with the file. Held back until they roll
    // back, when the file is exactly what they asked for.
    if (_controller.isWithheld) {
      _reloadDeferred = true;
      return;
    }
    unawaited(_reload(path));
  }

  Future<void> _reload(String path) async {
    try {
      final text = await widget.store.readString(path);
      if (!mounted || widget.path != path) return;
      await _controller.replaceFromDisk(text);
      if (!mounted || widget.path != path) return;
      // Matches were found in text that no longer exists.
      if (_findOpen) setState(() => _search(_findQuery.text));
    } catch (error) {
      if (!mounted || widget.path != path) return;
      setState(() => _loadError = error);
    }
  }

  void _onFocusChanged() {
    if (!_focusNode.hasFocus) _controller.flush(); // focus-loss flush point
  }

  /// Records an edit, and keeps the find highlights honest while the user types
  /// into a document that is being searched.
  void _onEdit(String text) {
    final limit = _controller.sizeLimitBytes;
    if (limit != null &&
        noteSizeInBytes(text) > limit &&
        noteSizeInBytes(_controller.text) <= limit &&
        text.length - _controller.text.length > 1) {
      // More than one character arrived at once and crossed the line: a
      // paste. Refused at the paste, before it is the buffer — the field
      // goes back to what it was, and the dialog offers to undo (done) or
      // convert (the paste is then applied). Typing crosses one character
      // at a time and is let through to the withheld-save path instead.
      _pendingPaste = text;
      _editor.replaceText(_controller.text);
      unawaited(_askAboutPaste());
      return;
    }
    _controller.edit(text);
    if (_findOpen) setState(() => _search(_findQuery.text));
  }

  Future<void> _askAboutPaste() async {
    final pending = _pendingPaste;
    if (pending == null) return;
    final l10n = AppLocalizations.of(context);
    final convert = await showAdaptiveDialog<bool>(
      context: context,
      builder: (context) => AlertDialog.adaptive(
        title: Text(l10n.wallTitle),
        content: Text(
          l10n.wallBodyPaste(
            formatDecimal(context, noteSizeInBytes(pending)),
            formatDecimal(context, widget.noteSizeCeilingBytes),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.wallUndoPaste),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.housekeepingConvert),
          ),
        ],
      ),
    );
    if (!mounted) return;
    _pendingPaste = null;
    if (convert != true) return; // undone already: the field was put back
    await _convert();
    if (!mounted) return;
    _editor.replaceText(pending);
    _controller.edit(pending);
    await _controller.flush();
  }

  /// The wall, reached by typing: roll back to the last saved version, or
  /// convert and let the withheld save through.
  Future<void> _askAboutWall() async {
    final l10n = AppLocalizations.of(context);
    final choice = await showAdaptiveDialog<_WallChoice>(
      context: context,
      builder: (context) => AlertDialog.adaptive(
        title: Text(l10n.wallTitle),
        content: Text(
          l10n.wallBodyTyping(
            formatDecimal(context, noteSizeInBytes(_controller.text)),
            formatDecimal(context, widget.noteSizeCeilingBytes),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(_WallChoice.rollBack),
            child: Text(l10n.wallRollBack),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(_WallChoice.convert),
            child: Text(l10n.housekeepingConvert),
          ),
        ],
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case null:
        return;
      case _WallChoice.rollBack:
        _controller.rollBack();
        _editor.replaceText(_controller.text);
        if (_reloadDeferred) {
          _reloadDeferred = false;
          await _reload(widget.path);
        }
      case _WallChoice.convert:
        await _convert();
        if (!mounted) return;
        // Clearing the limit turns the withheld save back into a pending
        // one; flushing writes it, through the plain-file writer now.
        await _controller.flush();
      case _WallChoice.reconstruct:
        break; // not offered here
    }
  }

  /// The external-edit door (step 20) on the same surface: reconstruct or
  /// convert a note that grew past the limit outside the app.
  Future<void> _askAboutExternal() async {
    final l10n = AppLocalizations.of(context);
    final choice = await showAdaptiveDialog<_WallChoice>(
      context: context,
      builder: (context) => AlertDialog.adaptive(
        title: Text(l10n.wallTitle),
        content: Text(
          l10n.wallBodyExternal(
            formatDecimal(context, noteSizeInBytes(_awaitingText)),
            formatDecimal(context, widget.noteSizeCeilingBytes),
            asidePathFor(widget.path).split('/').last,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(_WallChoice.reconstruct),
            child: Text(l10n.housekeepingReconstruct),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(_WallChoice.convert),
            child: Text(l10n.housekeepingConvert),
          ),
        ],
      ),
    );
    if (!mounted) return;
    final path = widget.path;
    switch (choice) {
      case null:
        return;
      case _WallChoice.reconstruct:
        // The reconciler says so on its stream, and _onReconciled reopens.
        await widget.reconciler?.reconstruct(path);
      case _WallChoice.convert:
        await widget.reconciler?.convertToPlainFile(path);
        if (!mounted || widget.path != path) return;
        await _open(path);
      case _WallChoice.rollBack:
        break; // not offered here
    }
  }

  /// Converts the open note to a plain file (step 19) and lifts the limit:
  /// from here its saves go through the plain-file writer.
  Future<void> _convert() async {
    await widget.reconciler?.convertToPlainFile(widget.path);
    if (!mounted) return;
    _controller.sizeLimitBytes = null;
    setState(() => _plainFile = true);
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
    _reconciled?.cancel();
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
        child: Text(
          l10n.readerOpenError(widget.path),
          textAlign: TextAlign.center,
        ),
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
    if (_awaitingDecision) {
      // Read-only, and plainly so: the reader over the file, under a line
      // that says why and where the decision is made. No header — there is
      // no mode to toggle and nothing to save. Step 22 puts the decision's
      // two verbs on the status bar; until then, Housekeeping has them.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Semantics(
            liveRegion: true,
            child: Container(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              color: Theme.of(context).colorScheme.tertiaryContainer,
              child: Text(
                l10n.editorAwaitingDecision,
                style: TextStyle(
                  fontSize: 13,
                  color: Theme.of(context).colorScheme.onTertiaryContainer,
                ),
              ),
            ),
          ),
          Expanded(
            child: MarkdownReader(
              store: widget.store,
              path: widget.path,
              availablePaths: widget.availablePaths,
              onNavigateToFile: widget.onNavigateToFile,
            ),
          ),
          NoteStatusBar(
            text: _awaitingText,
            ceilingBytes: widget.noteSizeCeilingBytes,
            onWallPressed: _askAboutExternal,
          ),
        ],
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
            onOverLimit: _askAboutWall,
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
          NoteStatusBar(
            text: _controller.text,
            ceilingBytes: widget.noteSizeCeilingBytes,
            plainFile: _plainFile,
            onWarningPressed: _explainNearLimit,
            onWallPressed: _askAboutWall,
          ),
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
    required this.onOverLimit,
    required this.onFind,
  });

  final String path;
  final _Mode mode;
  final SaveStatus status;
  final bool findOpen;
  final ValueChanged<_Mode> onModeChanged;
  final VoidCallback onSaveNow;

  /// Opens the wall — the choices — when the buffer is over the limit.
  final VoidCallback onOverLimit;
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
          _SaveStatusChip(
            status: status,
            onSaveNow: onSaveNow,
            onOverLimit: onOverLimit,
          ),
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
  const _SaveStatusChip({
    required this.status,
    required this.onSaveNow,
    required this.onOverLimit,
  });

  final SaveStatus status;
  final VoidCallback onSaveNow;

  /// Over the limit the chip is a button too, but to the decision rather
  /// than to a save there cannot be.
  final VoidCallback onOverLimit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final theme = Theme.of(context);
    final (label, icon) = _describe(l10n);
    // Only dirty/error are worth a manual flush; saved is nothing to do and
    // saving is already in flight.
    final canSaveNow = status == SaveStatus.dirty || status == SaveStatus.error;
    final overLimit = status == SaveStatus.overLimit;
    final color = status == SaveStatus.error || overLimit
        ? theme.colorScheme.error
        : null;

    return Semantics(
      button: canSaveNow || overLimit,
      label: canSaveNow ? '$label, ${l10n.saveNowTooltip}' : label,
      child: Tooltip(
        message: canSaveNow ? l10n.saveNowTooltip : label,
        child: InkWell(
          onTap: canSaveNow
              ? onSaveNow
              : overLimit
              ? onOverLimit
              : null,
          borderRadius: BorderRadius.circular(16),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: color),
                const SizedBox(width: 4),
                Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(color: color),
                ),
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
      case SaveStatus.overLimit:
        return (l10n.saveStatusOverLimit, Icons.block);
    }
  }
}

/// What the wall's dialogs come back with.
enum _WallChoice { rollBack, convert, reconstruct }
