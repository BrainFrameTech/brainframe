/// The live view: what each store, and the engram's shared identity map,
/// just did.
///
/// SQLite has no cross-process change notification — `sqlite3_update_hook`
/// fires only for the connection that wrote — so this polls. Cheaply: each
/// tick reads `PRAGMA data_version` per store, which moves only when
/// another connection committed, and skips the store when it has not.
/// When it has, a handful of small queries are diffed against the last
/// snapshot and each difference becomes one line: a scan and what it did,
/// a catalog row appearing, changing state, moving, or being tombstoned,
/// and every new change in the op-log, replayed and described as the text
/// it inserted or deleted.
///
/// One line per event, oldest first, prefixed with the time and the store's
/// label, so two stores over one folder read as one interleaved story.
library;

import 'dart:async';
import 'dart:io';

import 'package:brainframe/engram/crdt/catalog.dart';
import 'package:sqlite3/sqlite3.dart' as sq;

import 'replay.dart';
import 'store.dart';

/// What the watcher remembers of one store between ticks.
class _StoreSnapshot {
  _StoreSnapshot({
    required this.dataVersion,
    required this.lastScan,
    required this.latestScanId,
    required this.catalog,
    required this.changeIds,
  });

  int dataVersion;
  DateTime? lastScan;
  int latestScanId;
  Map<String, CatalogEntry> catalog;
  Map<String, Set<String>> changeIds;

  /// A replay per document, built silently from the log the first time the
  /// document is seen, so only changes that arrive *while watching* print.
  final Map<String, NoteReplay> replays = {};
}

/// One identity-map file's rows, keyed by ULID, plus the file's mtime as
/// the cheap "did it change" test.
class _MapSnapshot {
  _MapSnapshot(this.modified, this.rows);

  DateTime modified;
  Map<String, (String path, bool deleted)> rows;
}

