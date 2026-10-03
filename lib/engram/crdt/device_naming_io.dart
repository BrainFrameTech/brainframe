/// This device's name in the open engram, resolved from its three sources and
/// published to the engram's other devices (the device names design,
/// Decisions 1 and 2).
///
/// `dart:io`-only by way of the database and the map file. The session owns
/// one of these for as long as the engram is open; Settings reaches it
/// through the [DeviceNaming] seam.
library;

import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

import '../../settings/device_settings.dart';
import '../../settings/settings_store.dart';
import '../device_name.dart';
import 'identity_authorship_io.dart';
import 'metadata_db_io.dart';

/// The `dart:developer` log name for naming's own messages.
const String deviceNamingLogName = 'brainframe.engram.device_name';

/// The open engram's [DeviceNaming]: reads the three names, keeps the
/// engram's own in its `metadata.db`, the default in the device tier, and
/// publishes the result in this device's map file.
class SessionDeviceNaming implements DeviceNaming {
  SessionDeviceNaming._(
    this._database,
    this._identity,
    this._deviceSettings,
    this._platform,
    DeviceNames names,
  ) : _names = ValueNotifier(names);

  /// The `bf_meta` key holding this engram's name for the device. In the
  /// engram's local database — which never leaves the machine — and never in
  /// `.brainframe/settings.json`, which travels with the folder and would
  /// carry this device's name to every other device as their own.
  static const String engramNameKey = 'device_name';

  final MetadataDatabase _database;

  /// Where the name is published, or null for an engram with no map file —
  /// one that is not a folder. Its names can still be set; nothing sees them.
  final AuthoredIdentity? _identity;

  final SettingsBackend _deviceSettings;
  final String _platform;
  final ValueNotifier<DeviceNames> _names;

  /// Set by [close]: the session's identity and database are going away, so
  /// nothing may be published or stored through them any more.
  bool _closed = false;

  /// Saves still in flight, so [settle] and [close] can wait them out. A
  /// save that awaited the device tier while the engram closed would
  /// otherwise publish through a writer the session had already flushed,
  /// and that writer's late file could replace a reopened session's map.
  final Set<Future<void>> _pending = {};

  /// Reads the names and publishes the one that results.
  ///
  /// **Never fails the open.** A device default that cannot be read is
  /// treated as unset, and the platform's name never throws; a name is
  /// never worth refusing an engram over.
  static Future<SessionDeviceNaming> open({
    required MetadataDatabase database,
    required AuthoredIdentity? identity,
    required SettingsBackend deviceSettings,
    required PlatformDeviceName platformName,
  }) async {
    final naming = SessionDeviceNaming._(
      database,
      identity,
      deviceSettings,
      platformName.platform,
      DeviceNames(
        engram: normalizeDeviceName(database.readMeta(engramNameKey)),
        deviceDefault: await _readDefault(deviceSettings),
        platform: await platformName.read(),
      ),
    );
    naming._publish();
    return naming;
  }

  @override
  DeviceNames get names => _names.value;

  @override
  ValueListenable<DeviceNames> get changes => _names;

  @override
  Future<DeviceNames> setEngramName(String? name) async {
    _checkOpen();
    final normalized = normalizeDeviceName(name);
    if (normalized == null) {
      _database.deleteMeta(engramNameKey);
    } else {
      _database.writeMeta(engramNameKey, normalized);
    }
    _names.value = DeviceNames(
      engram: normalized,
      deviceDefault: names.deviceDefault,
      platform: names.platform,
    );
    _publish();
    return names;
  }

  @override
  Future<DeviceNames> setDeviceDefault(String? name) {
    _checkOpen();
    final save = _setDeviceDefault(name);
    _pending.add(save);
    return save.whenComplete(() => _pending.remove(save));
  }

  Future<DeviceNames> _setDeviceDefault(String? name) async {
    final normalized = normalizeDeviceName(name);
    await _deviceSettings.write(
      deviceDefaultNameSetting.key,
      deviceDefaultNameSetting.encode(normalized),
    );
    _names.value = DeviceNames(
      engram: names.engram,
      deviceDefault: normalized,
      platform: names.platform,
    );
    _publish();
    return names;
  }

  /// Waits for every save in flight, so a flush that follows writes the
  /// name they published. A save that failed is the caller's to report.
  Future<void> settle() async {
    while (_pending.isNotEmpty) {
      await Future.wait(
        _pending.map((save) => save.then<void>((_) {}, onError: (_) {})),
      );
    }
  }

  /// Refuses any further save, then waits out every one in flight. The
  /// session calls this before it flushes the map and closes the database.
  Future<void> close() async {
    // Closed first, then settled: a save is refused or counted, never
    // accepted in the gap after the last one settled.
    _closed = true;
    await settle();
  }

  void _checkOpen() {
    if (_closed) {
      throw StateError('the engram this device name belongs to is closed');
    }
  }

  /// Publishes the resolved name, if it differs from what was last
  /// published: the map file is rewritten only when the name changed.
  void _publish() {
    _identity?.publishName(names.resolved, platform: _platform);
  }

  static Future<String?> _readDefault(SettingsBackend settings) async {
    try {
      final raw = await settings.read(deviceDefaultNameSetting.key);
      return normalizeDeviceName(deviceDefaultNameSetting.decode(raw));
    } on Object catch (error, stack) {
      developer.log(
        'the device default name could not be read; using none',
        name: deviceNamingLogName,
        error: error,
        stackTrace: stack,
      );
      return null;
    }
  }
}
