import 'dart:typed_data';

import 'package:brainframe/engram/engram.dart';
import 'package:brainframe/engram/engram_scope.dart';
import 'package:brainframe/engram/engram_store.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A minimal store that records how many times it was released, so the scope's
/// switch/dispose contract can be observed.
class _RecordingStore extends EngramStore {
  int releaseCount = 0;

  @override
  Future<List<String>> list() async => const [];

  @override
  Future<Uint8List> readBytes(String path) async => Uint8List(0);

  @override
  Future<void> writeBytes(String path, Uint8List bytes) async {}

  @override
  Future<void> release() async => releaseCount++;
}

Engram _engram(String id, EngramStore store) =>
    Engram(id: id, displayName: id, readOnly: false, store: store);

/// Reads the active engram from the scope and offers a button to switch to
/// [target]; rebuilds whenever the scope's value changes.
class _EngramProbe extends StatelessWidget {
  const _EngramProbe({required this.target});

  final Engram target;

  @override
  Widget build(BuildContext context) {
    final scope = EngramScope.of(context);
    return Column(
      children: [
        Text('active: ${scope.engram.displayName}'),
        TextButton(
          onPressed: () => scope.switchTo(target),
          child: const Text('switch'),
        ),
      ],
    );
  }
}

void main() {
  testWidgets('maybeOf returns null without a scope; of exposes the engram',
      (tester) async {
    EngramScopeData? seen;
    late bool sawNullOutside;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(builder: (context) {
          sawNullOutside = EngramScope.maybeOf(context) == null;
          return EngramScope(
            initialEngram: _engram('a', _RecordingStore()),
            child: Builder(builder: (context) {
              seen = EngramScope.of(context);
              return const SizedBox.shrink();
            }),
          );
        }),
      ),
    );

    expect(sawNullOutside, isTrue);
    expect(seen, isNotNull);
    expect(seen!.engram.id, 'a');
  });

  testWidgets('switching swaps the active engram and releases the old store',
      (tester) async {
    final storeA = _RecordingStore();
    final storeB = _RecordingStore();
    final b = _engram('b', storeB);

    var rootBuilds = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: _RootBuildCounter(
          onBuild: () => rootBuilds++,
          child: EngramScope(
            initialEngram: _engram('a', storeA),
            child: _EngramProbe(target: b),
          ),
        ),
      ),
    );

    expect(find.text('active: a'), findsOneWidget);
    expect(rootBuilds, 1);

    await tester.tap(find.text('switch'));
    await tester.pumpAndSettle();

    expect(find.text('active: b'), findsOneWidget);
    // The outgoing store was released exactly once; the incoming one was not.
    expect(storeA.releaseCount, 1);
    expect(storeB.releaseCount, 0);
    // The switch is local to the scope: the widget above it never rebuilt.
    expect(rootBuilds, 1);
  });

  testWidgets('switching to the already-active engram is a no-op', (tester) async {
    final store = _RecordingStore();
    final same = _engram('a', store);

    await tester.pumpWidget(
      MaterialApp(
        home: EngramScope(
          initialEngram: same,
          child: _EngramProbe(target: _engram('a', _RecordingStore())),
        ),
      ),
    );

    await tester.tap(find.text('switch'));
    await tester.pumpAndSettle();

    expect(find.text('active: a'), findsOneWidget);
    expect(store.releaseCount, 0); // nothing was switched away from
  });

  testWidgets('onSwitched fires with the new engram after a switch',
      (tester) async {
    final switched = <String>[];
    final b = _engram('b', _RecordingStore());

    await tester.pumpWidget(
      MaterialApp(
        home: EngramScope(
          initialEngram: _engram('a', _RecordingStore()),
          onSwitched: (engram) async => switched.add(engram.id),
          child: _EngramProbe(target: b),
        ),
      ),
    );

    await tester.tap(find.text('switch'));
    await tester.pumpAndSettle();

    expect(switched, ['b']);
  });

  testWidgets('the active store is released when the scope is torn down',
      (tester) async {
    final store = _RecordingStore();

    await tester.pumpWidget(
      MaterialApp(
        home: EngramScope(
          initialEngram: _engram('a', store),
          child: const SizedBox.shrink(),
        ),
      ),
    );

    // Replace the scope with something else to dispose its state.
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await tester.pumpAndSettle();

    expect(store.releaseCount, 1);
  });

  group('updateActive', () {
    testWidgets('replaces the engram in place without releasing its store',
        (tester) async {
      final store = _RecordingStore();
      final engram = _engram('a', store);
      late EngramScopeData scope;

      await tester.pumpWidget(
        MaterialApp(
          home: EngramScope(
            initialEngram: engram,
            child: Builder(
              builder: (context) {
                scope = EngramScope.of(context);
                return Text('active: ${scope.engram.displayName}');
              },
            ),
          ),
        ),
      );
      expect(find.text('active: a'), findsOneWidget);

      await scope.updateActive(engram.withDisplayName('Field Notebook'));
      await tester.pump();

      // The dependent rebuilt: the marker used to compare ids only, so a
      // renamed engram left every reader showing the old name.
      expect(find.text('active: Field Notebook'), findsOneWidget);
      // Same engram over the same store: releasing it would close what the
      // user is still reading.
      expect(store.releaseCount, 0);
    });

    testWidgets('a switch still releases the outgoing store', (tester) async {
      // Guards the distinction updateActive introduces: only a rename skips
      // the release.
      final outgoing = _RecordingStore();
      final engram = _engram('a', outgoing);
      final other = _engram('b', _RecordingStore());
      late EngramScopeData scope;

      await tester.pumpWidget(
        MaterialApp(
          home: EngramScope(
            initialEngram: engram,
            child: Builder(
              builder: (context) {
                scope = EngramScope.of(context);
                return Text('active: ${scope.engram.displayName}');
              },
            ),
          ),
        ),
      );

      await scope.switchTo(other);
      await tester.pumpAndSettle();

      expect(outgoing.releaseCount, 1);
    });
  });

  group('EngramScopeProxy', () {
    testWidgets('a captured scope is readable inside a detached subtree',
        (tester) async {
      // A pushed route is the scope's sibling, not its descendant, so without
      // the proxy `EngramScope.of` finds nothing there at all.
      final engram = _engram('a', _RecordingStore());
      late EngramScopeData captured;

      await tester.pumpWidget(
        MaterialApp(
          home: EngramScope(
            initialEngram: engram,
            child: Builder(
              builder: (context) {
                captured = EngramScope.of(context);
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: EngramScopeProxy(
            source: captured,
            child: Builder(
              builder: (context) => Text(
                'inside: ${EngramScope.of(context).engram.displayName}',
              ),
            ),
          ),
        ),
      );

      expect(find.text('inside: a'), findsOneWidget);
    });

    testWidgets('a rename through the proxy updates it and the real scope',
        (tester) async {
      final engram = _engram('a', _RecordingStore());
      late EngramScopeData inner;

      // The real scope stays mounted while the proxy stands in beside it,
      // mirroring Settings pushed over the browser.
      await tester.pumpWidget(
        MaterialApp(
          home: EngramScope(
            initialEngram: engram,
            child: Builder(
              builder: (context) {
                final captured = EngramScope.of(context);
                return Column(
                  children: [
                    Text('below: ${captured.engram.displayName}'),
                    EngramScopeProxy(
                      source: captured,
                      child: Builder(
                        builder: (context) {
                          inner = EngramScope.of(context);
                          return Text(
                            'inside: ${inner.engram.displayName}',
                          );
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );

      expect(find.text('below: a'), findsOneWidget);
      expect(find.text('inside: a'), findsOneWidget);

      await inner.updateActive(engram.withDisplayName('Field Notebook'));
      await tester.pumpAndSettle();

      expect(find.text('inside: Field Notebook'), findsOneWidget);
      expect(find.text('below: Field Notebook'), findsOneWidget);
    });

    testWidgets('a switch through the proxy reaches the real scope',
        (tester) async {
      final engram = _engram('a', _RecordingStore());
      final other = _engram('b', _RecordingStore());
      late EngramScopeData inner;

      await tester.pumpWidget(
        MaterialApp(
          home: EngramScope(
            initialEngram: engram,
            child: Builder(
              builder: (context) {
                final captured = EngramScope.of(context);
                return Column(
                  children: [
                    Text('below: ${captured.engram.displayName}'),
                    EngramScopeProxy(
                      source: captured,
                      child: Builder(
                        builder: (context) {
                          inner = EngramScope.of(context);
                          return const SizedBox.shrink();
                        },
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      );

      await inner.switchTo(other);
      await tester.pumpAndSettle();

      expect(find.text('below: b'), findsOneWidget);
    });
  });

}

class _RootBuildCounter extends StatefulWidget {
  const _RootBuildCounter({required this.onBuild, required this.child});

  final VoidCallback onBuild;
  final Widget child;

  @override
  State<_RootBuildCounter> createState() => _RootBuildCounterState();
}

class _RootBuildCounterState extends State<_RootBuildCounter> {
  @override
  Widget build(BuildContext context) {
    widget.onBuild();
    return widget.child;
  }
}
