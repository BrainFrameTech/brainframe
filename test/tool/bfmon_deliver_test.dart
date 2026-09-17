// ignore_for_file: prefer_initializing_formals

import 'dart:io';
import 'dart:typed_data';

import 'package:brainframe/engram/crdt/catalog.dart';
import 'package:brainframe/engram/crdt/crdt_note_writer_io.dart';
import 'package:brainframe/engram/crdt/drift_reconciler_io.dart';
import 'package:brainframe/engram/crdt/engram_store_location_io.dart';
import 'package:brainframe/engram/crdt/identity_authorship_io.dart';
import 'package:brainframe/engram/crdt/identity_map_io.dart';
import 'package:brainframe/engram/crdt/metadata_db_io.dart';
import 'package:brainframe/engram/crdt/note_document_io.dart';
import 'package:brainframe/engram/crdt/note_document_lock.dart';
import 'package:brainframe/engram/fs/engram_location.dart';
import 'package:brainframe/engram/fs/fs_store_io.dart';
import 'package:brainframe/engram/id.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../tool/bfmon/deliver.dart';
import '../../tool/bfmon/store.dart';

/// `deliver`: operations carried between two devices' stores by hand, and
/// what the receiver does with them — the local half of sync, exercised
/// against the real store, writer, and reconciler.
///
/// A device here is closed (its store released) before it receives, as the
/// command requires of the app, and reopened afterwards to look.
void main() {
  late Directory root;
  final open = <_Device>[];

  setUp(() {
    root = Directory.systemTemp.createTempSync('brainframe_deliver');
  });

  tearDown(() async {
    for (final device in List.of(open)) {
      await device.release();
    }
    open.clear();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// A device [name] over [folder]; its app-data home is `<root>/<name>`.
  Future<_Device> device(
    String name, {
    required String engramId,
    required String folder,
  }) async {
    Directory(folder).createSync(recursive: true);
    final home = '${root.path}/$name/tech.brainframe.app.debug';
    Future<String> resolveRoot() async => home;
    final store = await MetadataDatabase.open(
      engramId,
      resolveRoot: resolveRoot,
    );
    await recordEngramPath(engramId, folder, resolveRoot: resolveRoot);
    final identity = await AuthoredIdentity.load(
      IdentityMap(engramRoot: folder, peerId: store.peerId),
      writer: DebouncedIdentityMapWriter(
        (rows) =>
            IdentityMap(engramRoot: folder, peerId: store.peerId).write(rows),
        idleDebounce: const Duration(days: 1),
        maxWait: const Duration(days: 1),
      ),
    );
    final lock = NoteDocumentLock();
    final engram = FileSystemEngramStore(EngramLocation(folder));
    final d = _Device(
      name: name,
      home: '${root.path}/$name',
      folder: folder,
      engram: engram,
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
    open.add(d);
    return d;
  }

  Future<Map<DeliveryOutcome, int>> send(
    _Device from,
    _Device to, {
    String? note,
    StringSink? out,
  }) => deliver(
    fromStorePath: from.storePath,
    toStorePath: to.storePath,
    note: note,
    out: out ?? StringBuffer(),
  );

  group('over one shared folder', () {
    late String id;
    late String folder;

    setUp(() {
      id = newUlid();
      folder = '${root.path}/engram';
    });

    test('a history-pending note is promoted and gets its log', () async {
      final a = await device('a', engramId: id, folder: folder);
      await a.writer.write('index.md', 'from A\n');
      await a.publish();
      final b = await device('b', engramId: id, folder: folder);
      await b.reconciler.scan();
      expect(b.rowAt('index.md')!.state, NoteState.historyPending);
      final out = StringBuffer();
      await b.release();

      final outcomes = await send(a, b, note: 'index.md', out: out);

      expect(outcomes, {DeliveryOutcome.delivered: 1});
      expect(out.toString(), contains('shared folder'));
      expect(out.toString(), contains('index.md  +1 change; promoted'));
      expect(out.toString(), contains('file already the projection'));
      await b.reopen();
      final row = b.rowAt('index.md')!;
      expect(row.state, NoteState.live);
      expect(row.seededBy, a.store.peerId, reason: 'the seed stays A\'s');
      expect(b.changesOf('index.md'), 1);
      expect(b.valueOf('index.md'), 'from A\n');
      expect(await b.engram.readString('index.md'), 'from A\n');
      expect((await b.reconciler.scan()).isClean, isTrue);

      // B now has a history: its next save is operations, not a file write.
      await b.writer.write('index.md', 'from A\nfrom B\n');
      expect(b.changesOf('index.md'), 2);
      final authors = b.authorsOf('index.md');
      expect(
        authors,
        containsAll([a.store.peerId.toString(), b.store.peerId.toString()]),
      );
    });

    test('a second delivery of the same log is up to date', () async {
      final a = await device('a', engramId: id, folder: folder);
      await a.writer.write('index.md', 'from A\n');
      await a.publish();
      final b = await device('b', engramId: id, folder: folder);
      await b.reconciler.scan();
      await b.release();
      await send(a, b);

      final out = StringBuffer();
      final outcomes = await send(a, b, out: out);

      expect(outcomes, {DeliveryOutcome.upToDate: 1});
      expect(out.toString(), contains('index.md  up to date'));
    });

    test('plain-file edits made while pending become operations', () async {
      final a = await device('a', engramId: id, folder: folder);
      await a.writer.write('index.md', 'from A\n');
      await a.publish();
      final b = await device('b', engramId: id, folder: folder);
      await b.reconciler.scan();
      // B edits before any log arrives: a plain write, no ops.
      await b.writer.write('index.md', 'from A\nfrom B, pending\n');
      expect(b.changesOf('index.md'), 0);
      await b.release();
      final out = StringBuffer();

      await send(a, b, out: out);

      expect(
        out.toString(),
        contains('file diffed in: +"from B, pending\\n" @L2'),
      );
      await b.reopen();
      expect(b.valueOf('index.md'), 'from A\nfrom B, pending\n');
      expect(b.changesOf('index.md'), 2, reason: 'A\'s seed and B\'s diff');
      expect(b.authorsOf('index.md'), contains(b.store.peerId.toString()));
    });

    test('the receiver catches up on the sender\'s later edits', () async {
      // The "A was off" story: B edits with a history, A never scanned, and
      // delivery gives A the operations rather than a file to diff.
      final a = await device('a', engramId: id, folder: folder);
      await a.writer.write('index.md', 'from A\n');
      await a.publish();
      final b = await device('b', engramId: id, folder: folder);
      await b.reconciler.scan();
      await b.release();
      await send(a, b);
      await b.reopen();
      await b.writer.write('index.md', 'from A\nfrom B\n');
      await a.release();
      final out = StringBuffer();

      await send(b, a, note: 'index.md', out: out);

      expect(
        out.toString(),
        contains('index.md  +1 change; file already the projection'),
      );
      await a.reopen();
      expect(a.changesOf('index.md'), 2);
      expect(a.authorsOf('index.md'), contains(b.store.peerId.toString()));
      expect(a.valueOf('index.md'), 'from A\nfrom B\n');
      expect((await a.reconciler.scan()).isClean, isTrue);
    });

    test('every note with a log is delivered when none is named', () async {
      final a = await device('a', engramId: id, folder: folder);
      await a.writer.write('one.md', '1\n');
      await a.writer.write('two.md', '2\n');
      await a.publish();
      final b = await device('b', engramId: id, folder: folder);
      await b.reconciler.scan();
      // A note B has never heard of is skipped, not invented.
      await a.writer.write('three.md', '3\n');
      await b.release();
      final out = StringBuffer();

      final outcomes = await send(a, b, out: out);

      expect(outcomes, {
        DeliveryOutcome.delivered: 2,
        DeliveryOutcome.skipped: 1,
      });
      expect(
        out.toString(),
        contains('three.md  skipped: the receiver has no row'),
      );
      expect(out.toString(), contains('2 delivered, 1 skipped'));
    });
  });

  group('over two folders (offline)', () {
    test('concurrent edits merge, and both files converge', () async {
      final id = newUlid();
      final folderA = '${root.path}/copyA';
      final folderB = '${root.path}/copyB';
      final a = await device('a', engramId: id, folder: folderA);
      await a.writer.write('x.md', 'one\ntwo\nthree\n');
      await a.publish();
      // B's copy of the folder, identity map included: a cold copy.
      _copyTree(folderA, folderB);
      final b = await device('b', engramId: id, folder: folderB);
      await b.reconciler.scan();
      await b.release();
      await send(a, b); // phase 0: B has the history
      await b.reopen();

      // Offline: each edits its own copy, at different places.
      await a.writer.write('x.md', 'one\nA was here\ntwo\nthree\n');
      await b.writer.write('x.md', 'one\ntwo\nthree\nB was here\n');

      // Reconnect: both ways.
      await b.release();
      await send(a, b);
      await b.reopen();
      await a.release();
      await send(b, a);
      await a.reopen();

      const merged = 'one\nA was here\ntwo\nthree\nB was here\n';
      expect(a.valueOf('x.md'), merged);
      expect(b.valueOf('x.md'), merged);
      expect(await a.engram.readString('x.md'), merged);
      expect(await b.engram.readString('x.md'), merged);
      expect((await a.reconciler.scan()).isClean, isTrue);
      expect((await b.reconciler.scan()).isClean, isTrue);
      expect(a.changesOf('x.md'), b.changesOf('x.md'));
    });

    test('local drift on the receiver is reconciled before import', () async {
      final id = newUlid();
      final folderA = '${root.path}/copyA';
      final folderB = '${root.path}/copyB';
      final a = await device('a', engramId: id, folder: folderA);
      await a.writer.write('x.md', 'base\n');
      await a.publish();
      _copyTree(folderA, folderB);
      final b = await device('b', engramId: id, folder: folderB);
      await b.reconciler.scan();
      await b.release();
      await send(a, b);
      await b.reopen();

      await a.writer.write('x.md', 'base\nfrom A\n');
      // B's file edited outside the app while B was closed.
      await b.engram.writeString('x.md', 'from B\nbase\n');
      await b.release();
      final out = StringBuffer();

      await send(a, b, out: out);

      expect(out.toString(), contains('local drift reconciled first'));
      await b.reopen();
      expect(b.valueOf('x.md'), 'from B\nbase\nfrom A\n');
      expect(await b.engram.readString('x.md'), 'from B\nbase\nfrom A\n');
    });

    test('a blob\'s bytes are copied from the sender when they match the '
        'winning claim', () async {
      final id = newUlid();
      final folderA = '${root.path}/copyA';
      final folderB = '${root.path}/copyB';
      final a = await device('a', engramId: id, folder: folderA);
      await a.engram.writeBytes('pic.png', Uint8List.fromList([1, 2, 3]));
      await a.reconciler.scan();
      await a.publish();
      _copyTree(folderA, folderB);
      final b = await device('b', engramId: id, folder: folderB);
      await b.reconciler.scan();
      await b.release();
      await send(a, b);
      await b.reopen();
      expect(b.rowAt('pic.png')!.state, NoteState.live);

      // A replaces the image; B's copy is stale.
      await a.engram.writeBytes('pic.png', Uint8List.fromList([9, 9, 9, 9]));
      await a.reconciler.scan();
      await b.release();
      final out = StringBuffer();

      await send(a, b, note: 'pic.png', out: out);

      expect(
        out.toString(),
        contains('bytes copied from the sender (4 bytes)'),
      );
      await b.reopen();
      expect(await b.engram.readBytes('pic.png'), [9, 9, 9, 9]);
      expect((await b.reconciler.scan()).isClean, isTrue);
    });
  });

  group('refusals', () {
    test('the same store on both sides', () async {
      final a = await device(
        'a',
        engramId: newUlid(),
        folder: '${root.path}/e',
      );
      expect(
        () => send(a, a),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('same store'),
          ),
        ),
      );
    });

    test('a note the sender does not have', () async {
      final id = newUlid();
      final folder = '${root.path}/e';
      final a = await device('a', engramId: id, folder: folder);
      final b = await device('b', engramId: id, folder: folder);
      await b.release();
      expect(() => send(a, b, note: 'nope.md'), throwsArgumentError);
    });

    test('a receiver another process holds open', () async {
      final id = newUlid();
      final folder = '${root.path}/e';
      final a = await device('a', engramId: id, folder: folder);
      final b = await device('b', engramId: id, folder: folder);
      await b.release();
      expect(isOpenByAnotherProcess(b.storePath), isFalse);
      final holder = await Process.start('tail', ['-f', b.storePath]);
      addTearDown(holder.kill);
      // Give tail a moment to open the file.
      for (var i = 0; i < 50; i++) {
        if (isOpenByAnotherProcess(b.storePath) == true) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }

      expect(isOpenByAnotherProcess(b.storePath), isTrue);
      expect(
        () => send(a, b),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('open in another process'),
          ),
        ),
      );
      // --force goes ahead anyway.
      final out = StringBuffer();
      await deliver(
        fromStorePath: a.storePath,
        toStorePath: b.storePath,
        out: out,
        force: true,
      );
      expect(out.toString(), contains('delivering from'));
    }, skip: !Platform.isLinux);
  });
}

