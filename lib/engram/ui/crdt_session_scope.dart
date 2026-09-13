import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/widgets.dart';

import '../../commands/pending_saves.dart';
import '../crdt/crdt_session.dart';
import '../engram.dart';
import '../engram_scope.dart';
import '../note_reconciler.dart';
import '../note_writer.dart';

/// Owns the active engram's op-log session and publishes how to save into it.
///
/// Placed directly under [EngramScope], because the session's lifetime is the
/// engram's: switching engrams closes the outgoing database before opening the
/// incoming one, and two connections to one `metadata.db` never coexist.
///
/// **It publishes a [NoteWriter] and a [NoteReconciler], not the session.**
/// Everything below is UI and has no business knowing whether an op-log
/// exists — the editor asks how to save and gets an answer, and on web or a
/// read-only engram that answer is simply "there is nothing here, write to
/// the store".
///
/// **It also owns two of the scan's three triggers** (Decision 6): the scan
/// on app start — which, from here, is the moment a session opens, so an
/// engram switch gets one too — and the scan on app resume. The third, before
/// a file is opened for editing, belongs to the editor pane, which is the one
/// that knows a file is about to open.
///
/// **Neither scan is waited for.** The session is published the moment it
/// opens and the scan runs behind the UI. A first scan over a folder that
/// predates the catalog mints every note in it — adoption at scale, which on
/// the slowest target is minutes — and the engram is usable throughout: the
/// editor's before-open reconciliation brings in whichever note the user
/// reaches first, and the scan finds it already present when it gets there.
/// What the scan is doing is on the reconciler's progress stream, for the
/// browser to show.
///
/// Absent by design in widget tests: nothing installs this host, so
/// [maybeOf] returns null and the editor writes directly, exactly as it did
/// before step 9. That is what keeps the browser's tests about the browser.
class CrdtSessionHost extends StatefulWidget {
  const CrdtSessionHost({
    super.key,
    required this.child,
    this.openSession = CrdtSession.openFor,
    this.pendingSaves,
  });

  final Widget child;

  /// Opens the session for an engram. Injected so a test can supply one
  /// without a real database, and so the app can supply the real thing.
  final Future<CrdtSession?> Function(Engram engram) openSession;

  /// The flush registry consulted before a resume scan, or the app-wide one
  /// when null. Injected so a test can register a flush of its own.
  final PendingSaves? pendingSaves;

  @override
  State<CrdtSessionHost> createState() => _CrdtSessionHostState();
}

class _CrdtSessionHostState extends State<CrdtSessionHost>
    with WidgetsBindingObserver {
  CrdtSession? _session;
  String? _engramId;

  /// True until the first session resolution for the current engram finishes.
  ///
  /// The child is withheld while it is set, which is the point: an editor
  /// mounted before the writer exists would save straight to disk, and that
  /// write would come back as drift on the next scan — a real edit, correctly
  /// recovered, but recorded as though it had arrived from outside the app.
  /// Opening the session is quick; the scan that follows is not, and is not
  /// inside this window.
  bool _resolving = true;

  PendingSaves get _pendingSaves =>
      widget.pendingSaves ?? PendingSaves.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

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
        // The scan on start, behind the UI. Nothing is registered to flush
        // yet — the child is only now mounting — so Decision 6's first step
        // is vacuously done. The report has no surface until step 13; what
        // it says is logged by the scan.
        if (next != null) _scanInBackground(next, ScanTrigger.open);
      } else {
        // Switched away mid-open: the session we just opened belongs to an
        // engram nobody is looking at, so close it rather than leaking it.
        unawaited(next?.close());
      }
    }
  }

  /// Runs a scan without waiting for it. The scan collects per-note failures
  /// itself; what can still throw is the catalog being unreadable, which is
  /// logged rather than left as an unhandled error from a fire-and-forget.
  void _scanInBackground(CrdtSession session, ScanTrigger trigger) {
    unawaited(
      session.reconciler.scan(trigger: trigger).catchError((
        Object error,
        StackTrace stack,
      ) {
        developer.log(
          'scan failed',
          name: 'brainframe.engram.drift',
          error: error,
          stackTrace: stack,
        );
        return const DriftScanReport();
      }),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_scanOnResume());
  }

  /// The scan on resume: the app was in the background, and anything could
  /// have happened to the folder in the meantime.
  ///
  /// The editor is flushed first, which is Decision 6's step 1 — reconciling
  /// underneath an unsaved buffer would race the save. In practice the buffer
  /// is already clean, since pause flushed it, and this is the guarantee
  /// rather than the common case. A session that resolves mid-flight is left
  /// to its own start-up scan.
  Future<void> _scanOnResume() async {
    final session = _session;
    if (session == null) return;
    await _pendingSaves.flushAll();
    if (!mounted || !identical(_session, session)) return;
    _scanInBackground(session, ScanTrigger.resume);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // dispose cannot await; the handle is released with the process anyway.
    unawaited(_session?.close());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_resolving) return const SizedBox.shrink();
    return CrdtSessionScope._(
      writer: _session?.writer,
      reconciler: _session?.reconciler,
      child: widget.child,
    );
  }
}

/// Publishes the active engram's [NoteWriter] and [NoteReconciler] to the
/// editor below it.
class CrdtSessionScope extends InheritedWidget {
  const CrdtSessionScope._({
    required this.writer,
    required this.reconciler,
    required super.child,
  });

  /// Re-publishes a captured session inside a pushed route.
  ///
  /// The host lives at the app's `home`, so a route pushed over it is a
  /// sibling, not a descendant, and would not see the session at all — the
  /// same reason `openSettingsScreen` proxies the engram scope. A caller
  /// captures [maybeOf] and [maybeReconcilerOf] before the push and wraps the
  /// route's content in this, so Settings can ask the reconciler what it
  /// knows. It publishes and nothing more: no session is opened or closed
  /// here, and the host underneath still owns both.
  const CrdtSessionScope.republish({
    super.key,
    required this.writer,
    required this.reconciler,
    required super.child,
  });

  /// How to save into the active engram, or null when it has no op-log.
  final NoteWriter? writer;

  /// How to reconcile a file that changed outside the app, or null when the
  /// engram has no op-log — in which case nothing can drift from anything.
  final NoteReconciler? reconciler;

  /// The writer published by the enclosing [CrdtSessionHost] widget — the
  /// closest one up the widget tree from [context] — or null if this widget
  /// is not under one at all.
  ///
  /// Null is an ordinary answer, not a failure: it means "write to the store",
  /// which is correct for a read-only engram, for web, and for any widget test
  /// that did not install a host.
  static NoteWriter? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<CrdtSessionScope>()
      ?.writer;

  /// The reconciler published by the enclosing [CrdtSessionHost] widget, or
  /// null if there is none — the same three cases as [maybeOf], and null
  /// means "nothing to reconcile against".
  static NoteReconciler? maybeReconcilerOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<CrdtSessionScope>()
      ?.reconciler;

  @override
  bool updateShouldNotify(CrdtSessionScope oldWidget) =>
      oldWidget.writer != writer || oldWidget.reconciler != reconciler;
}
