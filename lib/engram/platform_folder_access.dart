import 'package:flutter/foundation.dart';

import 'channel_folder_access.dart';
import 'fs/folder_access.dart';
import 'path_folder_access.dart';

/// The [FolderAccess] this platform uses (the sandboxed folder adoption
/// design, Decision 2): the app's own channel on Android, plain paths
/// everywhere else.
///
/// iOS reports false from [FolderAccess.canPick] here until its channel is
/// built, which keeps "Open folder…" hidden there, as before. macOS stays on
/// plain paths until then too, and moves to the channel along with iOS.
FolderAccess platformFolderAccess() =>
    defaultTargetPlatform == TargetPlatform.android
    ? const ChannelFolderAccess()
    : const PathFolderAccess();
