import 'package:flutter/foundation.dart';
import 'package:brainframe/engram/device_name.dart';

/// A [DeviceNaming] held in memory, recording what it was asked to set —
/// for a session fake that needs one, and for widget tests of the section
/// that edits it.
class FakeDeviceNaming implements DeviceNaming {
  FakeDeviceNaming({
    String? engram,
    String? deviceDefault,
    String platform = 'jdoe-desktop',
  }) : _names = ValueNotifier(
         DeviceNames(
           engram: engram,
           deviceDefault: deviceDefault,
           platform: platform,
         ),
       );

  final ValueNotifier<DeviceNames> _names;

  /// Every call, as `engram:<value>` or `default:<value>`, in order.
  final List<String> calls = [];

  /// When set, every change throws it and changes nothing.
  Object? failWith;

  @override
  DeviceNames get names => _names.value;

  @override
  ValueListenable<DeviceNames> get changes => _names;

  /// Sets the names as another section's save would, notifying [changes].
  set names(DeviceNames names) => _names.value = names;

  @override
  Future<DeviceNames> setEngramName(String? name) async {
    calls.add('engram:$name');
    if (failWith case final error?) throw error;
    return _names.value = DeviceNames(
      engram: normalizeDeviceName(name),
      deviceDefault: names.deviceDefault,
      platform: names.platform,
    );
  }

  @override
  Future<DeviceNames> setDeviceDefault(String? name) async {
    calls.add('default:$name');
    if (failWith case final error?) throw error;
    return _names.value = DeviceNames(
      engram: names.engram,
      deviceDefault: normalizeDeviceName(name),
      platform: names.platform,
    );
  }
}
