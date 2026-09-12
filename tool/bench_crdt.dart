// The CRDT layer's cost on this machine: what the scan pays per note, and what
// one note costs to seed at each size. The numbers behind the design's
// "Performance envelope" (docs/design/note-identity-and-crdt.md) and the
// note-size ceiling, kept here so they can be re-taken on any target rather
// than trusted from a table written on one.
//
// Run with `flutter test`, by explicit path so the suite never picks it up:
//
//   flutter test tool/bench_crdt.dart                 # the standard set
//   BENCH=quick flutter test tool/bench_crdt.dart     # one folder, small notes
//   BENCH=scan  flutter test tool/bench_crdt.dart     # or BENCH=seed
//
// It would be a plain `dart run` script if it could be: everything it times
// is pure Dart over SQLite. But the store and the app-data resolver import
// `path_provider`, a Flutter plugin, so the import chain reaches `dart:ui`
// and only the Flutter tool can compile it. `flutter test` is the smallest
// harness that can, and it runs on a Raspberry Pi over SSH the same as on a
// desktop. Everything it touches — the catalog, the op-log, the reconciler,
// the identity map — is the code the app runs, over real files in a temporary
// directory that is removed afterwards. Nothing reaches the real app data or
// any real engram.
//
// Two figures matter and both scale: the first scan over an existing engram
// mints every note (this is adoption's cost, and the reason step 12 must be
// non-blocking), and seeding a single note costs memory per character, which
// is what sets the ceiling. These are debug-mode numbers on a JIT VM, so a
// release build is somewhat faster; the ratio between targets is the durable
// result. The tables print as Markdown, ready to paste.
import 'dart:io';

import 'package:brainframe/engram/crdt/app_data_resolver_io.dart';
import 'package:brainframe/engram/crdt/drift_reconciler_io.dart';
import 'package:brainframe/engram/crdt/identity_authorship_io.dart';
import 'package:brainframe/engram/crdt/identity_map_io.dart';
import 'package:brainframe/engram/crdt/metadata_db_io.dart';
import 'package:brainframe/engram/crdt/note_document_io.dart';
import 'package:brainframe/engram/crdt/note_document_lock.dart';
import 'package:brainframe/engram/crdt/sketch.dart';
import 'package:brainframe/engram/fs/engram_location.dart';
import 'package:brainframe/engram/fs/fs_store_io.dart';
import 'package:brainframe/engram/id.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final mode = Platform.environment['BENCH'] ?? '';
  final quick = mode == 'quick';
  final scanOnly = mode == 'scan';
  final seedOnly = mode == 'seed';

  setUpAll(() {
    stdout.writeln(
      '# bench_crdt on ${Platform.operatingSystem} '
      '${Platform.version.split(' ').first}, ${Platform.numberOfProcessors} '
      'cores',
    );
    stdout.writeln();
  });

  test('scanning a folder', () async {
    if (seedOnly) return;
    final folders = quick
        ? const [(200, 300)]
        : const [(200, 300), (200, 1500), (1000, 300)];
    stdout.writeln('## Scanning a folder');
    stdout.writeln();
    stdout.writeln(
      '| Folder | Read all | First scan (mint) | Map flush | '
      'Steady scan | Cold-copy adopt |',
    );
    stdout.writeln('| :-- | --: | --: | --: | --: | --: |');
    for (final (count, words) in folders) {
      stdout.writeln(await _benchScan(count: count, words: words));
    }
    stdout.writeln();
  }, timeout: const Timeout(Duration(minutes: 30)));

  test('seeding one note', () async {
    if (scanOnly) return;
    final sizes = quick
        ? const [300, 1500, 5000]
        : const [300, 1500, 5000, 20000, 60000];
    stdout.writeln('## Seeding one note');
    stdout.writeln();
    stdout.writeln(
      '| Note | Mint | Per char | Reopen from op-log | Sketch | '
      'Resident while held |',
    );
    stdout.writeln('| --: | --: | --: | --: | --: | --: |');
    await _benchSeed(sizes);
    stdout.writeln();
  }, timeout: const Timeout(Duration(minutes: 30)));
}

/// Synthetic prose: distinct words, so every trigram is unique and the sketch
/// has as much to do as it ever will.
String _body(int words) => List.generate(words, (i) => 'word$i').join(' ');

