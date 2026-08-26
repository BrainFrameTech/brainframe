import 'package:brainframe/commands/pending_saves.dart';
import 'package:brainframe/settings/device_settings.dart';
import 'package:brainframe/settings/settings_store.dart';
import 'package:brainframe/window/window_state_io.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

/// An in-memory device backend that records what the persister writes.
class _MapBackend implements SettingsBackend {
  final Map<String, Object?> values = {};

  @override
  Future<Object?> read(String key) async => values[key];

  @override
  Future<void> write(String key, Object? value) async {
    values[key] = value;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('window_manager');
  // window_manager asks screen_retriever for the display when centering.
  const screenChannel = MethodChannel('dev.leanflutter.plugins/screen_retriever');
  late List<String> calls;
  late List<MethodCall> invocations;

  SettingsStore storeWith(_MapBackend device) => SettingsStore(
    device: device,
    engram: () => const NullSettingsBackend(),
  );

  setUp(() {
    calls = [];
    invocations = [];
    resetWindowStatePersistenceForTesting();
    const display = {
      'id': 'mock-display',
      'name': 'mock',
      'size': {'width': 1920.0, 'height': 1080.0},
      'visiblePosition': {'dx': 0.0, 'dy': 0.0},
      'visibleSize': {'width': 1920.0, 'height': 1080.0},
      'scaleFactor': 1.0,
    };
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(screenChannel, (call) async {
          switch (call.method) {
            case 'getAllDisplays':
              return const {'displays': [display]};
            case 'getCursorScreenPoint':
              return const {'dx': 0.0, 'dy': 0.0};
            default:
              return display;
          }
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          invocations.add(call);
          switch (call.method) {
            case 'isMaximized':
              return false;
            case 'getBounds':
              return {'x': 100.0, 'y': 200.0, 'width': 1280.0, 'height': 800.0};
            case 'destroy':
              return true;
            default:
              // window_manager types its is* queries as non-nullable bools, so
              // a null reply throws before the code under test is reached.
              return call.method.startsWith('is') ? false : null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(screenChannel, null);
    debugDefaultTargetPlatformOverride = null;
    resetWindowStatePersistenceForTesting();
  });

  test('onWindowClose saves geometry and destroys the window once', () async {
    final device = _MapBackend();
    final persister = WindowStatePersister(storeWith(device));

    await persister.onWindowClose();

    expect(calls.where((m) => m == 'destroy'), hasLength(1));
    expect(
      device.values[windowStateSetting.key],
      {'x': 100.0, 'y': 200.0, 'width': 1280.0, 'height': 800.0, 'maximized': false},
    );
  });

  test('onWindowClose writes unsaved edits before the window goes away',
      () async {
    final saves = PendingSaves();
    final order = <String>[];
    saves.register('editor', () async => order.add('flush'));
    final device = _MapBackend();
    final persister = WindowStatePersister(
      storeWith(device),
      pendingSaves: saves,
    );

    await persister.onWindowClose();

    // Flushed first, and before the window was destroyed — a debounced
    // keystroke must not die with the process.
    expect(order, ['flush']);
    expect(calls, contains('destroy'));
  });

  test('a failing flush still lets the window close', () async {
    final saves = PendingSaves();
    saves.register('editor', () async => throw StateError('disk full'));
    final persister = WindowStatePersister(
      storeWith(_MapBackend()),
      pendingSaves: saves,
    );

    await persister.onWindowClose();

    expect(calls, contains('destroy'));
  });

  test(
    're-entrant onWindowClose is a no-op — destroy() re-fires the '
    'delete-event, which must not trigger a second save or destroy',
    () async {
      final device = _MapBackend();
      final persister = WindowStatePersister(storeWith(device));

      // The real re-entry happens inside the first destroy(); calling twice
      // reproduces the guard's contract: once closing, further entries return.
      await persister.onWindowClose();
      calls.clear();
      await persister.onWindowClose();

      // The second entry touched neither the window nor the store.
      expect(calls, isEmpty);
    },
  );

  group('initWindowManager with an explicit --window-size', () {
    /// The saved geometry a real user would already have: a different size, a
    /// position, and maximized — everything the override has to beat.
    const savedGeometry = {
      'x': 100.0,
      'y': 200.0,
      'width': 1280.0,
      'height': 800.0,
      'maximized': true,
    };

    _MapBackend seededDevice() =>
        _MapBackend()..values[windowStateSetting.key] = savedGeometry;

    /// The setBounds that carries the size. Centering issues a second
    /// setBounds with only a position, so "the last one" is the wrong call.
    Map<Object?, Object?> sizeBounds() =>
        invocations.firstWhere(
              (c) =>
                  c.method == 'setBounds' &&
                  (c.arguments as Map).containsKey('width'),
            ).arguments
            as Map<Object?, Object?>;

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
    });

    test('opens at the requested size', () async {
      await initWindowManager(startupSize: const Size(1600, 1000));

      expect(sizeBounds()['width'], 1600.0);
      expect(sizeBounds()['height'], 1000.0);
    });

    test('does not restore the saved geometry it was told to override',
        () async {
      await initWindowManager(startupSize: const Size(1600, 1000));

      // Restoring would have re-applied the stored 1280x800 and maximized it,
      // which would defeat the size that was asked for.
      expect(calls, isNot(contains('maximize')));
      expect(sizeBounds()['width'], 1600.0);
    });

    test('does not write the recording size back over the saved geometry',
        () async {
      final device = seededDevice();
      await initWindowManager(startupSize: const Size(1600, 1000));

      // A resize during the session, then the save-on-close path.
      await WindowStatePersister(storeWith(device)).onWindowClose();

      expect(
        device.values[windowStateSetting.key],
        savedGeometry,
        reason: 'a size passed for one session must not become the '
            'remembered one',
      );
    });

    test('without the flag, geometry is persisted as usual', () async {
      final device = seededDevice();
      await initWindowManager();

      await WindowStatePersister(storeWith(device)).onWindowClose();

      expect(
        device.values[windowStateSetting.key],
        isNot(savedGeometry),
        reason: 'the override must not leak into ordinary sessions',
      );
    });
  });
}
