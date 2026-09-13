/// What adopting a folder would do, told before it is done.
///
/// Pure value, no `dart:io`: the counting lives with the store. The desktop
/// adoption flow shows this in its confirmation, because adopting writes into
/// a folder the user already owns — a `.brainframe/` marker now, an
/// identity-map file once the scan runs, and every text file with Windows
/// line endings rewritten LF in one sweep — and turns every content file into
/// a note. A folder under version control notices all of it, and the user
/// should hear it from the app first, with the numbers.
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
