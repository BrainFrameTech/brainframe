import 'package:brainframe/engram/channel_folder_access.dart';
import 'package:brainframe/engram/fs/folder_access.dart';
import 'package:brainframe/engram/path_folder_access.dart';
import 'package:brainframe/engram/platform_folder_access.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The Dart half of the folder-access channel: what goes out, and how each
/// answer and error code comes back as the seam's types. The platform half is
/// exercised on a device (manual test plan F39).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(ChannelFolderAccess.channelName);
  const access = ChannelFolderAccess();
  final calls = <MethodCall>[];

  /// Answers every call with [answer], recording it first.
  void platform(Object? Function(MethodCall call) answer) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return answer(call);
    });
  }

  PlatformException code(String code) =>
      PlatformException(code: code, message: 'native words');

  setUp(calls.clear);

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('can always pick: it is only chosen where the platform can', () {
    expect(access.canPick, isTrue);
  });

  group('pick', () {
    test('a path, with a bookmark where the platform gives one', () async {
      platform((_) => {'path': '/storage/emulated/0/Notes', 'bookmark': 'b'});
      final picked = await access.pick();
      expect(calls.single.method, 'pick');
      expect(picked!.path, '/storage/emulated/0/Notes');
      expect(picked.bookmark, 'b');
    });

    test('and without one', () async {
      platform((_) => {'path': '/p'});
      expect((await access.pick())!.bookmark, isNull);
    });

    test('a cancelled picker is null', () async {
      platform((_) => null);
      expect(await access.pick(), isNull);
    });

    test('notLocal is a FolderNotLocalException, keeping the words', () async {
      platform((_) => throw code('notLocal'));
      await expectLater(
        access.pick(),
        throwsA(
          isA<FolderNotLocalException>().having(
            (e) => e.message,
            'message',
            'native words',
          ),
        ),
      );
    });

    test('any other code is rethrown as it came', () async {
      platform((_) => throw code('noPicker'));
      await expectLater(access.pick(), throwsA(isA<PlatformException>()));
    });
  });

  group('resolve', () {
    test('sends the row, and returns the path with any fresh bookmark',
        () async {
      platform((_) => {'path': '/now', 'refreshedBookmark': 'fresh'});
      final resolved = await access.resolve(path: '/then', bookmark: 'old');
      expect(calls.single.method, 'resolve');
      expect(calls.single.arguments, {'path': '/then', 'bookmark': 'old'});
      expect(resolved.path, '/now');
      expect(resolved.refreshedBookmark, 'fresh');
    });

    test('a row with no bookmark sends null for it', () async {
      platform((call) => {'path': '/p'});
      final resolved = await access.resolve(path: '/p');
      expect(calls.single.arguments, {'path': '/p', 'bookmark': null});
      expect(resolved.refreshedBookmark, isNull);
    });

    for (final (wire, reason) in [
      ('accessNeeded', UnreachableReason.accessNeeded),
      ('bookmarkInvalid', UnreachableReason.bookmarkInvalid),
    ]) {
      test('$wire is a FolderAccessException with that reason', () async {
        platform((_) => throw code(wire));
        await expectLater(
          access.resolve(path: '/p'),
          throwsA(
            isA<FolderAccessException>()
                .having((e) => e.reason, 'reason', reason)
                .having((e) => e.message, 'message', 'native words'),
          ),
        );
      });
    }

    test('any other code is rethrown as it came', () async {
      platform((_) => throw code('badArgs'));
      await expectLater(
        access.resolve(path: '/p'),
        throwsA(isA<PlatformException>()),
      );
    });
  });

  group('broad access', () {
    test('reports and requests what the platform says', () async {
      platform((call) => call.method == 'hasBroadAccess' ? false : true);
      expect(await access.hasBroadAccess, isFalse);
      expect(await access.requestBroadAccess(), isTrue);
      expect(calls.map((c) => c.method), [
        'hasBroadAccess',
        'requestBroadAccess',
      ]);
    });

    test('no answer at all is no access', () async {
      platform((_) => null);
      expect(await access.hasBroadAccess, isFalse);
      expect(await access.requestBroadAccess(), isFalse);
    });
  });

  group('platformFolderAccess', () {
    tearDown(() => debugDefaultTargetPlatformOverride = null);

    test('is the channel on Android', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(platformFolderAccess(), isA<ChannelFolderAccess>());
    });

    test('is plain paths everywhere else, for now', () {
      for (final platform in [
        TargetPlatform.linux,
        TargetPlatform.windows,
        TargetPlatform.macOS,
        TargetPlatform.iOS,
      ]) {
        debugDefaultTargetPlatformOverride = platform;
        expect(platformFolderAccess(), isA<PathFolderAccess>(),
            reason: '$platform');
      }
    });
  });

  test('FolderNotLocalException names its words, when it has them', () {
    expect(const FolderNotLocalException().toString(),
        'FolderNotLocalException');
    expect(const FolderNotLocalException('x').toString(),
        'FolderNotLocalException(x)');
  });
}
