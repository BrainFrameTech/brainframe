import 'dart:io';
import 'dart:typed_data';

import 'package:brainframe/engram/crdt/app_data_source.dart';
import 'package:brainframe/engram/crdt/catalog.dart';
import 'package:brainframe/engram/crdt/crdt_note_writer_io.dart';
import 'package:brainframe/engram/crdt/drift_reconciler_io.dart';
import 'package:brainframe/engram/crdt/engram_store_location_io.dart';
import 'package:brainframe/engram/crdt/identity_authorship_io.dart';
import 'package:brainframe/engram/crdt/identity_map_io.dart';
import 'package:brainframe/engram/crdt/metadata_db_io.dart';
import 'package:brainframe/engram/crdt/note_document_lock.dart';
import 'package:brainframe/engram/fs/engram_location.dart';
import 'package:brainframe/engram/fs/fs_store_io.dart';
import 'package:brainframe/engram/id.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/bfmon/commands.dart';
import '../../tool/bfmon/replay.dart';
import '../../tool/bfmon/store.dart';
import '../../tool/bfmon/watch.dart';

/// bfmon, the store monitor, against real stores driven by the real writer
/// and reconciler: two devices over one folder, as the demo runs them.
void main() {
  late Directory root;
  late String engramRoot;
  late FileSystemEngramStore engram;
  final devices = <_Device>[];

  setUp(() {
    root = Directory.systemTemp.createTempSync('brainframe_bfmon');
    engramRoot = '${root.path}/engram';
    Directory(engramRoot).createSync();
    engram = FileSystemEngramStore(EngramLocation(engramRoot));
  });

  tearDown(() async {
    for (final device in devices) {
      await device.close();
    }
    devices.clear();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// One device: its own app-data home under [root], like one instance's
  /// `XDG_DATA_HOME`, over the shared [engram].
  Future<_Device> device(String name, {required String engramId}) async {
    final home = '${root.path}/$name/tech.brainframe.app.debug';
    Future<String> resolveRoot() async => home;
    final store = await MetadataDatabase.open(
      engramId,
      resolveRoot: resolveRoot,
    );
    await recordEngramPath(engramId, engramRoot, resolveRoot: resolveRoot);
    final identity = await AuthoredIdentity.load(
      IdentityMap(engramRoot: engramRoot, peerId: store.peerId),
      writer: DebouncedIdentityMapWriter(
        (rows) => IdentityMap(
          engramRoot: engramRoot,
          peerId: store.peerId,
        ).write(rows),
        idleDebounce: const Duration(days: 1),
        maxWait: const Duration(days: 1),
      ),
    );
    final lock = NoteDocumentLock();
    final d = _Device(
      home: '${root.path}/$name',
      store: store,
      identity: identity,
      writer: CrdtNoteWriter(
        database: store,
        engram: engram,
        lock: lock,
        identity: identity,
      ),
      reconciler: DriftReconciler(
        database: store,
        engram: engram,
        lock: lock,
        identity: identity,
      ),
    );
    devices.add(d);
    return d;
  }

  group('resolveStorePath', () {
    test('accepts the file, its directory, or the app-data home', () async {
      final id = newUlid();
      final a = await device('a', engramId: id);
      final file =
          '${a.home}/tech.brainframe.app.debug/'
          '$engramsDirectoryName/$id/$metadataDatabaseFileName';

      expect(resolveStorePath(file), file);
      expect(resolveStorePath(File(file).parent.path), file);
      expect(resolveStorePath(a.home), file);
      expect(engramFolderOf(file), engramRoot);
    });

    test('with several engrams under a home, --engram picks', () async {
      final one = newUlid();
      final two = newUlid();
      final a = await device('a', engramId: one);
      await device('a', engramId: two);

      expect(
        () => resolveStorePath(a.home),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('holds 2 engram stores'),
          ),
        ),
      );
      expect(resolveStorePath(a.home, engramId: two), contains('/$two/'));
      expect(
        () => resolveStorePath(a.home, engramId: newUlid()),
        throwsArgumentError,
      );
    });

    test('says what is wrong with a bad argument', () {
      expect(() => resolveStorePath('${root.path}/nope'), throwsArgumentError);
      expect(() => resolveStorePath(root.path), throwsArgumentError);
      final stray = File('${root.path}/stray.txt')..writeAsStringSync('x');
      expect(() => resolveStorePath(stray.path), throwsArgumentError);
    });
  });

  group('StoreReader', () {
    test('refuses a file that is not a store', () {
      final other = File('${root.path}/$metadataDatabaseFileName')
        ..writeAsStringSync('');
      expect(
        () => StoreReader.open(other.path, label: 'X'),
        throwsArgumentError,
      );
      expect(
        () => StoreReader.open('${root.path}/missing.db', label: 'X'),
        throwsArgumentError,
      );
    });

    test('reads the peer, the catalog, the scans, and the log', () async {
      final a = await device('a', engramId: newUlid());
      await a.writer.write('one.md', 'first\n');
      await engram.writeString('one.md', 'first\nsecond\n');
      await a.reconciler.scan();

      final reader = a.reader();
      expect(reader.peerId, a.store.peerId.toString());
      final entry = reader.entryAt('one.md')!;
      expect(entry.state, NoteState.live.name);
      expect(reader.entryFor(entry.ulid)!.path, 'one.md');
      expect(reader.entryNamed(entry.ulid)!.path, 'one.md');
      expect(reader.entryNamed('one.md')!.ulid, entry.ulid);
      expect(reader.entryNamed('nope.md'), isNull);
      expect(reader.latestScanId, 1);
      final scan = reader.scansAfter(0).single;
      expect(scan.trigger, 'manual');
      expect(scan.events, [('reconciled', 'one.md', null)]);
      expect(reader.scansAfter(1), isEmpty);
      expect(reader.lastScan, isNotNull);
      final changes = reader.changesFor(entry.ulid);
      expect(changes, hasLength(2));
      expect(changes.first.change.hlc <= changes.last.change.hlc, isTrue);
      expect(reader.changeCounts()[entry.ulid], 2);
      expect(reader.changeIds()[entry.ulid], hasLength(2));
      expect(
        reader
            .changesNamed(entry.ulid, {changes.last.changeId})
            .single
            .changeId,
        changes.last.changeId,
      );
      reader.close();
    });
  });

  group('describeDelta', () {
    test('names the inserted and deleted runs and the line', () {
      expect(describeDelta('', 'hello\n'), '+"hello\\n" @seed');
      expect(describeDelta('a\nb\nc\n', 'a\nb\nX\nc\n'), '+"X\\n" @L3');
      expect(describeDelta('a\nbb\nc\n', 'a\nc\n'), '-"bb\\n" @L2');
      expect(describeDelta('one two', 'one three'), '-"wo" +"hree" @L1');
      expect(describeDelta('same', 'same'), 'no change');
    });

    test('elides a long run but keeps its length', () {
      final long = 'x' * 500;
      final delta = describeDelta('', long);
      expect(delta, contains('…'));
      expect(delta, contains('(500 chars)'));
      expect(delta.length, lessThan(120));
    });
  });

  group('log and notes', () {
    test('replay a text note change by change', () async {
      final a = await device('a', engramId: newUlid());
      await a.writer.write('n.md', 'one\n');
      await a.writer.write('n.md', 'one\ntwo\n');
      final out = StringBuffer();

      expect(printLog(a.reader(), 'n.md', out), isTrue);

      final text = out.toString();
      expect(text, contains('n.md'));
      expect(text, contains('self@'));
      expect(text, contains('+"one\\n" @seed'));
      expect(text, contains('+"two\\n" @L2'));
      expect(text, contains('2 changes; value now:\none\ntwo\n'));
    });

    test('a history-pending note says why it has no log', () async {
      final id = newUlid();
      final a = await device('a', engramId: id);
      await engram.writeString('theirs.md', 'from a\n');
      await a.reconciler.scan();
      await a.publish();
      final b = await device('b', engramId: id);
      await b.reconciler.scan();
      final out = StringBuffer();

      expect(printLog(b.reader(), 'theirs.md', out), isTrue);
      expect(out.toString(), contains('no history on this device'));

      expect(printLog(b.reader(), 'missing.md', StringBuffer()), isFalse);
    });

    test('a blob note is a register of digests', () async {
      final a = await device('a', engramId: newUlid());
      await engram.writeBytes('pic.png', Uint8List.fromList([1, 2, 3]));
      await a.reconciler.scan();
      await engram.writeBytes('pic.png', Uint8List.fromList([4, 5, 6, 7]));
      await a.reconciler.scan();
      final out = StringBuffer();

      printLog(a.reader(), 'pic.png', out);

      expect(out.toString(), contains('claim '));
      expect(out.toString(), contains('(4 bytes), was '));
    });

    test('notes lists every row with its count', () async {
      final a = await device('a', engramId: newUlid());
      await a.writer.write('n.md', 'one\n');
      await a.writer.write('m.md', 'two\n');
      final out = StringBuffer();

      printNotes(a.reader(), out);

      final text = out.toString();
      expect(text, contains('live'));
      expect(text, contains('self'));
      expect(text, contains('  m.md'));
      expect(text, contains('  n.md'));
      expect(text, contains('2 rows, 2 changes'));
    });
  });

  group('watch', () {
    test('narrates two devices over one folder', () async {
      final id = newUlid();
      final a = await device('a', engramId: id);
      await a.writer.write('index.md', 'from A\n');
      await a.publish();
      final b = await device('b', engramId: id);
      final out = StringBuffer();
      var now = DateTime(2026, 9, 16, 21, 0, 0);
      final watcher = Watcher(
        [a.reader(), b.reader()],
        out: out,
        engramFolder: engramRoot,
        clock: () => now,
      );
      watcher.start();
      expect(out.toString(), contains('A  watching'));
      expect(out.toString(), contains('B  watching'));
      expect(out.toString(), contains('1 peer map(s)'));
      out.clear();

      // B opens the folder: adopts A's note, seeds nothing.
      await b.reconciler.scan();
      now = now.add(const Duration(seconds: 1));
      watcher.tick();
      var text = out.toString();
      expect(
        text,
        contains('21:00:01.000  B  scan #1 (manual): adopted index.md'),
      );
      expect(text, contains('B  index.md  adopted'));
      expect(text, contains('historyPending  seed A'));
      expect(text, isNot(contains('+change')));
      out.clear();

      // B edits as a plain file; A's scan makes history of it — one change,
      // authored by A, described as the text it inserted.
      await b.writer.write('index.md', 'from A\nfrom B\n');
      await a.reconciler.scan();
      watcher.tick();
      text = out.toString();
      expect(text, contains('B  index.md  observed'));
      expect(text, contains('A  scan #1 (manual): reconciled index.md'));
      expect(text, contains('A  index.md  materialized'));
      expect(text, contains('A  index.md  +change A@'));
      expect(text, contains('+"from B\\n" @L2'));
      out.clear();

      // Nothing happened: nothing printed.
      watcher.tick();
      expect(out.toString(), isEmpty);

      // A clean scan leaves only its stamp.
      await a.reconciler.scan();
      watcher.tick();
      expect(out.toString(), contains('A  scan: clean'));
      out.clear();

      // B creates a note: minted on B; A adopts it once B's map is out.
      await b.writer.write('new.md', 'new on B\n');
      await b.publish();
      await a.reconciler.scan();
      watcher.tick();
      text = out.toString();
      expect(text, contains('B  new.md  minted'));
      expect(text, contains('B  new.md  +change B@'));
      expect(text, contains('+"new on B\\n" @seed'));
      expect(text, contains('A  scan #2 (manual): adopted new.md'));
      expect(text, contains('A  new.md  adopted'));
      expect(text, contains('map  peer B appeared  1 rows'));
      out.clear();

      // An external rename: A moves it in its catalog and tells the map.
      await engram.move('index.md', 'moved.md');
      await a.reconciler.scan();
      await a.publish();
      watcher.tick();
      text = out.toString();
      expect(text, contains('A  scan #3 (manual): moved index.md → moved.md'));
      expect(text, contains('A  index.md → moved.md  moved'));
      expect(text, contains('map  A: index.md → moved.md'));
      out.clear();

      // A deletion: tombstoned on A, and the map says so.
      await engram.delete('moved.md');
      await a.reconciler.scan();
      await a.publish();
      watcher.tick();
      text = out.toString();
      expect(text, contains('tombstoned moved.md'));
      expect(text, contains('A  moved.md  live → tombstoned'));
      expect(text, contains('map  A: moved.md deleted'));
    });

    test('run polls until told to stop, and colours labels', () async {
      final a = await device('a', engramId: newUlid());
      final out = StringBuffer();
      final watcher = Watcher([a.reader()], out: out, color: true);
      final stop = Future<void>.delayed(const Duration(milliseconds: 120));

      final running = watcher.run(
        interval: const Duration(milliseconds: 20),
        until: stop,
      );
      await a.writer.write('n.md', 'hi\n');
      await running;

      expect(out.toString(), contains('\x1B[36mA\x1B[0m'));
      expect(out.toString(), contains('n.md  minted'));
    });

    test('a store that breaks underneath is reported, not fatal', () async {
      final a = await device('a', engramId: newUlid());
      final reader = StoreReader.open(resolveStorePath(a.home), label: 'A');
      addTearDown(reader.close);
      final out = StringBuffer();
      final watcher = Watcher([reader], out: out);
      watcher.start();
      await a.close();
      devices.remove(a);
      // The file is replaced by something that is not a database at all.
      File(reader.path).writeAsBytesSync(List.filled(4096, 0x41));

      expect(watcher.tick, returnsNormally);
      expect(out.toString(), contains('A  read failed'));
    });
  });
}

class _Device {
  _Device({
    required this.home,
    required this.store,
    required this.identity,
    required this.writer,
    required this.reconciler,
  });

  /// This device's app-data home, as `XDG_DATA_HOME` would be.
  final String home;
  final MetadataDatabase store;
  final AuthoredIdentity identity;
  final CrdtNoteWriter writer;
  final DriftReconciler reconciler;
  final List<StoreReader> _readers = [];

  StoreReader reader() {
    final r = StoreReader.open(
      resolveStorePath(home),
      label: home.split('/').last.toUpperCase(),
    );
    _readers.add(r);
    return r;
  }

  Future<void> publish() => identity.flush();

  Future<void> close() async {
    for (final r in _readers) {
      r.close();
    }
    await reconciler.close();
    store.close();
  }
}
