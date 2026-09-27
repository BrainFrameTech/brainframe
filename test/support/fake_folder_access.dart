import 'package:brainframe/engram/fs/folder_access.dart';

/// A [FolderAccess] a test scripts: what [pick] returns, how each stored row
/// resolves, and whether broad access is held — so the Android and Apple
/// paths through the repository run without a device.
class FakeFolderAccess extends FolderAccess {
  FakeFolderAccess({
    this.picked,
    this.canPick = true,
    this.broadAccess = true,
    this._onResolve,
  });

  /// What [pick] returns; null plays a cancelled chooser.
  PickedFolder? picked;

  /// Thrown by [pick] instead of returning, when set — a
  /// [FolderNotLocalException], say.
  Object? pickError;

  /// How many times [pick] was called.
  int picks = 0;

  /// How many times [requestBroadAccess] was called.
  int requests = 0;

  /// Thrown by [requestBroadAccess] instead of answering, when set.
  Object? requestError;

  /// What [requestBroadAccess] leaves [broadAccess] as: true plays the user
  /// granting it, false turning it down.
  bool grants = true;

  @override
  final bool canPick;

  /// What [hasBroadAccess] reports; [requestBroadAccess] sets it to [grants].
  bool broadAccess;

  /// How a row resolves; throw [FolderAccessException] from it to refuse.
  /// Resolves every row to its own path when null.
  final ResolvedFolder Function(String path, String? bookmark)? _onResolve;

  /// Every row asked about, in order.
  final List<({String path, String? bookmark})> resolved = [];

  @override
  Future<PickedFolder?> pick() async {
    picks++;
    if (pickError case final error?) throw error;
    return picked;
  }

  @override
  Future<ResolvedFolder> resolve({
    required String path,
    String? bookmark,
  }) async {
    resolved.add((path: path, bookmark: bookmark));
    return _onResolve?.call(path, bookmark) ?? ResolvedFolder(path);
  }

  @override
  Future<bool> get hasBroadAccess async => broadAccess;

  @override
  Future<bool> requestBroadAccess() async {
    requests++;
    if (requestError case final error?) throw error;
    return broadAccess = grants;
  }
}
