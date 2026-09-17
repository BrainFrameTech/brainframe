/// The one-shot commands: what a store holds, printed and done.
library;

import 'package:brainframe/engram/crdt/catalog.dart';

import 'replay.dart';
import 'store.dart';

/// `notes`: every catalog row with its state, seed, and change count.
void printNotes(StoreReader store, StringSink out) {
  final counts = store.changeCounts();
  final rows = store.catalog().values.toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  out.writeln('${store.label}  ${store.path}');
  out.writeln('peer ${store.peerId}');
  out.writeln('');
  out.writeln(
    '${'state'.padRight(15)} ${'changes'.padLeft(7)}  '
    '${'seed'.padRight(8)}  ${'ulid'.padRight(26)}  path',
  );
  for (final row in rows) {
    final seed = row.seededBy == null
        ? '-'
        : row.seededBy == store.peerId
        ? 'self'
        : row.seededBy!.substring(0, 8);
    out.writeln(
      '${row.state.padRight(15)} ${(counts[row.ulid] ?? 0).toString().padLeft(7)}  '
      '${seed.padRight(8)}  ${row.ulid}  ${row.path}',
    );
  }
  out.writeln('');
  out.writeln(
    '${rows.length} rows, '
    '${counts.values.fold(0, (sum, n) => sum + n)} changes, '
    'last scan ${store.lastScan?.toLocal() ?? 'never'}',
  );
}

/// `log`: one note's op-log, replayed, each change as what it did.
///
/// Returns false if [name] — a path or a ULID — names no row.
bool printLog(StoreReader store, String name, StringSink out) {
  final entry = store.entryNamed(name);
  if (entry == null) {
    out.writeln('${store.label}: no catalog row for $name');
    return false;
  }
  out.writeln(
    '${store.label}  ${entry.path}  ${entry.ulid}  ${entry.state}  '
    '${entry.mergePolicy}'
    '${entry.seededBy == null ? '' : '  seed ${_peer(store, entry.seededBy!)}'}',
  );
  final changes = store.changesFor(entry.ulid);
  if (changes.isEmpty) {
    out.writeln(
      entry.state == NoteState.historyPending.name
          ? 'no history on this device: adopted from another peer\'s map, '
                'and its log has not arrived'
          : 'no changes',
    );
    return true;
  }
  final replay = NoteReplay(entry.ulid, mergePolicy: entry.mergePolicy);
  var n = 0;
  for (final stored in changes) {
    n++;
    final change = stored.change;
    out.writeln(
      '${n.toString().padLeft(4)}  ${_peer(store, change.author.toString())}'
      '@${change.hlc.asDateTime.toLocal().toIso8601String()}  '
      'deps ${change.deps.length}  ${replay.apply(stored)}',
    );
  }
  out.writeln('');
  out.writeln('${changes.length} changes; value now:');
  out.writeln(replay.value);
  replay.dispose();
  return true;
}

String _peer(StoreReader store, String peerId) =>
    peerId == store.peerId ? 'self' : peerId.substring(0, 8);
