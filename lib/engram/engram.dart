import 'engram_store.dart';

/// One engram: its identity plus the [store] its content is reached through.
///
/// [readOnly] is a property of the engram, not of the store — the built-in
/// tutorial and help engrams are read-only while user engrams are not, so
/// screens read this flag to hide create/edit/delete affordances. [id] is a
/// stable ULID (see `id.dart`) that survives folder renames; [displayName] is
/// a mutable convenience shown in the picker.
class Engram {
  const Engram({
    required this.id,
    required this.displayName,
    required this.readOnly,
    required this.store,
  });

  /// Stable ULID; the registry and cross-references key on this, not the name.
  final String id;

  /// Human-facing label (the folder name for a filesystem engram).
  final String displayName;

  /// Whether the engram forbids writes; carried here, not asked of [store].
  final bool readOnly;

  /// The content-access seam this engram is reached through.
  final EngramStore store;

  /// A copy of this engram carrying [displayName] instead — the in-memory half
  /// of a rename, over the same [store] and the same [id].
  ///
  /// The name is a label, not identity: everything that cross-references an
  /// engram keys on [id], so renaming changes what is shown and nothing else.
  Engram withDisplayName(String displayName) => Engram(
    id: id,
    displayName: displayName,
    readOnly: readOnly,
    store: store,
  );

  @override
  String toString() =>
      'Engram(id: $id, displayName: $displayName, readOnly: $readOnly)';
}
