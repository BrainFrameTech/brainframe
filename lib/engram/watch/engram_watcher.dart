/// Noticing that something outside the app changed an engram's folder, and
/// turning that into the scan and reconciliation that already exist (the
/// filesystem watcher design, **#70**).
///
/// Pure Dart: the platform watchers are in `engram_watcher_io.dart`, and
/// everything here is tested against a fake. The watcher is a **trigger, not
/// a second reconciler** (Decision 1): it never reads a note, never touches
/// the catalog, and never decides what a change means. Its events are hints,
/// and may be lost, duplicated, reordered or coalesced without that being a
/// correctness problem — a spurious one costs a stat, and a lost one is caught
/// by the next event, the next resume, or the next open.
library;

import 'dart:async';
import 'dart:developer' as developer;

import '../engram_paths.dart';
import '../note_reconciler.dart';

/// How long a batch waits for quiet before it is dispatched: another event
/// inside this restarts the wait (Decision 3). A starting value, to be
/// measured on the Pi Zero 2 W; kept here so tuning it is one line.
const Duration watchQuietPeriod = Duration(milliseconds: 250);

/// The longest a batch is held however busy the folder is, so a steady
/// stream of events — a sync client downloading for a minute — still
/// dispatches (Decision 3). A starting value, like [watchQuietPeriod].
const Duration watchBatchCap = Duration(seconds: 2);

/// What an event says happened.
enum WatchEventKind {
  /// The content of the file at the event's path changed.
  modified,

  /// What a listing of the folder shows changed at or under the event's path:
  /// a file or directory created, deleted, or moved. Only a scan can tell a
  /// move from a deletion and a creation, so this always asks for one.
  listing,

  /// The watch lost track — an overflow, a watch that died and was
  /// re-established — so anything may have changed. Has no path.
  lost,
}

/// One hint from an [EngramWatcher].
class EngramWatchEvent {
  const EngramWatchEvent.modified(String this.path)
    : kind = WatchEventKind.modified;

  const EngramWatchEvent.listing(String this.path)
    : kind = WatchEventKind.listing;

  const EngramWatchEvent.lost() : kind = WatchEventKind.lost, path = null;

  final WatchEventKind kind;

  /// Engram-relative, forward slashes; null for [WatchEventKind.lost].
  final String? path;

  @override
  bool operator ==(Object other) =>
      other is EngramWatchEvent && other.kind == kind && other.path == path;

  @override
  int get hashCode => Object.hash(kind, path);

  @override
  String toString() => 'EngramWatchEvent.${kind.name}(${path ?? ''})';
}

/// Why an engram cannot be watched, or can no longer be (Decision 9): the
/// session carries on with the triggers it had before, and says so once.
class EngramWatchUnavailable implements Exception {
  const EngramWatchUnavailable(this.reason, {this.cause});

  /// A short, untranslated diagnostic — what the log says. What the user is
  /// told is the Housekeeping panel's to word.
  final String reason;

  /// The underlying error, when there was one.
  final Object? cause;

  @override
  String toString() =>
      'EngramWatchUnavailable: $reason${cause == null ? '' : ' ($cause)'}';
}

/// Watches one engram folder and reports what changed in it, as hints.
///
/// One per session. [start] begins watching; [events] carries the hints and,
/// if the watch dies for good, one [EngramWatchUnavailable] error before it
/// closes. Implementations may report hidden paths — the dispatcher drops
/// them — but should not spend a kernel resource watching them.
abstract class EngramWatcher {
  /// The hints, as they arrive. Broadcast.
  Stream<EngramWatchEvent> get events;

  /// Begins watching. Throws [EngramWatchUnavailable] when the folder cannot
  /// be watched at all — the platform has no watching, or a kernel limit is
  /// already reached — in which case nothing is left running.
  Future<void> start();

  /// Stops watching and releases every watch. Safe to call twice.
  Future<void> stop();
}

