/// Which `path_provider` directory holds this device's app-owned engram data.
///
/// Split out from `app_data_resolver.dart` because it is a pure decision over
/// a platform name: no `dart:io`, no `path_provider`, and therefore safe to
/// import anywhere. The resolver's job is to act on this answer; this file's
/// job is to be the one place the answer is written down and tested.
library;

/// The `path_provider` call an app-data root is read from.
enum AppDataSource {
  /// `getApplicationSupportDirectory()`.
  applicationSupport,

  /// `getApplicationCacheDirectory()`.
  applicationCache,
}

/// The directory under the app-data root that holds every engram's
/// device-local store, one subdirectory per engram ULID.
const String engramsDirectoryName = 'engrams';

/// The database file inside an engram's store directory.
///
/// `metadata.db` rather than a narrower name like `catalog.db`: the catalog is
/// the first tenant, not the only one. Per-engram state that is device-local
/// and not user content — scan state, later the search and graph indexes —
/// belongs in the same file, and a name describing only the first table leaves
/// the next reader wondering whether they are in the right place.
const String metadataDatabaseFileName = 'metadata.db';

/// The [AppDataSource] for [operatingSystem], a `Platform.operatingSystem`
/// value (`linux`, `macos`, `windows`, `android`, `ios`, `fuchsia`).
///
/// Everything except Windows reads its app-data root from
/// `getApplicationSupportDirectory()`.
///
/// **Windows takes `getApplicationCacheDirectory()` on purpose**, and the
/// call's name is an abstraction leak rather than a claim that the contents
/// are disposable. On Windows `getApplicationSupportDirectory()` maps to
/// **`RoamingAppData`**, and a roaming profile is copied between machines at
/// logon and logoff — which means a live database copied out from under its
/// writer, and an op-log silently inflating a profile users already complain
/// is slow. `getApplicationCacheDirectory()` is the only `path_provider` call
/// that reaches the non-roaming `LocalAppData`.
///
/// **The same call must never be reused on Linux**, where it resolves to
/// `$XDG_CACHE_HOME` and invites a disk cleaner to delete history mid-session.
/// An op-log is not derived from anything and cannot be rebuilt by rescanning,
/// so it belongs under `$XDG_DATA_HOME` — which is what
/// `getApplicationSupportDirectory()` gives.
///
/// The Raspberry Pi reports `linux` and would land on the same answer; it is
/// expected to override the root entirely instead, since its library lives on
/// a separate mounted volume whose path comes from configuration.
///
/// This function exists so that both halves of that reasoning are pinned by a
/// test. Nothing else stops an upstream change — or a well-meaning cleanup
/// that "fixes" the odd-looking Windows call — from moving an op-log into a
/// roaming profile or a cache directory.
AppDataSource appDataSourceFor(String operatingSystem) =>
    operatingSystem == 'windows'
    ? AppDataSource.applicationCache
    : AppDataSource.applicationSupport;
