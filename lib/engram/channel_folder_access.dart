/// [FolderAccess] over the app's own platform channel,
/// `tech.brainframe.app/folder_access` (the sandboxed folder adoption design,
/// Decision 2).
///
/// This side only maps: method calls out, results and error codes back into
/// the seam's types. What each platform does to answer lives beside it —
/// `FolderAccessChannel.kt` on Android (the All files access permission, the
/// system folder picker, the tree-URI-to-path mapping of Decision 4); a
/// `FolderAccessChannel` class in `ios/Runner/AppDelegate.swift` and
/// `macos/Runner/MainFlutterWindow.swift` on the Apple platforms (the document
/// picker or open panel, and the security-scoped bookmark of Decision 5). The
/// Apple halves are written but not yet run on hardware.
///
/// ## The channel's contract
///
/// | Method | Arguments | Result | Error codes |
/// | --- | --- | --- | --- |
/// | `pick` | — | `{path, bookmark?}`, or null on cancel | `notLocal` |
/// | `resolve` | `{path, bookmark?}` | `{path, refreshedBookmark?}` | `accessNeeded`, `bookmarkInvalid` |
/// | `hasBroadAccess` | — | bool | — |
/// | `requestBroadAccess` | — | bool, whether granted afterwards | — |
///
/// An error code the contract does not name is rethrown as the
/// [PlatformException] it arrived as; discovery reports such a row as missing.
library;

import 'package:flutter/services.dart';

import 'fs/folder_access.dart';

class ChannelFolderAccess extends FolderAccess {
  /// [channel] replaces the app's own; tests pass one to mock.
  const ChannelFolderAccess({this._channel = const MethodChannel(channelName)});

  /// The channel's name, shared with the platform side.
  static const String channelName = 'tech.brainframe.app/folder_access';

  final MethodChannel _channel;

  /// Always true: this implementation is only chosen where the platform side
  /// has a chooser to answer with.
  @override
  bool get canPick => true;

  @override
  Future<PickedFolder?> pick() async {
    try {
      final result = await _channel.invokeMapMethod<String, Object?>('pick');
      if (result == null) return null;
      return PickedFolder(
        result['path']! as String,
        bookmark: result['bookmark'] as String?,
      );
    } on PlatformException catch (error) {
      if (error.code == 'notLocal') {
        throw FolderNotLocalException(error.message);
      }
      rethrow;
    }
  }

  @override
  Future<ResolvedFolder> resolve({
    required String path,
    String? bookmark,
  }) async {
    try {
      final result = await _channel.invokeMapMethod<String, Object?>(
        'resolve',
        {'path': path, 'bookmark': bookmark},
      );
      return ResolvedFolder(
        result!['path']! as String,
        refreshedBookmark: result['refreshedBookmark'] as String?,
      );
    } on PlatformException catch (error) {
      final reason = switch (error.code) {
        'accessNeeded' => UnreachableReason.accessNeeded,
        'bookmarkInvalid' => UnreachableReason.bookmarkInvalid,
        _ => null,
      };
      if (reason == null) rethrow;
      throw FolderAccessException(reason, error.message);
    }
  }

  @override
  Future<bool> get hasBroadAccess async =>
      await _channel.invokeMethod<bool>('hasBroadAccess') ?? false;

  @override
  Future<bool> requestBroadAccess() async =>
      await _channel.invokeMethod<bool>('requestBroadAccess') ?? false;
}
