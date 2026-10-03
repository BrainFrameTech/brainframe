import 'dart:developer' as developer;

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;
import 'package:shared_preferences/shared_preferences.dart';

import '../../settings/settings_store.dart';
import '../device_name.dart';
import '../engram.dart';
import '../fs/fs_store_io.dart';
import '../note_reconciler.dart';
import '../note_writer.dart';
import 'app_data_resolver.dart';
import 'crdt_note_writer_io.dart';
import 'device_naming_io.dart';
import 'drift_reconciler_io.dart';
import 'identity_authorship_io.dart';
import 'identity_map_io.dart';
import 'metadata_db_io.dart';
import 'note_document_lock.dart';
import '../watch/engram_watcher.dart';
import '../watch/engram_watcher_io.dart';

/// The `dart:developer` log name for the session's own messages.
const String crdtSessionLogName = 'brainframe.engram.session';

/// One engram's open op-log, for as long as that engram is the active one.
///
/// The database is a process-wide resource with a lifetime, which nothing in
/// the app owned before this: steps 0–8 built every piece of the CRDT layer and
/// left it unreachable, because opening it is only worth doing once something
/// writes through it. That is step 9.
///
/// **One session per engram, closed on the way out.** SQLite connections are
/// not free and two connections to one `metadata.db` would defeat the single
/// transaction boundary the schema depends on, so switching engrams closes the
/// outgoing session before the incoming one opens.
class CrdtSession {
  CrdtSession._(
    this._database,
    this.writer,
    this._reconciler,
    this._identity,
    this._folder,
    this._watcherFor,
    this._naming,
  );

  final MetadataDatabase _database;
  final AuthoredIdentity? _identity;

  /// The engram folder, for the watcher; null for an engram with none.
  final String? _folder;
  final EngramWatcher? Function(String root) _watcherFor;

  /// The watch while it runs (the filesystem watcher design, Decision 8).
  WatchDispatcher? _watching;

  final ValueNotifier<EngramWatchUnavailable?> _watchStatus = ValueNotifier(
    null,
  );

  /// Why live updates are off for this engram, or null while they are on
  /// (Decision 9): what Housekeeping says, once, rather than a notice on
  /// every open. Null too before the first [startWatching], and while
  /// watching is paused with the app in the background — those are not
  /// failures, and the resume scan is the catch-up.
  ValueListenable<EngramWatchUnavailable?> get watchStatus => _watchStatus;

  /// How the editor should save into this engram.
  final NoteWriter writer;

  final DriftReconciler _reconciler;

  /// How the app brings files that changed outside it back into history.
  NoteReconciler get reconciler => _reconciler;

  final SessionDeviceNaming _naming;

  /// What this device is called in this engram, and how Settings changes it
  /// (the device names design, Decisions 1 and 2).
  DeviceNaming get naming => _naming;

  /// Opens the op-log for [engram], or returns null if it should not have one.
  ///
  /// Null for a read-only engram: the built-ins ship as assets, cannot be
  /// edited, and nothing is ever written into their `.brainframe/`. A null
  /// session is the normal answer for them rather than a failure, and the
  /// editor writes directly — which for a read-only engram means it never
  /// writes at all.
  ///
  /// [resolveRoot] overrides where `metadata.db` is looked for, so a test can
  /// point at a temporary directory instead of the real app-data one. This
  /// is the app's edge: the platform's answer is applied here, once, and
  /// handed down to a store that never asks for it.
  ///
  /// [trace] is handed to the reconciler as the scan's narration sink — the
  /// `--trace-scan` startup option; see [DriftReconciler.trace].
  ///
  /// [watcherFor] makes the folder's watcher, which [startWatching] starts;
  /// it defaults to this platform's ([engramWatcherFor]), and a test hands in
  /// a fake.
  ///
  /// [deviceSettings] is where the device's default name is kept, the
  /// device-tier store by default; [platformName] is what the platform calls
  /// the device. A test hands in both, so no plugin or hostname is involved.
  static Future<CrdtSession?> openFor(
    Engram engram, {
    AppDataRootResolver? resolveRoot,
    void Function(String line)? trace,
    EngramWatcher? Function(String root) watcherFor = engramWatcherFor,
    SettingsBackend? deviceSettings,
    PlatformDeviceName? platformName,
  }) async {
    if (engram.readOnly) return null;
    final root = resolveRoot ?? appDataRootResolver();
    final database = await MetadataDatabase.open(engram.id, resolveRoot: root);
    // Old scan records go on open, before anything reads them: a year of
    // ordinary scans, never the ones that lost history or failed.
    database.scans.prune();
    // The shared identity map lives inside the engram folder, so it exists
    // only for an engram that has one. Every writable engram today is a
    // filesystem engram; the seam allows otherwise, and such an engram would
    // get drift reconciliation and nothing that needs a listing.
    final store = engram.store;
    if (store is FileSystemEngramStore) {
      // Label the store with the folder it belongs to, for whoever is
      // looking at the app-data directory by hand. A debugging aid: the
      // engram opens whether or not it could be written, and the failure is
      // logged rather than raised.
      try {
        await recordEngramPath(
          engram.id,
          store.location.path,
          resolveRoot: root,
        );
      } on Object catch (error, stack) {
        developer.log(
          'could not record the folder path in the engram store',
          name: crdtSessionLogName,
          error: error,
          stackTrace: stack,
        );
      }
    }
    final identity = store is FileSystemEngramStore
        ? await AuthoredIdentity.load(
            IdentityMap(
              engramRoot: store.location.path,
              peerId: database.peerId,
            ),
          )
        : null;
    if (identity != null) {
      // What the map file should say about this device's own mints is in
      // the catalog; a write lost to the debounce — a quit within seconds
      // of the first scan, a crash — is made good here, before anything
      // reads the map.
      final repaired = identity.repairFrom(
        database.catalog.seededBy(database.peerId),
      );
      if (repaired > 0) {
        developer.log(
          'identity map rebuilt: $repaired claim(s) the file had lost',
          name: crdtSessionLogName,
        );
      }
    }
    // What this device is called here, published in its map file before the
    // first scan — so even an open that changes nothing else names the
    // device to the engram's others. A file already saying so is left
    // alone.
    final naming = await SessionDeviceNaming.open(
      database: database,
      identity: identity,
      deviceSettings: deviceSettings ?? _deviceSettings(),
      platformName: platformName ?? PlatformDeviceName(),
    );
    // One lock between the two: a save and a reconciliation of the same note
    // must never overlap, and nothing above the session sequences them.
    final lock = NoteDocumentLock();
    final reconciler = DriftReconciler(
      database: database,
      engram: store,
      lock: lock,
      identity: identity,
      noteSizeCeilingBytes: engram.noteSizeCeilingBytes,
      trace: trace,
    );
    return CrdtSession._(
      database,
      CrdtNoteWriter(
        database: database,
        engram: store,
        lock: lock,
        identity: identity,
        // A save looks before it writes, and asks the reconciler, so a file
        // changed underneath is taken in exactly as the scan would take it
        // (the filesystem watcher design, Decision 5).
        check: reconciler,
      ),
      reconciler,
      identity,
      store is FileSystemEngramStore ? store.location.path : null,
      watcherFor,
      naming,
    );
  }

