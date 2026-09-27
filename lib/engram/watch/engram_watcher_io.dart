/// The platform watchers behind [EngramWatcher] (the filesystem watcher
/// design, Decision 2): a thin layer over `dart:io`'s own watching, not
/// `package:watcher`.
///
/// Why not the package: its Linux watcher places a watch on **every**
/// directory under the root and cannot be told to skip any — an engram that
/// is also a Git checkout has 256 directories under `.git/objects` alone,
/// each counted against a kernel limit that is lowest on the 512 MB board —
/// and on Android it polls the whole tree every second although inotify is
/// there. Decision 1 lets this layer be imprecise, which is what keeps it
/// small: an event is a hint, and a scan follows anything doubtful.
library;

import 'dart:async';
import 'dart:io';

import '../engram_paths.dart';
import 'engram_watcher.dart';

/// The watcher for this platform over the engram folder at [root], or null
/// where the platform has no watching — then the scan's other triggers are
/// all there is (Decision 9).
///
/// iOS answers null deliberately: `dart:io` is not expected to watch there,
/// and on an iPhone the Files app is in front only while BrainFrame is not,
/// so the resume scan already covers the realistic case. To be confirmed on a
/// device before anything is built on the answer.
EngramWatcher? engramWatcherFor(String root) {
  if (!FileSystemEntity.isWatchSupported) return null;
  if (Platform.isLinux || Platform.isAndroid) return DirectoryTreeWatcher(root);
  if (Platform.isMacOS || Platform.isWindows) return RecursiveWatcher(root);
  return null;
}

/// One non-recursive watch per **visible** directory — inotify's shape, for
/// Linux, the Pi, and Android.
///
/// Hidden directories are never entered, so a `.git` or an `.obsidian` costs
/// no watch at all. The tree is followed as it changes: a directory created
/// is watched (and whatever it already holds), one deleted or moved away
/// stops being watched. A file created in a new directory before its watch
/// is placed is still found, because the directory's own creation is a
/// listing change and the scan that follows lists it.
///
/// A watch that cannot be placed — the per-user inotify limit, reported as
/// "No space left on device" — ends the watcher: [events] carries one
/// [EngramWatchUnavailable] and every watch is released, rather than
/// watching part of the folder and silently missing the rest.
class DirectoryTreeWatcher implements EngramWatcher {
  DirectoryTreeWatcher(
    this.root, {
    Stream<FileSystemEvent> Function(Directory directory)? watchDirectory,
  }) : _watchDirectory = watchDirectory ?? _nativeWatch;

  /// The engram folder, absolute.
  final String root;

  final Stream<FileSystemEvent> Function(Directory directory) _watchDirectory;

  static Stream<FileSystemEvent> _nativeWatch(Directory directory) =>
      directory.watch();

  final StreamController<EngramWatchEvent> _events =
      StreamController<EngramWatchEvent>.broadcast();

  /// Every watch, by engram-relative directory path; the root is `''`.
  final Map<String, StreamSubscription<FileSystemEvent>> _watches = {};

  bool _running = false;

  /// How many directories are watched now: what the kernel is being asked
  /// for, and what a test can count.
  int get watchCount => _watches.length;

  @override
  Stream<EngramWatchEvent> get events => _events.stream;

  @override
  Future<void> start() async {
    if (_running) return;
    _running = true;
    try {
      await _watchTree('');
    } on FileSystemException catch (error) {
      await _release();
      throw EngramWatchUnavailable(
        'could not watch $root',
        cause: error,
        kind: watchUnavailableKindOf(error),
      );
    }
  }

  @override
  Future<void> stop() async {
    _running = false;
    await _release();
  }

  /// Watches the directory at [relative] and every visible directory under
  /// it, walking one level at a time so a hidden directory is never listed,
  /// let alone watched.
  Future<void> _watchTree(String relative) async {
    if (!_running) return;
    _watchOne(relative);
    final directory = Directory(_absolute(relative));
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final child = _relative(entity.path);
      if (!isHiddenEngramPath(child)) await _watchTree(child);
    }
  }

  void _watchOne(String relative) {
    if (_watches.containsKey(relative)) return;
    _watches[relative] = _watchDirectory(
      Directory(_absolute(relative)),
    ).listen(_onEvent, onError: _fail, onDone: () => _onDone(relative));
  }

  void _onEvent(FileSystemEvent event) {
    if (!_running) return;
    final path = _relative(event.path);
    if (path.isEmpty) return; // the root itself: its end is [_onDone]'s
    if (event is FileSystemModifyEvent) {
      // A directory's own modification is its listing changing, which the
      // create/delete events inside it already say.
      if (!event.isDirectory) _events.add(EngramWatchEvent.modified(path));
      return;
    }
    _events.add(EngramWatchEvent.listing(path));
    if (event is FileSystemDeleteEvent) {
      // A deletion cannot say whether it was a directory — the SDK reports
      // every one as a file, since what is gone cannot be looked at — so any
      // deleted path drops the watches under it. Nothing, for a file.
      _unwatchUnder(path);
      return;
    }
    if (!event.isDirectory) {
      if (event is FileSystemMoveEvent && event.destination != null) {
        _events.add(EngramWatchEvent.listing(_relative(event.destination!)));
      }
      return;
    }
    switch (event) {
      case FileSystemCreateEvent():
        _follow(path);
      case FileSystemMoveEvent(:final destination):
        _unwatchUnder(path);
        if (destination != null) {
          final to = _relative(destination);
          _events.add(EngramWatchEvent.listing(to));
          _follow(to);
        }
      default:
        break;
    }
  }

  /// Starts watching a directory that has just appeared.
  void _follow(String relative) {
    if (isHiddenEngramPath(relative)) return;
    unawaited(
      _watchTree(relative).catchError((Object error) {
        // Gone again before it could be listed: its deletion is its own
        // event. Anything else is a watch that could not be placed.
        if (error is FileSystemException &&
            !Directory(_absolute(relative)).existsSync()) {
          return;
        }
        _fail(error);
      }),
    );
  }

  void _unwatchUnder(String relative) {
    final gone = [
      for (final key in _watches.keys)
        if (key == relative || key.startsWith('$relative/')) key,
    ];
    for (final key in gone) {
      unawaited(_watches.remove(key)!.cancel());
    }
  }

  void _onDone(String relative) {
    // A watch ends when its directory does. For the root that is the engram
    // itself gone — nothing left to watch.
    _watches.remove(relative);
    if (_running && relative.isEmpty) {
      _fail(const FileSystemException('the engram folder is gone'));
    }
  }

  void _fail(Object error) {
    if (!_running) return;
    _running = false;
    unawaited(_release());
    _events.addError(
      error is EngramWatchUnavailable
          ? error
          : EngramWatchUnavailable(
              'watching $root failed',
              cause: error,
              kind: watchUnavailableKindOf(error),
            ),
    );
  }

  Future<void> _release() async {
    final watches = _watches.values.toList();
    _watches.clear();
    for (final watch in watches) {
      await watch.cancel();
    }
  }

  String _absolute(String relative) =>
      relative.isEmpty ? root : '$root/$relative';

  String _relative(String absolute) => relativeToRoot(root, absolute);
}

