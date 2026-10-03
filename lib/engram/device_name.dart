/// What this device is called in an engram (the device names design,
/// Decisions 1 and 2): the name the engram's other devices see it by.
///
/// The name an engram's other devices see is the first of:
///
/// 1. **this engram's name for the device**, if one is set — the override,
///    kept in the engram's local `metadata.db`, never in the synced folder;
/// 2. **the device's default name**, if one is set — one name for every
///    engram with no override, a device-tier setting;
/// 3. **the platform's name** for the device: the hostname on a desktop, the
///    phone's own name on Android, the model on iOS ([PlatformDeviceName]).
///
/// That is the theme's model — a device default and a per-engram override
/// that wins when set — with one difference: the override must not travel
/// with the folder, since the folder reaches every other device, and each
/// would take the name as its own.
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'device_name_rules.dart';

export 'device_name_rules.dart';

/// The three names behind a device's name in one engram, and which one wins.
class DeviceNames {
  const DeviceNames({
    required this.engram,
    required this.deviceDefault,
    required this.platform,
  });

  /// This engram's name for the device, or null to use the default.
  final String? engram;

  /// The device's default name for every engram, or null to use the
  /// platform's.
  final String? deviceDefault;

  /// The platform's name for the device: always present.
  final String platform;

  /// What the engram's other devices see: the first of [engram],
  /// [deviceDefault], and [platform] that is set.
  String get resolved => engram ?? deviceDefault ?? platform;

  /// What the device is called where this engram has no name for it: the
  /// default, else the platform's — what "use the default" falls back to.
  String get withoutEngram => deviceDefault ?? platform;

  @override
  bool operator ==(Object other) =>
      other is DeviceNames &&
      other.engram == engram &&
      other.deviceDefault == deviceDefault &&
      other.platform == platform;

  @override
  int get hashCode => Object.hash(engram, deviceDefault, platform);

  @override
  String toString() =>
      'DeviceNames(engram: $engram, default: $deviceDefault, '
      'platform: $platform)';
}

/// How Settings reads and sets this device's names for the open engram, and
/// publishes the result to the engram's other devices.
///
/// A seam rather than the session itself, as the reconciler is, so the pane
/// has no `dart:io` database in it and a widget test can hand in a fake.
abstract interface class DeviceNaming {
  /// The names as they stand.
  DeviceNames get names;

  /// [names], for whoever shows them: notified on every change, whoever
  /// made it. A Settings section rebuilt while a save it started is still
  /// in flight learns the outcome here, since the section that started the
  /// save is gone by the time it lands.
  ValueListenable<DeviceNames> get changes;

  /// Sets this engram's name for the device — null or blank clears it — and
  /// publishes the name that results. Returns the names as they now stand.
  Future<DeviceNames> setEngramName(String? name);

  /// Sets the device's default name for every engram — null or blank clears
  /// it — and publishes the name that results here. Another engram picks it
  /// up the next time it is open. Returns the names as they now stand.
  Future<DeviceNames> setDeviceDefault(String? name);
}

/// The platform's own name for this device: the last fallback of the three.
///
/// - **Desktop and the Pi:** the hostname. A macOS hostname's trailing
///   `.local` is dropped; it is the network's suffix, not part of the name.
/// - **Android:** the name the user gave the phone
///   (`Settings.Global.DEVICE_NAME`), else its model, over a small platform
///   channel.
/// - **iOS:** the model — "iPhone", "iPad". Since iOS 16, `UIDevice.name`
///   returns that much and no more unless Apple grants the app a
///   special entitlement, so the setting is how an iPhone gets a real name.
///
/// Never throws: a platform that cannot answer gets the hostname, and a
/// hostname that is blank gets the platform's identifier.
class PlatformDeviceName {
  PlatformDeviceName({
    String? operatingSystem,
    String Function()? hostname,
    MethodChannel? channel,
  }) : platform = operatingSystem ?? Platform.operatingSystem,
       _hostname = hostname ?? (() => Platform.localHostname),
       _channel = channel ?? const MethodChannel(channelName);

  /// The channel the Android and iOS runners answer `name` on.
  static const String channelName = 'tech.brainframe.app/device';

  /// The platform, as `Platform.operatingSystem` spells it: `linux`,
  /// `macos`, `windows`, `android`, `ios`. Published beside the name.
  final String platform;

  final String Function() _hostname;
  final MethodChannel _channel;

  /// Reads the platform's name for this device.
  Future<String> read() async {
    String? name;
    switch (platform) {
      case 'android':
      case 'ios':
        try {
          name = await _channel.invokeMethod<String>('name');
        } on PlatformException {
          name = null;
        } on MissingPluginException {
          name = null;
        }
      case 'macos':
        name = _host();
        if (name != null && name.toLowerCase().endsWith('.local')) {
          name = name.substring(0, name.length - '.local'.length);
        }
      default:
        name = _host();
    }
    return normalizeDeviceName(name) ??
        normalizeDeviceName(_host()) ??
        platform;
  }

  String? _host() {
    try {
      return _hostname();
    } on Object {
      return null;
    }
  }
}