  /// The device tier, where the device's default name is kept — or, where
  /// the platform's preferences cannot be reached at all, a tier with
  /// nothing in it. A name is never worth failing an engram's open over: the
  /// device is then called by the platform's name.
  static SettingsBackend _deviceSettings() {
    try {
      return DeviceSettingsBackend(SharedPreferencesAsync());
    } on StateError catch (error, stack) {
      developer.log(
        'device preferences are unavailable; no default device name',
        name: crdtSessionLogName,
        error: error,
        stackTrace: stack,
      );
      return const NullSettingsBackend();
    }
  }

  /// Starts watching the engram folder for changes made outside the app
  /// (Decisions 8 and 3), if it is not watched already.
  ///
  /// Called before the scan that opens the session, so a change made during
  /// a long first scan is an event, and the scan runs again once it is done;
  /// and on mobile, again before the resume scan. Never throws: a folder that
  /// cannot be watched — the platform, the system's limit, anything else —
  /// becomes [watchStatus], and the session carries on with the triggers it
  /// had before.
  Future<void> startWatching() async {
    if (_watching != null || _watchStatus.value != null) return;
    final folder = _folder;
    final watcher = folder == null ? null : _watcherFor(folder);
    if (watcher == null) {
      _watchStatus.value = const EngramWatchUnavailable.unsupported();
      return;
    }
    final dispatcher = WatchDispatcher(
      watcher: watcher,
      reconciler: _reconciler,
      isTracked: (path) => _database.catalog.byPath(path) != null,
      onFailure: (failure) {
        _watching = null;
        _watchStatus.value = failure;
      },
    );
    _watching = dispatcher;
    try {
      await dispatcher.start();
    } on EngramWatchUnavailable catch (failure) {
      _watching = null;
      _watchStatus.value = failure;
      developer.log(
        'cannot watch this engram',
        name: crdtSessionLogName,
        error: failure,
      );
    }
  }

  /// Stops watching, if it is: on mobile when the app goes to the background
  /// (Decision 8), and on the way to [close]. Not a failure — [watchStatus]
  /// is left as it was.
  Future<void> stopWatching() async {
    final dispatcher = _watching;
    _watching = null;
    await dispatcher?.stop();
  }

  /// Writes any identity-map rows still in the timers, without closing.
  ///
  /// Registered with the app's flush registry, so the desktop close path and
  /// the resume scan write the map the way they write unsaved editor text:
  /// a mint or a rename made seconds before a quit must reach the folder, or
  /// every other device keeps its own idea of that note.
  Future<void> flush() async {
    await _naming.settle();
    await _identity?.flush();
  }

  /// Writes any identity-map rows still in the timers, closes the
  /// reconciler's event stream, and closes the database. Safe to call twice.
  ///
  /// The map is flushed *before* the database closes, and awaited: a rename
  /// recorded seconds before the engram was switched away from must reach
  /// the folder, or every other device keeps the old path.
  Future<void> close() async {
    // First: nothing the watcher dispatches may reach a closing reconciler.
    await stopWatching();
    // A name save still in flight publishes before the map is flushed, and
    // none may start after: its writer is about to be left behind.
    await _naming.close();
    await _identity?.flush();
    await _reconciler.close();
    _database.close();
  }
}