/// Turns an [EngramWatcher]'s hints into reconciliation (Decision 3).
///
/// Events are **batched**: a batch closes after [quietPeriod] without a new
/// one, or [batchCap] after it opened. Then, per batch:
///
/// 1. Hidden paths are dropped — every dotfile and dot-directory, the app's
///    own `.brainframe/` and its temp files included.
/// 2. A batch holding **only modifications of notes the catalog knows**
///    ([isTracked]) reconciles each of them, alone and in turn. The common
///    case — another editor saving a note — costs one stat per path. These
///    are not recorded in Housekeeping, just as the before-open reconcile is
///    not.
/// 3. Anything else — a listing change, a lost watch, a path the catalog
///    does not know — runs **one** scan, recorded under
///    [ScanTrigger.watcher]. The reconciler queues it behind a scan already
///    running rather than joining it (step 5).
///
/// Dispatches are serialized: a batch waits for the previous one's work, so
/// the reconciler never sees two batches at once. Nothing thrown by the
/// reconciler escapes — it is logged, and the next event, resume, or open
/// tries again.
class WatchDispatcher {
  WatchDispatcher({
    required this.watcher,
    required this.reconciler,
    required this.isTracked,
    this.quietPeriod = watchQuietPeriod,
    this.batchCap = watchBatchCap,
  });

  final EngramWatcher watcher;
  final NoteReconciler reconciler;

  /// Whether the catalog has a note at an engram-relative path — the test
  /// that decides whether a modification can be reconciled alone.
  final bool Function(String path) isTracked;

  final Duration quietPeriod;
  final Duration batchCap;

  StreamSubscription<EngramWatchEvent>? _subscription;
  Timer? _quiet;
  Timer? _cap;
  final Set<String> _modified = {};
  bool _needsScan = false;
  Future<void> _work = Future<void>.value();
  bool _stopped = false;

  /// Whether the watcher has died for good, and why: the session's to
  /// surface (Decision 9). Null while it is healthy.
  EngramWatchUnavailable? get failure => _failure;
  EngramWatchUnavailable? _failure;

  /// Starts the watcher and listens to it. Throws [EngramWatchUnavailable]
  /// if the watcher cannot start; nothing is left running then.
  Future<void> start() async {
    _subscription = watcher.events.listen(
      _onEvent,
      onError: _onError,
      cancelOnError: false,
    );
    try {
      await watcher.start();
    } on EngramWatchUnavailable {
      await _subscription?.cancel();
      _subscription = null;
      rethrow;
    }
  }

  /// Stops listening, drops any batch not yet dispatched, and stops the
  /// watcher. Work already dispatched is left to finish. Safe to call twice.
  Future<void> stop() async {
    if (_stopped) return;
    _stopped = true;
    _cancelTimers();
    _modified.clear();
    _needsScan = false;
    await _subscription?.cancel();
    _subscription = null;
    await watcher.stop();
  }

  /// Completes when every dispatched batch's work has finished.
  Future<void> get idle => _work;

  void _onEvent(EngramWatchEvent event) {
    if (_stopped) return;
    final path = event.path;
    switch (event.kind) {
      case WatchEventKind.lost:
        _needsScan = true;
      case WatchEventKind.listing:
        if (isHiddenEngramPath(path!)) return;
        _needsScan = true;
      case WatchEventKind.modified:
        if (isHiddenEngramPath(path!)) return;
        _modified.add(path);
    }
    _quiet?.cancel();
    _quiet = Timer(quietPeriod, _dispatch);
    _cap ??= Timer(batchCap, _dispatch);
  }

  void _onError(Object error) {
    if (_stopped) return;
    _failure = error is EngramWatchUnavailable
        ? error
        : EngramWatchUnavailable('the watch failed', cause: error);
    developer.log('watching stopped', name: watchLogName, error: _failure);
  }

  void _dispatch() {
    _cancelTimers();
    final modified = Set.of(_modified);
    final needsScan = _needsScan || modified.any((path) => !isTracked(path));
    _modified.clear();
    _needsScan = false;
    if (!needsScan && modified.isEmpty) return;
    _work = _work.then((_) => _run(modified, needsScan));
  }

  Future<void> _run(Set<String> modified, bool needsScan) async {
    if (_stopped) return;
    if (needsScan) {
      await _logFailure(
        'watcher scan failed',
        () => reconciler.scan(trigger: ScanTrigger.watcher),
      );
      return;
    }
    for (final path in modified) {
      if (_stopped) return;
      await _logFailure(
        'watcher reconcile of $path failed',
        () => reconciler.reconcile(path),
      );
    }
  }

  Future<void> _logFailure(String what, Future<Object?> Function() work) async {
    try {
      await work();
    } on Object catch (error, stack) {
      developer.log(what, name: watchLogName, error: error, stackTrace: stack);
    }
  }

  void _cancelTimers() {
    _quiet?.cancel();
    _quiet = null;
    _cap?.cancel();
    _cap = null;
  }
}

/// Logger name for watcher diagnostics (see `dart:developer`).
const String watchLogName = 'brainframe.engram.watch';