Future<String> _benchScan({required int count, required int words}) async {
  final root = Directory.systemTemp.createTempSync('bf_bench_scan');
  try {
    final engramRoot = '${root.path}/engram';
    Directory(engramRoot).createSync();
    final text = '# Note\n\n${_body(words)}\n';
    for (var i = 0; i < count; i++) {
      File('$engramRoot/note$i.md').writeAsStringSync(text);
    }

    // Read every file once, so the seed cost can be separated from I/O.
    var sw = Stopwatch()..start();
    for (var i = 0; i < count; i++) {
      File('$engramRoot/note$i.md').readAsBytesSync();
    }
    final readMs = sw.elapsedMilliseconds;

    final first = await _Device.open(root, engramRoot);
    try {
      sw = Stopwatch()..start();
      final minted = await first.reconciler.scan();
      final firstMs = sw.elapsedMilliseconds;
      _check(minted.created.length == count, 'first scan minted every note');

      sw = Stopwatch()..start();
      await first.identity.flush();
      final flushMs = sw.elapsedMilliseconds;

      sw = Stopwatch()..start();
      final steady = await first.reconciler.scan();
      final steadyMs = sw.elapsedMilliseconds;
      _check(steady.isClean, 'steady scan is clean');

      // A second device over the same folder: every ULID from the first
      // device's map, nothing seeded.
      final second = await _Device.open(root, engramRoot);
      try {
        sw = Stopwatch()..start();
        final adopted = await second.reconciler.scan();
        final adoptMs = sw.elapsedMilliseconds;
        _check(adopted.adopted.length == count, 'cold copy adopted every note');

        return '| $count × ${_kb(text.length)} notes ($words words) '
            '| $readMs ms '
            '| $firstMs ms (${(firstMs / count).toStringAsFixed(1)} ms/note) '
            '| $flushMs ms '
            '| $steadyMs ms (${(steadyMs * 1000 / count).toStringAsFixed(0)} µs/note) '
            '| $adoptMs ms (${(adoptMs / count).toStringAsFixed(1)} ms/note) |';
      } finally {
        await second.close();
      }
    } finally {
      await first.close();
    }
  } finally {
    root.deleteSync(recursive: true);
  }
}

Future<void> _benchSeed(List<int> sizes) async {
  final root = Directory.systemTemp.createTempSync('bf_bench_seed');
  try {
    final store = await MetadataDatabase.open(
      newUlid(),
      resolveRoot: appDataRootResolver(overridePath: root.path),
    );
    try {
      for (final words in sizes) {
        final text = _body(words);
        final before = ProcessInfo.currentRss;
        var sw = Stopwatch()..start();
        final note = NoteDocument.mint(
          store: store,
          path: 'n$words.md',
          content: text,
        );
        final mintMs = sw.elapsedMilliseconds;
        final held = ProcessInfo.currentRss - before;

        sw = Stopwatch()..start();
        final sketch = computeSketch(text);
        final sketchMs = sw.elapsedMilliseconds;

        sw = Stopwatch()..start();
        final reopened = NoteDocument.open(store: store, ulid: note.ulid);
        final openMs = sw.elapsedMilliseconds;
        _check(reopened.value == text, 'reopened note holds the seed');
        note.dispose();
        reopened.dispose();

        stdout.writeln(
          '| ${_kb(text.length)} ($words words) '
          '| $mintMs ms '
          '| ${(mintMs * 1000 / text.length).toStringAsFixed(1)} µs '
          '| $openMs ms '
          '| $sketchMs ms (${sketch.length} B) '
          '| ${(held / 1024 / 1024).toStringAsFixed(0)} MB '
          '(${(held / text.length).toStringAsFixed(0)} B/char) |',
        );
      }
    } finally {
      store.close();
    }
  } finally {
    root.deleteSync(recursive: true);
  }
}

/// One device over a folder: its own database and identity-map file, with a
/// reconciler that only writes the map when asked.
class _Device {
  _Device(this.store, this.identity, this.reconciler);

  final MetadataDatabase store;
  final AuthoredIdentity identity;
  final DriftReconciler reconciler;

  static Future<_Device> open(Directory root, String engramRoot) async {
    final store = await MetadataDatabase.open(
      newUlid(),
      resolveRoot: appDataRootResolver(overridePath: root.path),
    );
    final map = IdentityMap(engramRoot: engramRoot, peerId: store.peerId);
    final identity = await AuthoredIdentity.load(
      map,
      writer: DebouncedIdentityMapWriter(
        map.write,
        idleDebounce: const Duration(days: 1),
        maxWait: const Duration(days: 1),
      ),
    );
    return _Device(
      store,
      identity,
      DriftReconciler(
        database: store,
        engram: FileSystemEngramStore(EngramLocation(engramRoot)),
        lock: NoteDocumentLock(),
        identity: identity,
      ),
    );
  }

  Future<void> close() async {
    identity.dispose();
    await reconciler.close();
    store.close();
  }
}

String _kb(int bytes) =>
    '${(bytes / 1024).toStringAsFixed(bytes < 10240 ? 1 : 0)} KB';

/// A benchmark that measured the wrong thing is worse than none, so each
/// stage checks that the scan and the seed did what the table claims.
void _check(bool condition, String what) =>
    expect(condition, isTrue, reason: what);
