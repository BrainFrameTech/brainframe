/// Where engrams live by default — the two container sources the app can
/// start from — and the one `path_provider` call in the filesystem layer.
///
/// Split out of [fs_store_io.dart](fs_store_io.dart) so that file, and every
/// store built on it, stays free of Flutter plugins. `path_provider`'s import
/// chain reaches `dart:ui`, which only the Flutter tool can compile against;
/// the store itself needs nothing from the platform but a directory it is
/// handed. Keeping the platform's *default* answer here, at the app's edge,
/// is what lets a plain `dart run` open an engram folder and its store.
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// The app documents directory (`path_provider`) — the *default* container
/// that holds engrams as sibling folders on desktop, iOS, and Android.
///
/// This is one container source, not the authority: the repository (Step 5)
/// takes the container as an injected value so it can be overridden per
/// platform. The Raspberry Pi in particular does not use this — its library is
/// expected to live on a separate mounted volume (a secondary SD card) whose
/// path comes from configuration, which `path_provider` cannot report. On a
/// headless Linux box without XDG user-dirs configured, `path_provider` throws
/// [MissingPlatformDirectoryException] rather than returning a path; the
/// container resolver, not this thin wrapper, is where that case is handled.
Future<String> applicationEngramContainerPath() async {
  final directory = await getApplicationDocumentsDirectory();
  return directory.path;
}

/// A throwaway container for a session that must not touch the user's real
/// engrams — the filesystem half of the `--ignore-config` startup flag.
///
/// Neutering preferences is not enough on its own. Discovery has two sources,
/// and only one of them is preferences: it also scans the container returned by
/// [applicationEngramContainerPath] one level deep, so a session backed by that
/// path lists every engram in the user's documents directory no matter how
/// thoroughly its saved configuration was ignored. That is a disclosure rather
/// than an inconvenience — an engram the user considers private is named in the
/// switcher, and in any screenshot taken of it.
///
/// This resolver hands out an empty temporary directory instead, so discovery
/// finds nothing real and anything the session creates lands somewhere
/// disposable. The directory is created once per process and reused, so
/// discovery and creation agree on one container for the session's lifetime; it
/// is deliberately not removed at exit, since it holds whatever that session
/// made and the system reaps its temp tree anyway.
Future<String> ephemeralEngramContainerPath() =>
    _ephemeralContainer ??= _createEphemeralContainer();

/// Memoized as the [Future], not its result, so two concurrent callers share
/// one directory instead of racing to create two.
Future<String>? _ephemeralContainer;

Future<String> _createEphemeralContainer() async {
  final directory = await Directory.systemTemp.createTemp(
    'brainframe-ephemeral-',
  );
  return directory.path;
}
