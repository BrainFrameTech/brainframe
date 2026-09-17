/// Where one engram's device-local store lives, given the app-data root —
/// and the two things done to that directory as a whole.
///
/// Pure `dart:io`: no `path_provider`, no Flutter. The root itself is
/// *handed in* as an [AppDataRootResolver], never looked up here, and that
/// is the whole reason this file exists apart from
/// [app_data_resolver_io.dart](app_data_resolver_io.dart). `path_provider`
/// is a Flutter plugin whose import chain reaches `dart:ui`, so anything that
/// imports it can be compiled only by the Flutter tool. The store, the
/// op-log, the reconciler, and the identity map need only to be told a
/// directory; taking the resolver as a required argument keeps every one of
/// them reachable from a plain `dart run` — a maintenance script, a
/// benchmark, the monitor CLI — while the app, which does know the platform,
/// supplies the platform's answer at its own edge.
library;

import 'dart:io';

import '../id.dart';
import 'app_data_source.dart';

/// The directory holding the engram [engramId]'s device-local store —
/// `<app data root>/engrams/<engram ULID>/`, where `metadata.db` goes.
///
/// **The engram ULID names the directory and appears nowhere inside the
/// database.** That is what makes a changed engram ULID — which a future sync
/// election can produce, since two devices that adopt one folder before
/// syncing each mint their own — a directory rename and nothing more: every
/// byte inside is already correct. Nothing should later key a table on it.
///
/// Throws [ArgumentError] unless [engramId] is a canonical ULID, so a display
/// name or a relative path can never become a directory component here.
Future<String> engramStorePath(
  String engramId, {
  required AppDataRootResolver resolveRoot,
}) async {
  if (!isCanonicalUlid(engramId)) {
    throw ArgumentError.value(engramId, 'engramId', 'must be a canonical ULID');
  }
  final root = await resolveRoot();
  return '$root/$engramsDirectoryName/$engramId';
}

/// Writes `path.txt` in the engram [engramId]'s device-local store directory,
/// naming [folderPath] — the absolute path of the engram folder — on one
/// line. See [engramPathFileName] for what it is for.
///
/// Rewritten whole on every call, so a store whose folder moved is relabelled
/// the next time the engram opens. The directory is created if it is not
/// there yet, so the order of this and the database open does not matter.
Future<void> recordEngramPath(
  String engramId,
  String folderPath, {
  required AppDataRootResolver resolveRoot,
}) async {
  final directory = await engramStorePath(engramId, resolveRoot: resolveRoot);
  await Directory(directory).create(recursive: true);
  await File('$directory/$engramPathFileName').writeAsString('$folderPath\n');
}

/// Deletes the engram [engramId]'s device-local store directory — `metadata.db`
/// and anything beside it — and returns whether there was one to delete.
///
/// Absence is success, not failure: a store that was never opened on this
/// device, or one already removed by an earlier attempt, both leave nothing
/// to do. The other half of a clean-up, the marker directory inside the
/// folder, lives behind the filesystem store seam.
///
/// The directory is resolved through [engramStorePath], so the same ULID check
/// guards it: nothing but a canonical engram ULID can name what is deleted
/// here. **Never call this for an open engram:** its `metadata.db` is a live
/// SQLite connection, which on Windows refuses the delete and everywhere else
/// leaves the session writing into an unlinked file.
Future<bool> deleteEngramStore(
  String engramId, {
  required AppDataRootResolver resolveRoot,
}) async {
  final directory = Directory(
    await engramStorePath(engramId, resolveRoot: resolveRoot),
  );
  if (!await directory.exists()) return false;
  await directory.delete(recursive: true);
  return true;
}
