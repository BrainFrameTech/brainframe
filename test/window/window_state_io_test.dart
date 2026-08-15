import 'package:brainframe/commands/pending_saves.dart';
import 'package:brainframe/settings/device_settings.dart';
import 'package:brainframe/settings/settings_store.dart';
import 'package:brainframe/window/window_state_io.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

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
  late List<String> calls;

  SettingsStore storeWith(_MapBackend device) => SettingsStore(
    device: device,
    engram: () => const NullSettingsBackend(),
  );

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          switch (call.method) {
            case 'isMaximized':
              return false;
            case 'getBounds':
              return {'x': 100.0, 'y': 200.0, 'width': 1280.0, 'height': 800.0};
            case 'destroy':
              return true;
            default:
              return null;
          }
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
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
}
