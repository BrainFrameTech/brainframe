import 'dart:async';
import 'dart:io';

import 'package:brainframe/engram/crdt/device_naming_io.dart';
import 'package:brainframe/engram/crdt/identity_authorship_io.dart';
import 'package:brainframe/engram/crdt/identity_map_io.dart';
import 'package:brainframe/engram/crdt/metadata_db_io.dart';
import 'package:brainframe/engram/device_name.dart';
import 'package:brainframe/settings/device_settings.dart';
import 'package:brainframe/settings/settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// This device's name in an open engram (the device names design, Decisions
/// 1 and 2): resolved from three sources, stored where each belongs, and
/// published in the map file only when it changes.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory folder;
  late MetadataDatabase database;
  late _MemorySettings device;

  setUp(() {
    folder = Directory.systemTemp.createTempSync('brainframe_device_naming');
    database = MetadataDatabase.openInMemory();
    device = _MemorySettings();
  });

  tearDown(() {
    database.close();
    if (folder.existsSync()) folder.deleteSync(recursive: true);
  });

  IdentityMap mapFor(MetadataDatabase db) =>
      IdentityMap(engramRoot: folder.path, peerId: db.peerId);

  Future<(SessionDeviceNaming, AuthoredIdentity)> open({
    MetadataDatabase? db,
    SettingsBackend? settings,
    String host = 'jdoe-desktop',
  }) async {
    final store = db ?? database;
    final identity = await AuthoredIdentity.load(mapFor(store));
    addTearDown(identity.dispose);
    final naming = await SessionDeviceNaming.open(
      database: store,
      identity: identity,
      deviceSettings: settings ?? device,
      platformName: PlatformDeviceName(
        operatingSystem: 'linux',
        hostname: () => host,
      ),
    );
    return (naming, identity);
  }

  test('with nothing set, the platform\'s name is published', () async {
    final (naming, identity) = await open();
    expect(
      naming.names,
      const DeviceNames(
        engram: null,
        deviceDefault: null,
        platform: 'jdoe-desktop',
      ),
    );
    await identity.flush();
    final published = mapFor(database).readOurName()!;
    expect(published.name, 'jdoe-desktop');
    expect(published.platform, 'linux');
  });

  test('this engram\'s name wins over the default', () async {
    final (naming, identity) = await open();
    await naming.setDeviceDefault('jdoe\'s laptop');
    expect(naming.names.resolved, 'jdoe\'s laptop');

    final names = await naming.setEngramName('  Work laptop  ');
    expect(names.engram, 'Work laptop', reason: 'trimmed as stored');
    expect(names.resolved, 'Work laptop');
    await identity.flush();
    expect(mapFor(database).readOurName()!.name, 'Work laptop');
  });

  test('clearing a name falls back one step', () async {
    final (naming, _) = await open();
    await naming.setDeviceDefault('jdoe\'s laptop');
    await naming.setEngramName('Work laptop');

    expect((await naming.setEngramName('   ')).resolved, 'jdoe\'s laptop');
    expect((await naming.setDeviceDefault(null)).resolved, 'jdoe-desktop');
    expect(database.readMeta(SessionDeviceNaming.engramNameKey), isNull);
  });

  test(
    'this engram\'s name is kept in its local database, not the folder',
    () async {
      final (naming, _) = await open();
      await naming.setEngramName('Work laptop');
      expect(
        database.readMeta(SessionDeviceNaming.engramNameKey),
        'Work laptop',
      );
      expect(
        File('${folder.path}/.brainframe/settings.json').existsSync(),
        isFalse,
        reason: 'the synced settings would carry it to every other device',
      );
      expect(await device.read(deviceDefaultNameSetting.key), isNull);
    },
  );

  test('the default is kept in the device tier', () async {
    final (naming, _) = await open();
    await naming.setDeviceDefault('jdoe\'s laptop');
    expect(await device.read(deviceDefaultNameSetting.key), 'jdoe\'s laptop');
    expect(database.readMeta(SessionDeviceNaming.engramNameKey), isNull);
  });

  test('a changed default reaches an engram without a name of its own, '
      'and not one with', () async {
    // Two engrams on one device: one database each, one device tier shared.
    final other = MetadataDatabase.openInMemory();
    addTearDown(other.close);
    final (first, _) = await open();
    await first.setEngramName('Work laptop');
    await first.setDeviceDefault('jdoe\'s laptop');

    // Opened after the default changed, the second has no name of its own.
    final (second, _) = await open(db: other);
    expect(second.names.resolved, 'jdoe\'s laptop');
    expect(first.names.resolved, 'Work laptop');

    // Reopened, the first still has its own.
    final (reopened, _) = await open();
    expect(reopened.names.resolved, 'Work laptop');
  });

  test(
    'every open publishes, but rewrites the file only on a change',
    () async {
      final (_, first) = await open();
      await first.flush();
      final stamped = mapFor(database).readOurName()!;

      final (again, second) = await open();
      await second.flush();
      expect(
        mapFor(database).readOurName(),
        stamped,
        reason: 'the same name, so not even its stamp moved',
      );

      await again.setEngramName('Work laptop');
      await second.flush();
      expect(mapFor(database).readOurName()!.name, 'Work laptop');
    },
  );

  test('a default that cannot be read is treated as unset', () async {
    final (naming, _) = await open(settings: _BrokenSettings());
    expect(naming.names.deviceDefault, isNull);
    expect(naming.names.resolved, 'jdoe-desktop');
  });

  test('closing waits for a default still being saved, then refuses '
      'any more', () async {
    final gated = _GatedSettings();
    final (naming, identity) = await open(settings: gated);
    final saving = naming.setDeviceDefault('jdoe\'s laptop');

    var closed = false;
    final closing = naming.close().then((_) => closed = true);
    await pumpEventQueue();
    expect(closed, isFalse, reason: 'the save is still in the device tier');

    gated.release();
    await closing;
    expect((await saving).resolved, 'jdoe\'s laptop');
    expect(
      identity.name!.name,
      'jdoe\'s laptop',
      reason:
          'published before close returned, so the flush that follows '
          'writes it',
    );

    expect(() => naming.setDeviceDefault('late'), throwsStateError);
    expect(() => naming.setEngramName('late'), throwsStateError);
  });

  test('a save begun as closing starts is refused, never stranded', () async {
    final gated = _GatedSettings();
    final (naming, _) = await open(settings: gated);
    final closing = naming.close();
    expect(() => naming.setDeviceDefault('late'), throwsStateError);
    gated.release();
    await closing;
  });

  test('settling waits out a save that fails', () async {
    final (naming, _) = await open(settings: _FailingWrites());
    final saving = expectLater(
      naming.setDeviceDefault('jdoe\'s laptop'),
      throwsStateError,
    );
    await naming.settle();
    await saving;
  });

  test('an engram with no map file still keeps its names', () async {
    final naming = await SessionDeviceNaming.open(
      database: database,
      identity: null,
      deviceSettings: device,
      platformName: PlatformDeviceName(
        operatingSystem: 'linux',
        hostname: () => 'jdoe-desktop',
      ),
    );
    expect((await naming.setEngramName('Work laptop')).resolved, 'Work laptop');
    expect(Directory('${folder.path}/.brainframe').existsSync(), isFalse);
  });
}

/// A device tier held in memory.
class _MemorySettings implements SettingsBackend {
  final Map<String, Object?> values = {};

  @override
  Future<Object?> read(String key) async => values[key];

  @override
  Future<void> write(String key, Object? value) async => values[key] = value;
}

/// A device tier that cannot be read: preferences unavailable.
class _BrokenSettings implements SettingsBackend {
  @override
  Future<Object?> read(String key) async => throw StateError('no prefs');

  @override
  Future<void> write(String key, Object? value) async {}
}

/// A device tier whose writes wait until [release] is called: a save that is
/// still in flight when the engram closes.
class _GatedSettings extends _MemorySettings {
  final Completer<void> _gate = Completer<void>();

  void release() => _gate.complete();

  @override
  Future<void> write(String key, Object? value) async {
    await _gate.future;
    await super.write(key, value);
  }
}

/// A device tier that can be read but not written.
class _FailingWrites extends _MemorySettings {
  @override
  Future<void> write(String key, Object? value) async =>
      throw StateError('prefs are read-only');
}
