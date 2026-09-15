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

/// Runs the preview of a picked folder — [previewFolderAdoption] over its
/// location — told each file as it is looked at and asked between files
/// whether to stop. Injected into [FolderPreviewing] so the dialog can be
/// driven in a test without a folder.
typedef FolderPreviewer = Future<FolderAdoptionPreview> Function({
  FolderPreviewProgress? onProgress,
  FolderPreviewCancelled? isCancelled,
});

/// A folder being looked at before adoption is asked (#168): its name, how
/// far the pass has come, the preview when it ends, and a way to stop it.
///
/// The pass starts the moment this is made. Between the native dialog closing
/// and the counts being in, a large folder — thousands of files, a recursive
/// listing and then every text file streamed for a carriage return — is long
/// enough to look hung, so the UI is handed this at once, shows the folder's
/// name and the count as it advances, and offers Cancel, rather than being
/// handed the finished preview after a silence.
class FolderPreviewing {
  FolderPreviewing({required this.name, required FolderPreviewer run}) {
    _preview = run(
      onProgress: (done, total) =>
          _progress.value = (done: done, total: total),
      isCancelled: () => _cancelled,
    );
  }

  /// The folder's own name, known before anything else is.
  final String name;

  final ValueNotifier<({int done, int total})?> _progress = ValueNotifier(
    null,
  );
  late final Future<FolderAdoptionPreview> _preview;
  bool _cancelled = false;

  /// Files looked at so far, of the total — or null while the folder is
  /// still being listed and there is no total to show. The first value has
  /// `done == 0`, the last `done == total`.
  ValueListenable<({int done, int total})?> get progress => _progress;

  /// The preview, once the pass ends. A cancelled pass ends early with what
  /// it had counted; [cancelled] says so, and the numbers are not to be
  /// shown.
  Future<FolderAdoptionPreview> get preview => _preview;

  /// Whether [cancel] was called. The pass stops at the next file.
  bool get cancelled => _cancelled;

  /// Stops the pass at the next file. Adoption never proceeds after this,
  /// whatever the confirmer answers.
  void cancel() => _cancelled = true;
}

/// Shows the folder being looked at, then asks whether to go ahead with
/// adopting it once [FolderPreviewing.preview] is in. Returns false to leave
/// the folder untouched.
///
/// Adoption writes into a folder the user already owns — the marker now, the
/// identity map once the scan runs — and turns every content file into a
/// note, and that is asked before it is done. An existing engram is opened as
/// it is, with nothing new written, so nothing needs asking: a confirmer
/// answers true for a preview that says `isEngram` without putting a
/// question.
typedef AdoptionConfirmer = Future<bool> Function(FolderPreviewing previewing);

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
/// [confirm] is shown the folder as it is looked at and asked before it is
/// adopted; with none, adoption proceeds unasked, which is right for a caller
/// that has already asked in its own way and wrong for a UI.
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
    final previewing = FolderPreviewing(
      name: folderNameOf(path),
      run: ({onProgress, isCancelled}) => previewFolderAdoption(
        location,
        onProgress: onProgress,
        isCancelled: isCancelled,
      ),
    );
    final adopt = await confirm(previewing);
    // A cancelled pass is a declined adoption whatever was answered: the
    // preview it ended with is partial and was never shown.
    if (!adopt || previewing.cancelled) {
      // Declined, perhaps before the pass ended: stop it here, whether or
      // not the confirmer did, and wait for it to stop — so when this
      // returns nothing is still walking the folder behind a decision
      // already made. What the pass ends with is unused, and so is how it
      // ends: a file gone from under a walk that was being stopped anyway
      // is nobody's error.
      previewing.cancel();
      await previewing.preview.then<void>((_) {}, onError: (_) {});
      return null;
    }
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
