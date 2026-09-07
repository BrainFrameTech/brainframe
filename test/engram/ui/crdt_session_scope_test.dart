import 'dart:async';

import 'package:brainframe/engram/asset_engram_store.dart';
import 'package:brainframe/engram/crdt/crdt_session.dart';
import 'package:brainframe/engram/engram.dart';
import 'package:brainframe/engram/engram_scope.dart';
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
  _FakeSession(this._onClose);

  final void Function() _onClose;

  @override
  NoteWriter get writer => _NoopWriter();

  @override
  Future<void> close() async => _onClose();
}

class _NoopWriter implements NoteWriter {
  @override
  Future<void> write(String path, String text) async {}
}
