import '../crdt/catalog.dart';
import '../engram_store.dart';

/// What adopting a folder would do, told before it is done.
///
/// Pure value, no `dart:io`; the counting is [countCrlfTextFiles], over any
/// store. The desktop adoption flow shows this in its confirmation, because
/// adopting writes into a folder the user already owns — a `.brainframe/`
/// marker now, an identity-map file once the scan runs, and every text file
/// with Windows line endings rewritten LF in one sweep — and turns every
/// content file into a note. A folder under version control notices all of
/// it, and the user should hear it from the app first, with the numbers.
class FolderAdoptionPreview {
  const FolderAdoptionPreview({
    required this.path,
    required this.name,
    required this.fileCount,
    required this.crlfCount,
    required this.isEngram,
  });

  /// Absolute path of the folder.
  final String path;

  /// The folder's own name, which becomes the engram's display name.
  final String name;

  /// Content files that would become notes: everything the scan admits, so
  /// nothing hidden and nothing under the marker.
  final int fileCount;

  /// Of [fileCount], the text notes whose terminators are not LF and which
  /// adoption will therefore rewrite (Decision 10). Blobs are never counted:
  /// their bytes are never touched.
  final int crlfCount;

  /// Whether the folder already carries a marker. An existing engram is
  /// opened, not adopted, and needs no confirmation: nothing new is written.
  final bool isEngram;
}

/// The last segment of [path], with a trailing separator ignored: the name
/// the preview reports and the dialog shows while the pass is still running.
String folderNameOf(String path) {
  final trimmed = path.replaceAll(r'\', '/').replaceAll(RegExp(r'/+$'), '');
  final slash = trimmed.lastIndexOf('/');
  return slash == -1 ? trimmed : trimmed.substring(slash + 1);
}

/// Told how far a preview's pass over a folder's files has come: [done] of
/// [total] files looked at. The first call carries `done == 0` and the total,
/// so a caller that had nothing to show while the folder was being listed can
/// switch to a count; the last carries `done == total`.
typedef FolderPreviewProgress = void Function(int done, int total);

/// Asked between files whether to stop. A pass that is told to stop returns
/// what it has counted so far; the caller that asked knows to discard it.
typedef FolderPreviewCancelled = bool Function();

/// How many of [paths] are text notes with a carriage return in them — the
/// ones adoption will rewrite LF (Decision 10) — counted over [store]
/// without ever holding a file whole.
///
/// A blob is never read: only a `fugueText` path is opened, and it is read as
/// a stream and left at the first `\r`. The answer per file is a boolean, so
/// the common CRLF file is decided in its first chunk and an LF file costs one
/// pass. A folder being adopted is precisely one this app has never seen, and
/// a 500 MB log with a `.txt` extension must not be loaded on a Pi before the
/// user has even confirmed.
///
/// Every path is one step of [onProgress], a blob's step costing nothing;
/// [isCancelled] is consulted between files. Both are optional, and the
/// desktop flow passes neither yet: the seam exists so the dialog that shows
/// this pass can be built on it (#168) without reshaping the loop.
Future<int> countCrlfTextFiles(
  EngramStore store,
  List<String> paths, {
  FolderPreviewProgress? onProgress,
  FolderPreviewCancelled? isCancelled,
}) async {
  var crlf = 0;
  var done = 0;
  onProgress?.call(done, paths.length);
  for (final path in paths) {
    if (isCancelled?.call() ?? false) break;
    if (mergePolicyForPath(path) == MergePolicy.fugueText &&
        await hasCarriageReturn(store.openRead(path))) {
      crlf++;
    }
    onProgress?.call(++done, paths.length);
  }
  return crlf;
}

/// Whether [chunks] contain a carriage return, stopping at the first one.
/// Returning from inside the loop cancels the subscription, so a file whose
/// first chunk answers the question is never read past it.
Future<bool> hasCarriageReturn(Stream<List<int>> chunks) async {
  await for (final chunk in chunks) {
    if (chunk.contains(_carriageReturn)) return true;
  }
  return false;
}

const int _carriageReturn = 0x0d;
