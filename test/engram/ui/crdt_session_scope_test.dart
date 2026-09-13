import 'dart:async';

import 'package:brainframe/commands/pending_saves.dart';
import 'package:brainframe/engram/asset_engram_store.dart';
import 'package:brainframe/engram/crdt/crdt_session.dart';
import 'package:brainframe/engram/engram.dart';
import 'package:brainframe/engram/engram_scope.dart';
import 'package:brainframe/engram/note_reconciler.dart';
import 'package:brainframe/engram/note_writer.dart';
import 'package:brainframe/engram/ui/crdt_session_scope.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

/// The host that owns the active engram's session and publishes its writer.
void main() {
  Engram engramNamed(String id) => Engram(
    id: id,
    displayName: id,
    readOnly: false,
    store: AssetEngramStore(assetPrefix: 'assets/engrams/tutorial/'),
  );

  /// Renders whatever writer the scope currently publishes.
  Widget probe() => Builder(
    builder: (context) {
      final writer = CrdtSessionScope.maybeOf(context);
      return Text(
        writer == null ? 'direct' : 'crdt',
        textDirection: TextDirection.ltr,
      );
    },
  );

  testWidgets('publishes null when the engram has no session', (tester) async {
    await tester.pumpWidget(
      EngramScope(
        initialEngram: engramNamed('a'),
        child: CrdtSessionHost(
          openSession: (_) async => null,
          child: probe(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('direct'), findsOneWidget);
  });

  testWidgets('withholds the child until the session resolves', (
    tester,
  ) async {
    final gate = Completer<CrdtSession?>();
    await tester.pumpWidget(
      EngramScope(
        initialEngram: engramNamed('a'),
        child: CrdtSessionHost(
          openSession: (_) => gate.future,
          child: probe(),
        ),
      ),
    );
    await tester.pump();

    // An editor mounted before the writer exists would save straight to disk,
    // and that write would come back as drift on the next scan.
    expect(find.text('direct'), findsNothing);
    expect(find.text('crdt'), findsNothing);

    gate.complete(null);
    await tester.pumpAndSettle();
    expect(find.text('direct'), findsOneWidget);
  });

  testWidgets('a session is closed before the next one opens', (tester) async {
    final order = <String>[];
    final scope = GlobalKey<State<EngramScope>>();

    await tester.pumpWidget(
      EngramScope(
        key: scope,
        initialEngram: engramNamed('a'),
        child: CrdtSessionHost(
          openSession: (engram) async {
            order.add('open ${engram.id}');
            return _FakeSession(() => order.add('close ${engram.id}'));
          },
          child: probe(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('crdt'), findsOneWidget);

    await EngramScope.of(tester.element(find.text('crdt')))
        .switchTo(engramNamed('b'));
    await tester.pumpAndSettle();

    // Two connections to one metadata.db would defeat the single transaction
    // boundary the schema depends on, so the ordering is load-bearing.
    expect(order, ['open a', 'close a', 'open b']);
  });

  testWidgets('publishes the session\'s reconciler beside its writer', (
    tester,
  ) async {
    final session = _FakeSession(() {});
    NoteReconciler? published;
    await tester.pumpWidget(
      EngramScope(
        initialEngram: engramNamed('a'),
        child: CrdtSessionHost(
          openSession: (_) async => session,
          child: Builder(
            builder: (context) {
              published = CrdtSessionScope.maybeReconcilerOf(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(identical(published, session.reconciler), isTrue);
  });

  testWidgets('the reconciler is null when there is no session', (
    tester,
  ) async {
    NoteReconciler? published = _RecordingReconciler();
    await tester.pumpWidget(
      EngramScope(
        initialEngram: engramNamed('a'),
        child: CrdtSessionHost(
          openSession: (_) async => null,
          child: Builder(
            builder: (context) {
              published = CrdtSessionScope.maybeReconcilerOf(context);
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(published, isNull);
  });

  group('the scan on start', () {
    testWidgets('starts when the session opens, and the child does not wait',
        (tester) async {
      // A first scan over a large folder mints every note in it, minutes on
      // the slowest target. The engram is usable throughout: the editor's
      // before-open reconciliation brings in whichever note the user reaches
      // first, and the scan finds it present when it gets there.
      final reconciler = _RecordingReconciler()..gate = Completer<void>();
      await tester.pumpWidget(
        EngramScope(
          initialEngram: engramNamed('a'),
          child: CrdtSessionHost(
            openSession: (_) async =>
                _FakeSession(() {}, reconciler: reconciler),
            child: probe(),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(reconciler.scans, 1);
      expect(find.text('crdt'), findsOneWidget, reason: 'published mid-scan');

      reconciler.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.text('crdt'), findsOneWidget);
    });

    testWidgets('a scan that throws is logged, not raised', (tester) async {
      // The scan collects per-note failures itself; what can still throw is
      // the catalog being unreadable, and a fire-and-forget must not turn
      // that into an unhandled error in the zone.
      final reconciler = _RecordingReconciler()..failScans = true;
      await tester.pumpWidget(
        EngramScope(
          initialEngram: engramNamed('a'),
          child: CrdtSessionHost(
            openSession: (_) async =>
                _FakeSession(() {}, reconciler: reconciler),
            child: probe(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(reconciler.scans, 1);
      expect(find.text('crdt'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('runs again for the incoming engram on a switch', (
      tester,
    ) async {
      final log = <String>[];
      await tester.pumpWidget(
        EngramScope(
          initialEngram: engramNamed('a'),
          child: CrdtSessionHost(
            openSession: (engram) async {
              log.add('open ${engram.id}');
              return _FakeSession(
                () => log.add('close ${engram.id}'),
                reconciler: _RecordingReconciler(log: log),
              );
            },
            child: probe(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await EngramScope.of(
        tester.element(find.text('crdt')),
      ).switchTo(engramNamed('b'));
      await tester.pumpAndSettle();

      expect(log, ['open a', 'scan', 'close a', 'open b', 'scan']);
    });
  });

  group('the scan on resume', () {
    testWidgets('flushes every registered editor, then scans', (tester) async {
      // Decision 6's first step: reconciling underneath an unsaved buffer
      // would race the save, so the flush comes first and is awaited.
      final log = <String>[];
      final pendingSaves = PendingSaves();
      final flushed = Completer<void>();
      pendingSaves.register(#editor, () {
        log.add('flush');
        return flushed.future;
      });
      final reconciler = _RecordingReconciler(log: log);
      await tester.pumpWidget(
        EngramScope(
          initialEngram: engramNamed('a'),
          child: CrdtSessionHost(
            openSession: (_) async =>
                _FakeSession(() {}, reconciler: reconciler),
            pendingSaves: pendingSaves,
            child: probe(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      log.clear();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      expect(log, ['flush'], reason: 'the scan waits for the flush');

      flushed.complete();
      await tester.pumpAndSettle();
      expect(log, ['flush', 'scan']);
    });

    testWidgets('other lifecycle states do not scan', (tester) async {
      final reconciler = _RecordingReconciler();
      await tester.pumpWidget(
        EngramScope(
          initialEngram: engramNamed('a'),
          child: CrdtSessionHost(
            openSession: (_) async =>
                _FakeSession(() {}, reconciler: reconciler),
            pendingSaves: PendingSaves(),
            child: probe(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final atStart = reconciler.scans;

      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.detached,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
        await tester.pumpAndSettle();
      }

      expect(reconciler.scans, atStart);
    });

    testWidgets('does nothing without a session', (tester) async {
      var flushes = 0;
      final pendingSaves = PendingSaves()
        ..register(#editor, () async => flushes++);
      await tester.pumpWidget(
        EngramScope(
          initialEngram: engramNamed('a'),
          child: CrdtSessionHost(
            openSession: (_) async => null,
            pendingSaves: pendingSaves,
            child: probe(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();

      expect(flushes, 0, reason: 'nothing to reconcile against');
    });
  });

  testWidgets('the last session is closed when the host goes away', (
    tester,
  ) async {
    var closed = false;
    await tester.pumpWidget(
      EngramScope(
        initialEngram: engramNamed('a'),
        child: CrdtSessionHost(
          openSession: (_) async => _FakeSession(() => closed = true),
          child: probe(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();

    expect(closed, isTrue);
  });
}

/// A session that records its close without touching a database.
class _FakeSession implements CrdtSession {
  _FakeSession(this._onClose, {_RecordingReconciler? reconciler})
    : reconciler = reconciler ?? _RecordingReconciler();

  final void Function() _onClose;

  @override
  NoteWriter get writer => _NoopWriter();

  @override
  final _RecordingReconciler reconciler;

  @override
  Future<void> close() async => _onClose();
}

/// A reconciler that records each scan, optionally via a shared log, and can
/// hold a scan open until told to finish.
class _RecordingReconciler implements NoteReconciler {
  _RecordingReconciler({List<String>? log}) : log = log ?? <String>[];

  final List<String> log;
  int scans = 0;
  Completer<void>? gate;
  bool failScans = false;

  @override
  Future<DriftScanReport> scan() async {
    scans++;
    log.add('scan');
    if (gate != null) await gate!.future;
    if (failScans) throw StateError('catalog unreadable');
    return DriftScanReport.clean;
  }

  @override
  Future<bool> reconcile(String path) async => false;

  @override
  Future<void> noteCreated(String path) async {}

  @override
  Future<void> noteMoved(String from, String to) async {}

  @override
  Future<void> noteDeleted(String path) async {}

  @override
  Stream<AdoptionProgress?> get adoption => const Stream<AdoptionProgress?>.empty();

  @override
  AdoptionProgress? get currentAdoption => null;

  @override
  Future<NoteLedger> ledger() async => const NoteLedger(
    peers: 1,
    minted: 0,
    adopted: 0,
    unclaimed: 0,
    tombstoned: 0,
  );

  @override
  List<ScanNotice> get recentScans => const [];

  @override
  Stream<String> get reconciled => const Stream<String>.empty();
}

class _NoopWriter implements NoteWriter {
  @override
  Future<void> write(String path, String text) async {}
}
