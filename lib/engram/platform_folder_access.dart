import 'package:flutter/foundation.dart';

import 'channel_folder_access.dart';
import 'fs/folder_access.dart';
import 'path_folder_access.dart';

/// The [FolderAccess] this platform uses (the sandboxed folder adoption
/// design, Decision 2): the app's own channel on the sandboxed platforms —
/// Android, iOS, macOS — and plain paths on Linux and Windows.
FolderAccess platformFolderAccess() => switch (defaultTargetPlatform) {
  TargetPlatform.android ||
  TargetPlatform.iOS ||
  TargetPlatform.macOS => const ChannelFolderAccess(),
  _ => const PathFolderAccess(),
};
