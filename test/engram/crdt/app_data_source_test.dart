import 'package:brainframe/engram/crdt/app_data_source.dart';
import 'package:flutter_test/flutter_test.dart';

/// The per-platform app-data mapping, pinned.
///
/// Both halves of this are counter-intuitive on sight, and both fail silently
/// when wrong: a roaming profile copies a live database out from under its
/// writer, and `$XDG_CACHE_HOME` invites a disk cleaner to delete an op-log
/// mid-session. Neither shows up as an error — the app simply opens an empty
/// or corrupt store later. So the mapping is asserted rather than trusted to
/// a comment.
void main() {
  group('appDataSourceFor', () {
    test('Windows reads LocalAppData, never the roaming profile', () {
      // getApplicationSupportDirectory() maps to RoamingAppData on Windows,
      // which is copied between machines at logon/logoff.
      // getApplicationCacheDirectory() is the only path_provider call that
      // reaches the non-roaming LocalAppData.
      expect(appDataSourceFor('windows'), AppDataSource.applicationCache);
    });

    test('Linux reads XDG_DATA_HOME, never XDG_CACHE_HOME', () {
      // The same call Windows needs resolves to $XDG_CACHE_HOME here, where a
      // disk cleaner may delete it. An op-log is not derived from anything and
      // cannot be rebuilt by rescanning, so it is data, not cache.
      expect(appDataSourceFor('linux'), AppDataSource.applicationSupport);
    });

    test('every other platform reads application support', () {
      for (final os in ['macos', 'android', 'ios', 'fuchsia']) {
        expect(
          appDataSourceFor(os),
          AppDataSource.applicationSupport,
          reason: '$os must not take the Windows exception',
        );
      }
    });

    test('Windows is the only exception', () {
      // Stated as its own assertion so that widening the exception — to
      // "desktop", say — fails here rather than quietly moving three
      // platforms' op-logs into a cache directory.
      final exceptions = [
        'linux',
        'macos',
        'windows',
        'android',
        'ios',
        'fuchsia',
      ].where((os) => appDataSourceFor(os) == AppDataSource.applicationCache);

      expect(exceptions, ['windows']);
    });

    test('an unknown platform name falls back to application support', () {
      // The recoverable direction: application support is durable everywhere,
      // so an unrecognized platform keeps history rather than risking a cache.
      expect(appDataSourceFor('haiku'), AppDataSource.applicationSupport);
    });
  });

  test('engrams live under a directory named for the concept', () {
    expect(engramsDirectoryName, 'engrams');
  });
}