void _copyTree(String from, String to) {
  for (final entity in Directory(from).listSync(recursive: true)) {
    final relative = entity.path.substring(from.length + 1);
    if (entity is Directory) {
      Directory('$to/$relative').createSync(recursive: true);
    } else if (entity is File) {
      File('$to/$relative').parent.createSync(recursive: true);
      entity.copySync('$to/$relative');
    }
  }
}

class _Device {
  _Device({
    required this.name,
    required this.home,
    required this.folder,
    required this.engram,
    required MetadataDatabase store,
    required AuthoredIdentity identity,
    required CrdtNoteWriter writer,
    required DriftReconciler reconciler,
  }) : _store = store,
       _identity = identity,
       _writer = writer,
       _reconciler = reconciler;

  final String name;
  final String home;
  final String folder;
  final FileSystemEngramStore engram;
  MetadataDatabase? _store;
  AuthoredIdentity? _identity;
  CrdtNoteWriter? _writer;
  DriftReconciler? _reconciler;

  MetadataDatabase get store => _store!;
  CrdtNoteWriter get writer => _writer!;
  DriftReconciler get reconciler => _reconciler!;

  String get storePath => resolveStorePath(home);

  Future<void> publish() => _identity!.flush();

  CatalogRow? rowAt(String path) => store.catalog.byPath(path);

