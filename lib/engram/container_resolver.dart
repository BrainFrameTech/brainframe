import 'fs/fs_store.dart';

/// Picks the engram container for this session: the user's real one, or an
/// empty throwaway when the session must not see it.
///
/// Discovery has two sources and only one of them is preferences — it also
/// scans the container directly (see `EngramRepository.discover`). So
/// `--ignore-config` cannot be honored by neutering `shared_preferences`
/// alone: pointed at the real container, an "ignore everything saved" session
/// still lists every engram in the user's documents directory, private ones
/// included, in the switcher and in any screenshot of it.
///
/// This lives here, rather than inline at the call site in `main.dart`, so the
/// choice is covered by tests — `main.dart` is excluded from the coverage
/// gate as untestable bootstrap, and a regression here is a disclosure.
Future<String> Function() engramContainerResolver({
  required bool ignoreConfig,
}) => ignoreConfig
    ? ephemeralEngramContainerPath
    : applicationEngramContainerPath;
