/// The "choose any folder" flow: ask the platform for a folder, then adopt
/// whatever the user picks as an engram (Step 6 of the storage plan).
///
/// Which platforms can, and how the picked folder is reached again, is the
/// [FolderAccess] handed in — by default the repository's own. On Linux and
/// Windows that is a dialog returning a plain path ([PathFolderAccess]).
/// Android, iOS and macOS come through the app's own platform channel
/// ([ChannelFolderAccess]), which hands back a path too — once All files
/// access is granted on Android, and with a bookmark to reach it again on the
/// Apple platforms (the sandboxed folder adoption design). The Raspberry Pi
/// (flutter-pi) has no native dialog, so its pick-any-folder path is a small
/// in-app directory browser deferred to the Pi-usability work.
library;

import 'package:flutter/foundation.dart';

import 'engram.dart';
import 'engram_repository.dart';
import 'fs/folder_access.dart';
import 'fs/fs_store.dart';

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

/// Says why the app needs access to folders outside its own storage, before
/// the platform asks for it, and answers whether to go on and ask.
typedef AccessExplainer = Future<bool> Function();

/// Prompts for a folder and adopts it into [repository] as a registry root.
///
/// Returns the adopted [Engram], or null if the user cancels the dialog. A
/// picked folder that is already an engram is opened and keeps its identity; a
/// plain folder is turned into one in place (see [EngramRepository.adoptFolder]).
///
/// The folder is chosen and reached through [access], which defaults to the
/// repository's own [EngramRepository.folderAccess]; its bookmark, if the
/// platform gives one, is stored with the row. Throws [UnsupportedError] where
/// [FolderAccess.canPick] is false — callers should only wire this in where it
/// is true.
/// [confirm] is shown the folder as it is looked at and asked before it is
/// adopted; with none, adoption proceeds unasked, which is right for a caller
/// that has already asked in its own way and wrong for a UI.
///
/// Where the app lacks the access it needs to read a folder outside its
/// container ([FolderAccess.hasBroadAccess]; Android), that is settled before
/// the chooser opens (Decision 4): [explainAccess] says why it is needed and
/// answers whether to go on, then the platform asks. Declining either, or
/// having no [explainAccess] to ask with, ends the flow with nothing adopted.
/// A chosen folder with no usable path throws [FolderNotLocalException].
Future<Engram?> pickAndAdoptFolder(
  EngramRepository repository, {
  FolderAccess? access,
  AdoptionConfirmer? confirm,
  AccessExplainer? explainAccess,
}) async {
  final folders = access ?? repository.folderAccess;
  if (!folders.canPick) {
    throw UnsupportedError('Choosing a folder is not available here.');
  }
  if (!await folders.hasBroadAccess) {
    if (explainAccess == null || !await explainAccess()) return null;
    if (!await folders.requestBroadAccess()) return null;
  }
  final picked = await folders.pick();
  if (picked == null) return null; // the user dismissed the chooser
  final path = picked.path;
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
  return repository.adoptFolder(location, bookmark: picked.bookmark);
}