/// Watches one or more stores and, when known, their engram's shared map.
class Watcher {
  Watcher(
    this.stores, {
    required this.out,
    this.engramFolder,
    this.color = false,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now {
    for (final store in stores) {
      _peerLabels[store.peerId] = store.label;
    }
  }

  final List<StoreReader> stores;
  final StringSink out;

  /// The engram folder whose `.brainframe/shared/*.db` files to watch, if
  /// any store's `path.txt` named one.
  final String? engramFolder;
  final bool color;
  final DateTime Function() _clock;

  final Map<StoreReader, _StoreSnapshot> _snapshots = {};
  final Map<String, _MapSnapshot> _maps = {};
  final Map<String, String> _peerLabels = {};

  /// Takes the first snapshot of everything, printing a header and nothing
  /// else: what is already there is history, and `log` is for that.
  void start() {
    for (final store in stores) {
      _snapshots[store] = _snapshot(store);
      _line(
        store.label,
        'watching ${store.path}\n'
        '${_pad('')}   peer ${store.peerId}  '
        '${_snapshots[store]!.catalog.length} catalog rows  '
        '${_countAll(_snapshots[store]!.changeIds)} changes',
      );
    }
    final folder = engramFolder;
    if (folder != null) {
      _readMaps(folder, announce: false);
      _line(
        '·',
        'watching $folder/.brainframe/shared  '
            '${_maps.length} peer map(s)',
      );
    }
  }

  /// One poll of every store and the map: prints what changed since the
  /// last tick. Public so a test can drive it without timers.
  void tick() {
    for (final store in stores) {
      try {
        _tickStore(store);
      } on sq.SqliteException catch (error) {
        // A commit that outlasted the busy timeout, or a store deleted from
        // under us: say so once and try again next tick.
        _line(store.label, 'read failed: ${error.message}');
      }
    }
    final folder = engramFolder;
    if (folder != null) _readMaps(folder, announce: true);
  }

  /// Polls every [interval] until [until] completes (Ctrl-C, in the CLI).
  Future<void> run({
    required Duration interval,
    required Future<void> until,
  }) async {
    start();
    final timer = Timer.periodic(interval, (_) => tick());
    try {
      await until;
    } finally {
      timer.cancel();
    }
  }

  _StoreSnapshot _snapshot(StoreReader store) => _StoreSnapshot(
    dataVersion: store.dataVersion,
    lastScan: store.lastScan,
    latestScanId: store.latestScanId,
    catalog: store.catalog(),
    changeIds: store.changeIds(),
  );

  void _tickStore(StoreReader store) {
    final previous = _snapshots[store]!;
    final version = store.dataVersion;
    if (version == previous.dataVersion) return;
    previous.dataVersion = version;

    // Scans first: they explain the catalog and log changes that follow.
    final scans = store.scansAfter(previous.latestScanId);
    for (final scan in scans) {
      previous.latestScanId = scan.id;
      _line(
        store.label,
        'scan #${scan.id} (${scan.trigger}): ${_events(scan)}',
      );
    }
    final lastScan = store.lastScan;
    if (scans.isEmpty && lastScan != previous.lastScan) {
      _line(store.label, 'scan: clean');
    }
    previous.lastScan = lastScan;

    final catalog = store.catalog();
    _diffCatalog(store, previous.catalog, catalog);
    previous.catalog = catalog;

    final changeIds = store.changeIds();
    _diffChanges(store, previous, changeIds, catalog);
    previous.changeIds = changeIds;
  }

  String _events(ScanRecord scan) {
    if (scan.events.isEmpty) return scan.complete ? 'clean' : 'incomplete';
    final byKind = <String, List<String>>{};
    for (final (kind, path, newPath) in scan.events) {
      byKind
          .putIfAbsent(kind, () => [])
          .add(newPath == null ? path : '$path → $newPath');
    }
    return byKind.entries
        .map((entry) => '${entry.key} ${entry.value.join(', ')}')
        .join('; ');
  }

  void _diffCatalog(
    StoreReader store,
    Map<String, CatalogEntry> before,
    Map<String, CatalogEntry> after,
  ) {
    for (final entry in after.values) {
      final old = before[entry.ulid];
      final seed = entry.seededBy == null
          ? ''
          : '  seed ${_peer(entry.seededBy!)}';
      if (old == null) {
        final how = entry.state == NoteState.historyPending.name
            ? 'adopted'
            : entry.seededBy == store.peerId
            ? 'minted'
            : 'recorded';
        _line(
          store.label,
          '${entry.path}  $how ${_ulid(entry.ulid)}  ${entry.state}$seed',
        );
        continue;
      }
      if (old.path != entry.path) {
        _line(store.label, '${old.path} → ${entry.path}  moved');
      }
      if (old.state != entry.state) {
        _line(store.label, '${entry.path}  ${old.state} → ${entry.state}$seed');
      } else if (old.materializedHash != entry.materializedHash &&
          entry.materializedHash != null) {
        // Same state, new hash: this device wrote the file (live) or saw
        // that someone else did (history-pending) — either way, what it
        // believes the file holds is now these bytes.
        final verb = entry.state == NoteState.historyPending.name
            ? 'observed'
            : 'materialized';
        _line(
          store.label,
          '${entry.path}  $verb ${entry.materializedHash!.substring(0, 12)}',
        );
      }
      if (old.mergePolicy != entry.mergePolicy) {
        _line(
          store.label,
          '${entry.path}  ${old.mergePolicy} → ${entry.mergePolicy}',
        );
      }
    }
    for (final entry in before.values) {
      if (!after.containsKey(entry.ulid)) {
        _line(store.label, '${entry.path}  row removed ${_ulid(entry.ulid)}');
      }
    }
  }

  void _diffChanges(
    StoreReader store,
    _StoreSnapshot previous,
    Map<String, Set<String>> after,
    Map<String, CatalogEntry> catalog,
  ) {
    for (final entry in after.entries) {
      final documentId = entry.key;
      final known = previous.changeIds[documentId] ?? const <String>{};
      final fresh = entry.value.difference(known);
      if (fresh.isEmpty) continue;
      final path = catalog[documentId]?.path ?? _ulid(documentId);
      final replay = previous.replays.putIfAbsent(documentId, () {
        // First sight of this document: rebuild it from what was already
        // there, silently, so the fresh changes describe a real delta.
        final built = NoteReplay(
          documentId,
          mergePolicy:
              catalog[documentId]?.mergePolicy ?? MergePolicy.fugueText.name,
        );
        for (final stored in store.changesNamed(documentId, known)) {
          built.apply(stored);
        }
        return built;
      });
      for (final stored in store.changesNamed(documentId, fresh)) {
        final change = stored.change;
        _line(
          store.label,
          '$path  +change ${_peer(change.author.toString())}'
          '@${_time(change.hlc.asDateTime)}  ${replay.apply(stored)}',
        );
      }
    }
  }

  /// Reads every `.brainframe/shared/<peer>.db`, announcing files that
  /// appeared and rows that changed when [announce] is set.
  void _readMaps(String folder, {required bool announce}) {
    final shared = Directory('$folder/.brainframe/shared');
    if (!shared.existsSync()) return;
    for (final entity in shared.listSync()) {
      if (entity is! File || !entity.path.endsWith('.db')) continue;
      final peer = entity.uri.pathSegments.last.replaceAll('.db', '');
      final modified = entity.statSync().modified;
      final previous = _maps[entity.path];
      if (previous != null && previous.modified == modified) continue;
      final Map<String, (String, bool)> rows;
      try {
        rows = _mapRows(entity.path);
      } on sq.SqliteException {
        continue; // mid-write; next tick
      }
      if (previous == null) {
        _maps[entity.path] = _MapSnapshot(modified, rows);
        if (announce) {
          _line('·', 'map  peer ${_peer(peer)} appeared  ${rows.length} rows');
        }
        continue;
      }
      previous.modified = modified;
      if (announce) {
        for (final row in rows.entries) {
          final old = previous.rows[row.key];
          final (path, deleted) = row.value;
          if (old == null) {
            _line(
              '·',
              'map  ${_peer(peer)} claims ${_ulid(row.key)} at $path'
                  '${deleted ? '  (deleted)' : ''}',
            );
          } else if (old.$1 != path) {
            _line('·', 'map  ${_peer(peer)}: ${old.$1} → $path');
          } else if (old.$2 != deleted) {
            _line(
              '·',
              'map  ${_peer(peer)}: $path ${deleted ? 'deleted' : 'restored'}',
            );
          }
        }
      }
      previous.rows = rows;
    }
  }

  Map<String, (String, bool)> _mapRows(String file) {
    final db = sq.sqlite3.open(file, mode: sq.OpenMode.readOnly);
    try {
      db.execute('PRAGMA busy_timeout = 500');
      return {
        for (final row in db.select(
          'SELECT ulid, path, deleted FROM bf_identity_map',
        ))
          row['ulid'] as String: (
            row['path'] as String,
            (row['deleted'] as int) != 0,
          ),
      };
    } finally {
      db.close();
    }
  }

  // ------------------------------------------------------------ formatting

  static const _colors = ['36', '33', '35', '32', '34'];

  void _line(String label, String message) {
    final stamp = _time(_clock());
    out.writeln('$stamp  ${_pad(label)}  $message');
  }

  String _pad(String label) {
    if (!color) return label.padRight(1);
    final index = stores.indexWhere((store) => store.label == label);
    if (index < 0) return label;
    return '\x1B[${_colors[index % _colors.length]}m$label\x1B[0m';
  }

  /// A peer id as the store label that owns it, else its first eight chars.
  String _peer(String peerId) => _peerLabels[peerId] ?? peerId.substring(0, 8);

  static String _ulid(String ulid) => ulid.length > 10
      ? '${ulid.substring(0, 6)}…${ulid.substring(ulid.length - 4)}'
      : ulid;

  static String _time(DateTime at) {
    final local = at.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(local.hour)}:${two(local.minute)}:${two(local.second)}'
        '.${local.millisecond.toString().padLeft(3, '0')}';
  }

  static int _countAll(Map<String, Set<String>> ids) =>
      ids.values.fold(0, (sum, set) => sum + set.length);
}