  int changesOf(String path) => store.crdt
      .changeStorageForDocument(rowAt(path)!.ulid)
      .getChanges()
      .length;

  Set<String> authorsOf(String path) => {
    for (final c
        in store.crdt.changeStorageForDocument(rowAt(path)!.ulid).getChanges())
      c.author.toString(),
  };

  String valueOf(String path) {
    final note = NoteDocument.open(store: store, ulid: rowAt(path)!.ulid);
    try {
      return note.value;
    } finally {
      note.dispose();
    }
  }

  /// Closes the store, as the app would be closed before receiving.
  Future<void> release() async {
    if (_store == null) return;
    await _reconciler!.close();
    await _identity!.flush();
    _store!.close();
    _store = null;
  }

  /// Reopens the store to look at what delivery did.
  Future<void> reopen() async {
    final engramId = File(
      storePath,
    ).parent.uri.pathSegments.where((s) => s.isNotEmpty).last;
    Future<String> resolveRoot() async => '$home/tech.brainframe.app.debug';
    _store = await MetadataDatabase.open(engramId, resolveRoot: resolveRoot);
    _identity = await AuthoredIdentity.load(
      IdentityMap(engramRoot: folder, peerId: _store!.peerId),
      writer: DebouncedIdentityMapWriter(
        (rows) =>
            IdentityMap(engramRoot: folder, peerId: _store!.peerId).write(rows),
        idleDebounce: const Duration(days: 1),
        maxWait: const Duration(days: 1),
      ),
    );
    final lock = NoteDocumentLock();
    _writer = CrdtNoteWriter(
      database: _store!,
      engram: engram,
      lock: lock,
      identity: _identity,
    );
    _reconciler = DriftReconciler(
      database: _store!,
      engram: engram,
      lock: lock,
      identity: _identity,
    );
  }
}
