/// What adopting a folder would do, told before it is done.
///
/// Pure value, no `dart:io`: the counting lives with the store. The desktop
/// adoption flow shows this in its confirmation, because adopting writes into
/// a folder the user already owns — a `.brainframe/` marker now, an
/// identity-map file once the scan runs — and turns every content file into a
/// note. A folder under version control notices both, and the user should
/// hear it from the app first.
class FolderAdoptionPreview {
  const FolderAdoptionPreview({
    required this.path,
    required this.name,
    required this.fileCount,
    required this.isEngram,
  });

  /// Absolute path of the folder.
  final String path;

  /// The folder's own name, which becomes the engram's display name.
  final String name;

  /// Content files that would become notes: everything the scan admits, so
  /// nothing hidden and nothing under the marker.
  final int fileCount;

  /// Whether the folder already carries a marker. An existing engram is
  /// opened, not adopted, and needs no confirmation: nothing new is written.
  final bool isEngram;
}
