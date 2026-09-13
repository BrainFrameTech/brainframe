/// The desktop "choose any folder" flow: open a native directory dialog, then
/// adopt whatever the user picks as an engram (Step 6 of the storage plan).
///
/// This is deliberately desktop-only *in v1* — not because the other platforms
/// can't choose a directory, but because of what their choosers hand back. The
/// desktop dialog returns a plain `dart:io` path, exactly what
/// [FileSystemEngramStore] and the registry's plain-path token consume. Android
/// (Storage Access Framework) and iOS (`UIDocumentPickerViewController`) can
/// pick a folder too, but yield a scoped `content://` URI or a security-scoped
/// URL that must be re-resolved from a persisted bookmark each launch — a
/// different [EngramLocation] access kind that the design defers to v2
/// ("sandboxed-platform folder picking and iCloud"). The Raspberry Pi
/// (flutter-pi) has no native dialog at all, so its pick-any-folder path is a
/// small in-app directory browser deferred to the Pi-usability work. Guarding
/// to desktop scopes this to the case v1's storage model actually supports; the
/// injectable dialog keeps the only untestable line (the real plugin call) to a
/// hair.
library;

import 'package:file_selector/file_selector.dart' as file_selector;
import 'package:flutter/foundation.dart';

import 'engram.dart';
import 'engram_repository.dart';
import 'fs/fs_store.dart';

/// Chooses a directory and returns its absolute path, or null if the user
/// cancels. Injected so tests can drive adoption without a native dialog.
typedef DirectoryPicker = Future<String?> Function();

/// Asks whether to go ahead with adopting the folder [preview] describes.
/// Returns false to leave the folder untouched.
///
/// Called only for a folder that is not an engram yet: adoption writes into a
/// folder the user already owns — the marker now, the identity map once the
/// scan runs — and turns every content file into a note, and that is asked
/// before it is done. An existing engram is opened as it is, with nothing
/// new written, so nothing needs asking.
typedef AdoptionConfirmer = Future<bool> Function(FolderAdoptionPreview preview);

/// Whether the pick-any-folder flow is available on this platform in v1.
///
/// True only on the desktop targets, whose native dialog returns a plain
/// filesystem path. Mobile's scoped-URI pickers and the Pi's in-app browser are
/// later work (see the library doc), so they report false here.
bool get isDesktopFolderAdoptionSupported =>
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.linux ||
    defaultTargetPlatform == TargetPlatform.macOS;

/// Prompts for a folder and adopts it into [repository] as a registry root.
///
/// Returns the adopted [Engram], or null if the user cancels the dialog. A
/// picked folder that is already an engram is opened and keeps its identity; a
/// plain folder is turned into one in place (see [EngramRepository.adoptFolder]).
///
/// Throws [UnsupportedError] off the desktop targets — callers should only wire
/// this in where [isDesktopFolderAdoptionSupported] is true. Pass [picker] to
/// supply a directory chooser (tests do); it defaults to the native dialog.
/// [confirm] is asked before a folder that is not yet an engram is adopted;
/// with none, adoption proceeds unasked, which is right for a caller that has
/// already asked in its own way and wrong for a UI.
Future<Engram?> pickAndAdoptFolder(
  EngramRepository repository, {
  DirectoryPicker? picker,
  AdoptionConfirmer? confirm,
}) async {
  if (!isDesktopFolderAdoptionSupported) {
    throw UnsupportedError(
      'Choosing a folder is only available on desktop platforms.',
    );
  }
  final path = await (picker ?? _pickDirectoryPath)();
  if (path == null) return null; // the user dismissed the dialog
  final location = EngramLocation(path);
  if (confirm != null) {
    final preview = await previewFolderAdoption(location);
    if (!preview.isEngram && !await confirm(preview)) return null;
  }
  return repository.adoptFolder(location);
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
