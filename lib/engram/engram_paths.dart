/// What counts as engram content: the one predicate the file browser and the
/// scan must agree on.
///
/// It lived in the browser until step 11 moved it here, because it was never
/// UI logic — it is the definition of which paths are notes. The scan
/// enumerates only the paths it admits. Without that, a scan walks every
/// dot-directory in the folder and treats each file inside as a note, and the
/// identity map then carries those notes to every other device, so the
/// mistake outlives the `metadata.db` that made it. A checkout of notes under
/// version control and an Obsidian vault are the two folders a real user
/// adopts, and both hold exactly such a directory.
library;

/// Whether [path] is hidden from the file browser and ignored by the scan:
/// true when any of its segments begins with a dot — a dotfile (`.DS_Store`),
/// or anything inside a dot-directory (`.git/config`, the app's own
/// `.brainframe/…`). Matches the usual hidden-file convention.
bool isHiddenEngramPath(String path) =>
    path.split('/').any((segment) => segment.startsWith('.'));
