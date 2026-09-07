/// Detecting that a note's file changed without us (Decision 5).
///
/// Pure Dart: hashing and three comparisons, no filesystem. The `dart:io` half
/// — reading the file's size and modification time — lives in
/// [materializer_io.dart](materializer_io.dart) beside the writer whose output
/// these values describe.
///
/// **Everything here is device-local and must never be shared.** The hash
/// records what *this device's* materializer last wrote, not a property of the
/// note, and two devices legitimately hold different values at the same
/// instant. Decision 5 works the failure through: a device that trusts another
/// device's hash concludes there is no drift, never reconciles the edit it
/// cannot see, and later writes over it. The size and mtime beside the hash
/// describe the same last write and carry the same rule.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../engram_store.dart';
import 'catalog.dart';

/// Hash of the exact bytes the materializer wrote, as lowercase hex.
///
/// SHA-256 because this is a change detector rather than a checksum: it decides
/// whether to reconcile, and a collision would silently skip a real edit. The
/// cost is irrelevant next to the file read it follows.
String contentHash(Uint8List bytes) => sha256.convert(bytes).toString();

/// Hash of [text] as UTF-8, which is how notes are written.
String contentHashOfString(String text) =>
    contentHash(Uint8List.fromList(utf8.encode(text)));

/// Whether [current] *might* differ from what this device last wrote — the
/// cheap pre-filter that decides whether hashing is worth it.
///
/// **It can only ever say "maybe", never "yes".** That asymmetry is the whole
/// point, and it is why this returns a bare "keep looking" rather than a
/// verdict: Decision 5 requires the pre-filter never be the sole test, because
/// same-size same-second edits are trivially achievable by a script, and a
/// filesystem with coarse timestamp granularity produces them by accident. A
/// caller that treats `false` as "unchanged" is correct; one that treats `true`
/// as "changed" has skipped [hasDrifted] and is wrong.
///
/// Returns `true` whenever anything is unknown — a row this device has never
/// materialized, or a stat that could not be read — so missing information
/// costs a hash rather than a missed edit.
bool mayHaveDrifted(CatalogRow row, FileFingerprint? current) {
  if (current == null) return true;
  if (row.materializedHash == null) return true;
  if (row.size == null || row.mtimeUtc == null) return true;

  // Both halves named, because the file is ruled out only when *neither*
  // changed and a reader has to be able to see both being asked. An edit that
  // replaces one word with another of the same length moves only the second
  // one, and it is the whole reason size alone will not do.
  final sizeChanged = row.size != current.size;
  final mtimeChanged = !_sameInstantAtCatalogResolution(
    row.mtimeUtc!,
    current.mtimeUtc,
  );
  return sizeChanged || mtimeChanged;
}

/// Compares two instants at the resolution the catalog can actually store.
///
/// `mtime_utc` is an INTEGER of milliseconds since the epoch, while a
/// filesystem reports microseconds. Comparing the two directly means a
/// round-tripped mtime never equals a fresh stat, so the pre-filter can never
/// rule a file out and silently degrades into "always hash" — an optimization
/// that looks present and does nothing. Truncating both sides is what makes it
/// work at all.
///
/// The resolution loss is safe in the one direction that matters. It can only
/// make the pre-filter *more* willing to rule a file out, and the case that
/// requires — a real edit of identical size landing in the same millisecond as
/// our own last write — is already indistinguishable to a catalog that stores
/// milliseconds. The hash remains the only thing that decides.
bool _sameInstantAtCatalogResolution(DateTime a, DateTime b) =>
    a.millisecondsSinceEpoch == b.millisecondsSinceEpoch;

/// Whether the file's content differs from what this device last wrote.
///
/// This is the real test, and the only one that decides. A row with no
/// [CatalogRow.materializedHash] has never been materialized by this device,
/// which counts as drift: there is no output of ours for the file to match.
bool hasDrifted(CatalogRow row, String currentHash) =>
    row.materializedHash != currentHash;
