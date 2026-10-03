import 'package:brainframe/engram/device_name.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:flutter_test/flutter_test.dart';

/// What a device is called (the device names design, Decision 1): how a name
/// is stored, which of the three wins, and what each platform calls itself.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('normalizeDeviceName', () {
    test('trims, and a blank is no name at all', () {
      expect(normalizeDeviceName('  jdoe-desktop  '), 'jdoe-desktop');
      expect(normalizeDeviceName('   '), isNull);
      expect(normalizeDeviceName(''), isNull);
      expect(normalizeDeviceName(null), isNull);
    });

    test('cuts at 64 characters as a reader counts them', () {
      expect(normalizeDeviceName('x' * 64), 'x' * 64);
      expect(normalizeDeviceName('x' * 80), 'x' * 64);
      // A family emoji is several code points and one character: cut by
      // code units it would be split, and the name would end in garbage.
      const family = '👨‍👩‍👧';
      final name = normalizeDeviceName('${'a' * 63}$family$family');
      expect(name, '${'a' * 63}$family');
    });

    test('caps code points too, keeping only whole characters', () {
      // One character as a reader sees it, built of a letter and 300
      // combining accents: 64 such characters would pass the character
      // limit and be enormous. The code-point limit stops it — and takes
      // whole characters only, so the first of them, too large alone,
      // leaves no name at all.
      final heavy = 'a${'́' * 300}';
      expect(heavy.characters.length, 1);
      expect(normalizeDeviceName(heavy), isNull);
      expect(normalizeDeviceName('jdoe$heavy'), 'jdoe');

      // Many ordinary accented characters fit both limits untouched.
      final accented = 'é' * 64; // 64 characters, 128 code points
      expect(normalizeDeviceName(accented), accented);
    });

    test('control characters become spaces, NUL above all', () {
      // SQLite cuts text at a NUL, so a name holding one would be read back
      // shorter by every other device. A pasted tab or line break becomes a
      // space rather than running two words together.
      expect(normalizeDeviceName('Desk\u0000top'), 'Desk top');
      expect(normalizeDeviceName('jdoe\tlaptop'), 'jdoe laptop');
      expect(normalizeDeviceName('jdoe\r\nlaptop'), 'jdoe  laptop');
      expect(normalizeDeviceName('\u0000\u007F\u0085'), isNull);
      expect(normalizeDeviceName('café'), 'café', reason: 'not a control');
    });

    test('normalizing a normalized name changes nothing', () {
      // What lets another device read a name back exactly as it was
      // stored: it normalizes what it reads, and must land on the same.
      for (final raw in [
        '  jdoe\'s laptop  ',
        'x' * 100,
        '👨‍👩‍👧' * 70,
        'jdoe${'á' * 200}',
      ]) {
        final once = normalizeDeviceName(raw);
        expect(normalizeDeviceName(once), once, reason: raw);
        expect(once!.runes.length, lessThanOrEqualTo(deviceNameMaxCodePoints));
      }
    });

    test('a cut that splits a word drops the dangling space', () {
      expect(normalizeDeviceName('${'a' * 63} and more'), 'a' * 63);
    });
  });

  group('DeviceNames.resolved', () {
    test('this engram\'s name, else the default, else the platform\'s', () {
      const all = DeviceNames(
        engram: 'Work laptop',
        deviceDefault: 'jdoe\'s laptop',
        platform: 'jdoe-desktop',
      );
      expect(all.resolved, 'Work laptop');
      expect(all.withoutEngram, 'jdoe\'s laptop');

      const noEngram = DeviceNames(
        engram: null,
        deviceDefault: 'jdoe\'s laptop',
        platform: 'jdoe-desktop',
      );
      expect(noEngram.resolved, 'jdoe\'s laptop');

      const neither = DeviceNames(
        engram: null,
        deviceDefault: null,
        platform: 'jdoe-desktop',
      );
      expect(neither.resolved, 'jdoe-desktop');
      expect(neither.withoutEngram, 'jdoe-desktop');
    });

    test('equal by value', () {
      const a = DeviceNames(engram: 'x', deviceDefault: null, platform: 'p');
      const b = DeviceNames(engram: 'x', deviceDefault: null, platform: 'p');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a.toString(), contains('x'));
    });
  });

  group('PlatformDeviceName', () {
    const channel = MethodChannel(PlatformDeviceName.channelName);
    final calls = <String>[];

    void answer(Object? Function() reply) {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            return reply();
          });
    }

    tearDown(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    PlatformDeviceName on(String os, {String host = 'jdoe-desktop'}) =>
        PlatformDeviceName(
          operatingSystem: os,
          hostname: () => host,
          channel: channel,
        );

    test('Linux and Windows are their hostname', () async {
      expect(await on('linux').read(), 'jdoe-desktop');
      expect(await on('windows', host: 'JDOE-PC').read(), 'JDOE-PC');
      expect(on('linux').platform, 'linux');
      expect(calls, isEmpty, reason: 'no channel on a desktop');
    });

    test('macOS drops the network\'s .local suffix', () async {
      expect(
        await on('macos', host: 'jdoes-MacBook-Pro.local').read(),
        'jdoes-MacBook-Pro',
      );
      expect(await on('macos', host: 'jdoe-mini.LOCAL').read(), 'jdoe-mini');
      expect(await on('macos', host: 'jdoe-mini').read(), 'jdoe-mini');
    });

    test('Android asks the runner for the phone\'s own name', () async {
      answer(() => 'jdoe\'s Pixel');
      expect(await on('android', host: 'localhost').read(), 'jdoe\'s Pixel');
      expect(calls, ['name']);
    });

    test('iOS asks the runner, which answers the model', () async {
      answer(() => 'iPhone');
      expect(await on('ios').read(), 'iPhone');
    });

    test('a runner that cannot answer falls back to the hostname', () async {
      answer(() => throw PlatformException(code: 'nope'));
      expect(await on('android', host: 'phone').read(), 'phone');

      // No handler at all: the runner predates the channel.
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      expect(await on('ios', host: 'phone').read(), 'phone');

      answer(() => '   ');
      expect(await on('android', host: 'phone').read(), 'phone');
    });

    test('with nothing to go on, the platform\'s own identifier', () async {
      final blank = PlatformDeviceName(
        operatingSystem: 'linux',
        hostname: () => '',
        channel: channel,
      );
      expect(await blank.read(), 'linux');

      final throwing = PlatformDeviceName(
        operatingSystem: 'linux',
        hostname: () => throw const OSError('no hostname'),
        channel: channel,
      );
      expect(await throwing.read(), 'linux');
    });

    test('a long hostname is cut like any name', () async {
      expect(await on('linux', host: 'h' * 100).read(), 'h' * 64);
    });

    test('defaults to the running platform', () async {
      final real = PlatformDeviceName();
      expect(real.platform, isNotEmpty);
      expect(await real.read(), isNotEmpty);
    });
  });
}

class OSError implements Exception {
  const OSError(this.message);
  final String message;
}
