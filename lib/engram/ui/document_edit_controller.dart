import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../commands/pending_saves.dart';
import '../note_writer.dart';

/// The save state surfaced to the header status indicator.
enum SaveStatus { saved, dirty, saving, error }

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
/// switch, focus loss, and app-lifecycle pause/detach.
///
/// Two correctness rules from the design are honored here: switching files
/// flushes the outgoing file first ([openFile]), and a write captures the path
/// and text it targets so a late timer or an in-flight write can never stamp
/// content onto a file that has since been switched away.
class DocumentEditController extends ChangeNotifier with WidgetsBindingObserver {
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
    // [PendingSaves]).
    _pendingSaves.register(this, flush);
  }

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

  /// Adopts [text] as the open file's on-disk content, discarding the buffer.
  ///
  /// For the one case [openFile] cannot cover: the file *under the open path*
  /// was rewritten — reconciliation merged an edit made outside the app — so
  /// the buffer no longer knows what is on disk, and the next save would diff
  /// against a history that has moved on and delete the merged edit as though
  /// the user had removed it. Reloading is what keeps a whole-buffer save
  /// honest; a CRDT-aware editor (#85) is what eventually makes it unnecessary.
  ///
  /// A write already in flight is awaited first, so its completion cannot
  /// settle stale state over the reload. Any keystrokes made between the
  /// pre-scan flush and this call are dropped: that window is the length of
  /// one note's reconciliation, and the alternative — saving them — would
  /// discard the external edit instead. A no-op before a file is opened.
  Future<void> replaceFromDisk(String text) async {
    if (_path == null) return;
    final inFlight = _writing;
    if (inFlight != null) await inFlight;
    _cancelTimers();
    _buffer = text;
    _savedText = text;
    _status = SaveStatus.saved;
    // Always, not only on a status change: the buffer changed even when the
    // status did not, and the pane rebuilds the source field from the buffer.
    notifyListeners();
  }

  /// Records an edit to the open file: updates the buffer, (re)arms the idle
  /// debounce, and ensures the max-wait cap is ticking. Editing back to the
  /// saved content cancels the pending write and returns to `saved`.
  void edit(String text) {
    if (_path == null) return;
    _buffer = text;
    if (isDirty) {
      _idleTimer?.cancel();
      _idleTimer = Timer(idleDebounce, _flushFromTimer);
      _maxWaitTimer ??= Timer(maxWait, _flushFromTimer);
      _setStatus(SaveStatus.dirty);
    } else {
      _cancelTimers();
      _setStatus(SaveStatus.saved);
    }
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

    final targetPath = _path!;
    final pending = _buffer;
    _setStatus(SaveStatus.saving);
    final op = _write(targetPath, pending);
    _writing = op;
    await op;
  }

  Future<void> _write(String targetPath, String pending) async {
    try {
      await writer.write(targetPath, pending);
      // Only settle state if we are still on the file we wrote — a switch
      // during the write leaves the new file's state alone.
      if (_path == targetPath) {
        _savedText = pending;
        _setStatus(isDirty ? SaveStatus.dirty : SaveStatus.saved);
      }
    } catch (_) {
      if (_path == targetPath) {
        _setStatus(SaveStatus.error); // buffer stays dirty for retry
      }
    } finally {
      _writing = null;
    }
  }

  void _flushFromTimer() {
    // Don't null the timer fields here: flush() cancels *both* timers, so the
    // sibling timer (e.g. max-wait when the idle timer fired) is stopped rather
    // than leaking a second, spurious write.
    unawaited(flush());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Leaving or backgrounding must never strand edits.
    if (state == AppLifecycleState.paused ||
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
