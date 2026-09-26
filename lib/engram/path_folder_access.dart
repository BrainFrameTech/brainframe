/// [FolderAccess] where a picked path stays good on its own: Linux and
/// Windows, and — until its bookmark channel lands — macOS (the sandboxed
/// folder adoption design, Decision 2).
///
/// The desktop dialog returns a plain `dart:io` path, and nothing more is
/// needed to reach it in a later launch, so there is no bookmark, no
/// permission, and resolving a row is the identity. Android and iOS report
/// [canPick] false here; their chooser is a platform channel of its own.
library;

import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:flutter/foundation.dart';

import 'fs/folder_access.dart';

/// Chooses a directory and returns its absolute path, or null if the user
/// cancels. Injected so tests can drive adoption without a native dialog.
typedef DirectoryPicker = Future<String?> Function();

class PathFolderAccess extends FolderAccess {
  /// [picker] replaces the native dialog; tests pass one.
  const PathFolderAccess({this._picker});

  final DirectoryPicker? _picker;

  /// True on the desktop targets, whose native dialog returns a plain path.
  @override
  bool get canPick =>
      defaultTargetPlatform == TargetPlatform.windows ||
      defaultTargetPlatform == TargetPlatform.linux ||
      defaultTargetPlatform == TargetPlatform.macOS;

  @override
  Future<PickedFolder?> pick() async {
    final path = await (_picker ?? _pickDirectoryPath)();
    return path == null ? null : PickedFolder(path);
  }

  @override
  Future<ResolvedFolder> resolve({
    required String path,
    String? bookmark,
  }) async => ResolvedFolder(path);

  @override
  Future<bool> get hasBroadAccess async => true;

  @override
  Future<bool> requestBroadAccess() async => true;
}

/// The real native directory dialog. Isolated so it is the sole line the unit
/// tests cannot exercise (it needs a platform channel).
///
/// Uses `file_selector` (the maintained, built-in-Kotlin plugin) rather than
/// `file_picker`, whose legacy Kotlin-Gradle-Plugin apply broke the Android
/// build even though the picker itself is desktop-only.
Future<String?> _pickDirectoryPath() => file_selector.getDirectoryPath(
      confirmButtonText: 'Choose folder',
    );