/// One recursive watch on the root — FSEvents on macOS,
/// `ReadDirectoryChangesW` on Windows — with hidden paths left for the
/// dispatcher to drop.
///
/// A watch that errors or ends while the root is still there — a Windows
/// buffer overflow is the ordinary case — is re-established, and a
/// [WatchEventKind.lost] event asks for the scan that covers whatever was
/// missed meanwhile. More than [maxRestarts] in a row without an event
/// between them is a watch that cannot be kept, and ends the watcher with an
/// [EngramWatchUnavailable].
class RecursiveWatcher implements EngramWatcher {
  RecursiveWatcher(
    this.root, {
    Stream<FileSystemEvent> Function()? watchRoot,
    this.maxRestarts = 3,
  }) : _watchRoot = watchRoot ?? (() => Directory(root).watch(recursive: true));

  /// The engram folder, absolute.
  final String root;

  /// Consecutive restarts allowed before the watch is given up on.
  final int maxRestarts;

  final Stream<FileSystemEvent> Function() _watchRoot;

  final StreamController<EngramWatchEvent> _events =
      StreamController<EngramWatchEvent>.broadcast();

  StreamSubscription<FileSystemEvent>? _watch;
  bool _running = false;
  int _restarts = 0;

  @override
  Stream<EngramWatchEvent> get events => _events.stream;

  @override
  Future<void> start() async {
    if (_running) return;
    _running = true;
    _restarts = 0;
    _listen();
  }

  @override
  Future<void> stop() async {
    _running = false;
    await _watch?.cancel();
    _watch = null;
  }

  void _listen() {
    _watch = _watchRoot().listen(
      _onEvent,
      onError: (Object error) => _restart(error),
      onDone: () => _restart(null),
    );
  }

  void _onEvent(FileSystemEvent event) {
    if (!_running) return;
    _restarts = 0;
    final path = _relative(event.path);
    if (path.isEmpty) return;
    if (event is FileSystemModifyEvent) {
      if (!event.isDirectory) _events.add(EngramWatchEvent.modified(path));
      return;
    }
    _events.add(EngramWatchEvent.listing(path));
    if (event is FileSystemMoveEvent && event.destination != null) {
      _events.add(EngramWatchEvent.listing(_relative(event.destination!)));
    }
  }

  void _restart(Object? error) {
    if (!_running) return;
    unawaited(_watch?.cancel());
    _watch = null;
    if (_restarts >= maxRestarts || !Directory(root).existsSync()) {
      _running = false;
      _events.addError(
        EngramWatchUnavailable(
          'watching $root failed',
          cause: error ?? const FileSystemException('the watch ended'),
        ),
      );
      return;
    }
    _restarts++;
    _events.add(const EngramWatchEvent.lost());
    _listen();
  }

  String _relative(String absolute) => relativeToRoot(root, absolute);
}

/// The kind of [error] a watch failed with: the system's watch limit when it
/// said "no space left on device" — errno 28, which is how inotify reports
/// `fs.inotify.max_user_watches` reached — and a plain failure otherwise.
WatchUnavailableKind watchUnavailableKindOf(Object? error) =>
    error is FileSystemException && error.osError?.errorCode == 28
    ? WatchUnavailableKind.watchLimit
    : WatchUnavailableKind.failed;

/// [absolute], a path under [root] as a watch reports it, made
/// engram-relative with forward slashes — `''` for the root itself.
String relativeToRoot(String root, String absolute) {
  var relative = absolute.replaceAll('\\', '/');
  final prefix = root.replaceAll('\\', '/');
  if (relative.startsWith(prefix)) relative = relative.substring(prefix.length);
  while (relative.startsWith('/')) {
    relative = relative.substring(1);
  }
  return relative;
}
