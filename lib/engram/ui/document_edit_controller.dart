import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../commands/pending_saves.dart';
import '../crdt/catalog.dart';
import '../crdt/line_terminators.dart';
import '../note_writer.dart';
import '../text_merge.dart';

/// The save state surfaced to the header status indicator.
enum SaveStatus {
  saved,
  dirty,
  saving,
  error,

  /// The buffer is over the note's size limit and the save is withheld
  /// (the note size ceiling design, Decisions 4 and 5): nothing is written
  /// until the user rolls back to the last saved version or converts the
  /// note to a plain file. Dirty, but not saveable.
  overLimit,
}

/// Owns the edit buffer and save pipeline for the one Markdown file currently
/// open in the editor (design: "The save model").
///
/// It does not know how a save reaches storage. [writer] decides that: a
/// [DirectNoteWriter] puts the buffer on disk the way notes were always
/// written, while the CRDT writer turns it into operations on the note's
/// document and rewrites the file from the result. Everything below — the
/// debounce, the status, the path capture that stops a late write stamping the
/// wrong file — is identical either way, which is the point of the seam.
///
/// Debounced autosave is primary — after [idleDebounce] of no edits the buffer
/// is written — with a [maxWait] cap so an uninterrupted typing burst (which
/// keeps resetting the idle timer) still checkpoints at least once per cap.
/// [flush] writes immediately and is the hook for the manual save, a file
/// switch, focus loss — the editor's, and the window's — and app-lifecycle
/// pause/detach.
///
/// Two correctness rules from the design are honored here: switching files
/// flushes the outgoing file first ([openFile]), and a write captures the path
/// and text it targets so a late timer or an in-flight write can never stamp
/// content onto a file that has since been switched away.
class DocumentEditController extends ChangeNotifier
    with WidgetsBindingObserver {
  DocumentEditController({
    required this.writer,
    this.idleDebounce = const Duration(seconds: 5),
    this.maxWait = const Duration(seconds: 30),
    this.observeLifecycle = true,
    PendingSaves? pendingSaves,
  }) : _pendingSaves = pendingSaves ?? PendingSaves.instance {
    if (observeLifecycle) WidgetsBinding.instance.addObserver(this);
    // Desktop exits without a lifecycle event, so the close path asks every
    // live controller to flush rather than waiting to be told (see
    // [PendingSaves]) — and, for a buffer a flush will not write, to put the
    // decision in front of the user before anything leaves it.
    _pendingSaves.register(
      this,
      flush,
      isWithheld: () => isWithheld,
      resolve: () async => await resolveWithheld?.call() ?? false,
    );
  }

  /// Asks the user to settle a withheld buffer — the pane's wall dialog —
  /// and returns whether it is settled. Set by the pane that owns the
  /// dialog; unset, a withheld buffer cannot be settled and nothing may
  /// leave it.
  Future<bool> Function()? resolveWithheld;

  /// Whether the buffer is over the size limit and so will not be written
  /// by any flush (the note size ceiling design, Decisions 4 and 5).
  bool get isWithheld => _status == SaveStatus.overLimit;

  final NoteWriter writer;
  final Duration idleDebounce;
  final Duration maxWait;

  /// The exit-time flush registry this controller belongs to for its lifetime.
  final PendingSaves _pendingSaves;

  /// Whether this controller registers a [WidgetsBindingObserver] to flush on
  /// app pause/detach. Off in unit tests that have no binding.
  final bool observeLifecycle;

  String? _path;
  String _buffer = '';
  String _savedText = '';
  SaveStatus _status = SaveStatus.saved;
  int? _sizeLimitBytes;

  /// The largest buffer this file may be saved at, in bytes on disk, or null
  /// for no limit — a plain-file note, or an engram with no catalog to
  /// protect. Set by the pane when it opens a note. Lowering it below the
  /// buffer withholds the save; raising it, or clearing it, over a withheld
  /// buffer lets the pending edit save on the next flush.
  int? get sizeLimitBytes => _sizeLimitBytes;
  set sizeLimitBytes(int? bytes) {
    _sizeLimitBytes = bytes;
    if (_path == null) return;
    final over = _overLimit(_buffer);
    if (over && _status != SaveStatus.overLimit) {
      _cancelTimers();
      _setStatus(SaveStatus.overLimit);
    } else if (!over && _status == SaveStatus.overLimit) {
      _idleTimer = Timer(idleDebounce, _flushFromTimer);
      _maxWaitTimer ??= Timer(maxWait, _flushFromTimer);
      _setStatus(SaveStatus.dirty);
    }
  }

  bool _overLimit(String text) {
    final limit = _sizeLimitBytes;
    return limit != null && noteSizeInBytes(text) > limit;
  }

  Timer? _idleTimer;
  Timer? _maxWaitTimer;
  Future<void>? _writing;

  /// The engram-relative path of the open file, or null before one is opened.
  String? get path => _path;

  /// The live edit buffer.
  String get text => _buffer;

  /// The current save state for the status indicator.
  SaveStatus get status => _status;

  /// Whether the buffer differs from what is on disk.
  bool get isDirty => _buffer != _savedText;

  /// Opens [path] with [initialText] as its on-disk content, adopting it clean.
  ///
  /// If a different file is open, its buffer is flushed first (correctness rule
  /// 1) so switching never strands edits. Re-opening the already-open path is a
  /// no-op, so the live buffer is never clobbered.
  Future<void> openFile(String path, String initialText) async {
    if (_path == path) return;
    if (_path != null) await flush();
    _cancelTimers();
    _path = path;
    _buffer = initialText;
    _savedText = initialText;
    _setStatus(SaveStatus.saved);
  }

  /// Takes in the open file's content from disk, as [read] returns it, after
  /// the file *under the open path* was rewritten — reconciliation took in an
  /// edit made outside the app — so the buffer no longer knows what is on
  /// disk (the filesystem watcher design, Decision 7).
  ///
  /// - **A clean buffer** adopts the file: it becomes the buffer and the saved
  ///   text alike.
  /// - **A dirty buffer** is merged with it, three ways, from the text the
  ///   buffer grew from ([threeWayMerge]). Nothing typed is dropped, and
  ///   nothing the file gained is either. The file becomes the saved text and
  ///   the buffer stays dirty, so the ordinary debounce saves the merge —
  ///   unless the merge is over the size limit, when it is withheld like any
  ///   buffer that is.
  ///
  /// [read] is called here, not by the caller, and only once no write is in
  /// flight: a file read before a save of ours lands is older than the saved
  /// text, and merging it would undo that save. If a new write starts while
  /// reading, it is awaited and the file read again. A file that says what the
  /// saved text says — which is what a notification of our own save reads —
  /// changes nothing, so a duplicate notification is harmless. A no-op before
  /// a file is opened, and if the file is switched away from meanwhile.
  Future<void> mergeFromDisk(Future<String> Function() read) async {
    final path = _path;
    if (path == null) return;
    String text;
    do {
      final inFlight = _writing;
      if (inFlight != null) await inFlight;
      text = await read();
      if (_path != path) return;
    } while (_writing != null);

    if (!isDirty) {
      _cancelTimers();
      _buffer = text;
      _savedText = text;
      _status = SaveStatus.saved;
      // Always, not only on a status change: the buffer changed even when
      // the status did not, and the pane puts it into the field.
      notifyListeners();
      return;
    }
    if (normalizeTerminators(text) == normalizeTerminators(_savedText)) return;
    _buffer = threeWayMerge(base: _savedText, mine: _buffer, theirs: text);
    _savedText = text;
    if (_overLimit(_buffer)) {
      _cancelTimers();
      _status = SaveStatus.overLimit;
    } else if (isDirty) {
      _idleTimer?.cancel();
      _idleTimer = Timer(idleDebounce, _flushFromTimer);
      _maxWaitTimer ??= Timer(maxWait, _flushFromTimer);
      _status = SaveStatus.dirty;
    } else {
      _cancelTimers();
      _status = SaveStatus.saved;
    }
    notifyListeners();
  }

  /// Discards the buffer in favour of the last saved text — the way back
  /// from over the limit that keeps the note's history (the note size
  /// ceiling design, Decision 4). Clean afterwards. A no-op before a file
  /// is open.
  void rollBack() {
    if (_path == null) return;
    _cancelTimers();
    _buffer = _savedText;
    // Always, not only on a transition: the buffer changed, and the pane
    // puts it back into the field on notification.
    _status = SaveStatus.saved;
    notifyListeners();
  }

  /// Records an edit to the open file: updates the buffer, (re)arms the idle
  /// debounce, and ensures the max-wait cap is ticking. Editing back to the
  /// saved content cancels the pending write and returns to `saved`.
  void edit(String text) {
    if (_path == null) return;
    _buffer = text;
    final before = _status;
    if (_overLimit(text)) {
      // Typing past the limit is allowed — the app never fights the
      // keyboard — but the save is withheld, and the timers that would
      // make one are stopped. The way out is rollBack, or a conversion
      // that clears the limit.
      _cancelTimers();
      _setStatus(SaveStatus.overLimit);
    } else if (isDirty) {
      _idleTimer?.cancel();
      _idleTimer = Timer(idleDebounce, _flushFromTimer);
      _maxWaitTimer ??= Timer(maxWait, _flushFromTimer);
      _setStatus(SaveStatus.dirty);
    } else {
      _cancelTimers();
      _setStatus(SaveStatus.saved);
    }
    // Every edit, not only a status change: the status bar counts the
    // buffer, and a run of typing that stays dirty throughout would
    // otherwise never reach it. Once per edit — a transition has already
    // notified. The bar coalesces its own counting.
    if (_status == before) notifyListeners();
  }

  /// Writes the buffer through [writer] now if it is dirty, cancelling pending
  /// timers. Safe to call when clean (a no-op) and to await from any flush
  /// point. Writes are serialized per controller so the writer never sees two
  /// concurrent writes to the same file — which the CRDT writer relies on more
  /// heavily than the direct one, since it opens the note's document to apply
  /// the buffer and two overlapping opens would race on one op-log.
  Future<void> flush() async {
    _cancelTimers();
    final inFlight = _writing;
    if (inFlight != null) await inFlight;
    if (!isDirty || _path == null) return;
    // Withheld: over the limit there is nothing that may be written. The
    // buffer stays as the user left it, for them to roll back or convert.
    if (_status == SaveStatus.overLimit) return;

    final targetPath = _path!;
    final pending = _buffer;
    // What the buffer grew from: the writer merges with a file that has moved
    // on since, rather than writing over it (the filesystem watcher design,
    // Decision 5).
    final base = _savedText;
    _setStatus(SaveStatus.saving);
    final op = _write(targetPath, pending, base);
    _writing = op;
    await op;
  }

  Future<void> _write(String targetPath, String pending, String base) async {
    try {
      final saved = await writer.write(targetPath, pending, base: base);
      // Only settle state if we are still on the file we wrote — a switch
      // during the write leaves the new file's state alone.
      if (_path == targetPath) {
        _adoptSaved(pending, saved);
        _setStatus(isDirty ? SaveStatus.dirty : SaveStatus.saved);
      }
    } on NoteMergeOverLimitException catch (e) {
      // The file had changed underneath and the merge came out too large to
      // save. The external edit is safe — it is what the note holds — and the
      // merge becomes the buffer, withheld as though it had been typed.
      if (_path == targetPath) {
        _adoptSaved(pending, e.merged, onDisk: e.onDisk);
        _cancelTimers();
        _setStatus(
          _overLimit(_buffer) ? SaveStatus.overLimit : SaveStatus.error,
        );
      }
    } catch (_) {
      if (_path == targetPath) {
        _setStatus(SaveStatus.error); // buffer stays dirty for retry
      }
    } finally {
      _writing = null;
    }
  }

  /// Settles the buffer after a write of [pending] came back as [result] — the
  /// note's text, [onDisk] unless given separately.
  ///
  /// [result] is [pending] unless the writer merged with a change it found on
  /// disk. The buffer then takes the merge, keeping anything typed while the
  /// write was in flight by merging that too; the field is rebuilt from it on
  /// the notification that follows.
  void _adoptSaved(String pending, String result, {String? onDisk}) {
    _savedText = onDisk ?? result;
    if (result == pending) return;
    _buffer = _buffer == pending
        ? result
        : threeWayMerge(base: pending, mine: _buffer, theirs: result);
    notifyListeners();
  }

  void _flushFromTimer() {
    // Don't null the timer fields here: flush() cancels *both* timers, so the
    // sibling timer (e.g. max-wait when the idle timer fired) is stopped rather
    // than leaking a second, spurious write.
    unawaited(flush());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Leaving or backgrounding must never strand edits — and neither must
    // losing the window. On desktop, switching to another window sends
    // `inactive` and nothing else, so without it here a keystroke sits in
    // the debounce while whatever took focus reads the folder: a second
    // BrainFrame over the same engram scans on its own resume, immediately,
    // and finds the file from before the edit. `inactive` is also cheap
    // everywhere it fires for other reasons (a system prompt, an incoming
    // call): flushing a dirty buffer early is what the timer would have done
    // a few seconds later. `resumed` is left alone; there is nothing to save
    // on the way back in.
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(flush());
    }
  }

  void _setStatus(SaveStatus status) {
    if (_status == status) return;
    _status = status;
    notifyListeners();
  }

  void _cancelTimers() {
    _idleTimer?.cancel();
    _idleTimer = null;
    _maxWaitTimer?.cancel();
    _maxWaitTimer = null;
  }

  @override
  void dispose() {
    _cancelTimers();
    _pendingSaves.unregister(this);
    if (observeLifecycle) WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
