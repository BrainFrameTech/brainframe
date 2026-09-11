import 'dart:async';

import 'package:flutter/widgets.dart';

import '../crdt/crdt_session.dart';
import '../engram.dart';
import '../engram_scope.dart';
import '../note_writer.dart';

/// Owns the active engram's op-log session and publishes how to save into it.
///
/// Placed directly under [EngramScope], because the session's lifetime is the
/// engram's: switching engrams closes the outgoing database before opening the
/// incoming one, and two connections to one `metadata.db` never coexist.
///
/// **It publishes a [NoteWriter], not the session.** Everything below is UI and
/// has no business knowing whether an op-log exists — the editor asks how to
/// save and gets an answer, and on web or a read-only engram that answer is
/// simply "there is nothing here, write to the store".
///
/// Absent by design in widget tests: nothing installs this host, so
/// [maybeOf] returns null and the editor writes directly, exactly as it did
/// before step 9. That is what keeps the browser's tests about the browser.
class CrdtSessionHost extends StatefulWidget {
  const CrdtSessionHost({
    super.key,
    required this.child,
    this.openSession = CrdtSession.openFor,
  });

  final Widget child;

  /// Opens the session for an engram. Injected so a test can supply one
  /// without a real database, and so the app can supply the real thing.
  final Future<CrdtSession?> Function(Engram engram) openSession;

  @override
  State<CrdtSessionHost> createState() => _CrdtSessionHostState();
}

class _CrdtSessionHostState extends State<CrdtSessionHost> {
  CrdtSession? _session;
  String? _engramId;

  /// True until the first session resolution for the current engram finishes.
  ///
  /// The child is withheld while it is set, which is the point: an editor
  /// mounted before the writer exists would save straight to disk, and that
  /// write would come back as drift on the next scan — a real edit, correctly
  /// recovered, but recorded as though it had arrived from outside the app.
  bool _resolving = true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final engram = EngramScope.of(context).engram;
    if (engram.id == _engramId) return;
    _engramId = engram.id;
    setState(() => _resolving = true);
    unawaited(_swapTo(engram));
  }

  Future<void> _swapTo(Engram engram) async {
    // Closed before the next is opened, never after: the outgoing engram's
    // connection must be gone before the incoming one asks for its own.
    await _session?.close();
    _session = null;
    CrdtSession? next;
    try {
      next = await widget.openSession(engram);
    } finally {
      if (mounted && _engramId == engram.id) {
        setState(() {
          _session = next;
          _resolving = false;
        });
      } else {
        // Switched away mid-open: the session we just opened belongs to an
        // engram nobody is looking at, so close it rather than leaking it.
        unawaited(next?.close());
      }
    }
  }

  @override
  void dispose() {
    // dispose cannot await; the handle is released with the process anyway.
    unawaited(_session?.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_resolving) return const SizedBox.shrink();
    return CrdtSessionScope._(writer: _session?.writer, child: widget.child);
  }
}

/// Publishes the active engram's [NoteWriter] to the editor below it.
class CrdtSessionScope extends InheritedWidget {
  const CrdtSessionScope._({required this.writer, required super.child});

  /// How to save into the active engram, or null when it has no op-log.
  final NoteWriter? writer;

  /// The writer for the nearest host, or null if there is no host at all.
  ///
  /// Null is an ordinary answer, not a failure: it means "write to the store",
  /// which is correct for a read-only engram, for web, and for any widget test
  /// that did not install a host.
  static NoteWriter? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<CrdtSessionScope>()
      ?.writer;

  @override
  bool updateShouldNotify(CrdtSessionScope oldWidget) =>
      oldWidget.writer != writer;
}
