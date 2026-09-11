import 'dart:io';

import 'package:brainframe/engram/crdt/app_data_resolver_io.dart';
import 'package:brainframe/engram/crdt/crdt_note_writer_io.dart';
import 'package:brainframe/engram/crdt/crdt_session_io.dart';
import 'package:brainframe/engram/crdt/drift_reconciler_io.dart';
import 'package:brainframe/engram/engram.dart';
import 'package:brainframe/engram/fs/engram_location.dart';
import 'package:brainframe/engram/fs/fs_store_io.dart';
import 'package:brainframe/engram/id.dart';
import 'package:flutter_test/flutter_test.dart';

/// One engram's op-log, opened for as long as that engram is active.
void main() {
  late Directory root;
  late AppDataRootResolver resolveRoot;

  setUp(() {
    root = Directory.systemTemp.createTempSync('brainframe_crdt_session');
    resolveRoot = appDataRootResolver(overridePath: root.path);
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Engram engramWith({required bool readOnly}) => Engram(
    id: newUlid(),
    displayName: 'test',
    readOnly: readOnly,
    store: FileSystemEngramStore(EngramLocation('${root.path}/engram')),
  );

  test('a read-only engram gets no session', () async {
    // The built-ins ship as assets and nothing is ever written into their
    // marker directory, so a null session is the normal answer rather than a
    // failure to open one.
    expect(
      await CrdtSession.openFor(
        engramWith(readOnly: true),
        resolveRoot: resolveRoot,
      ),
      isNull,
    );
  });

  test('a read-only engram is refused before any database is touched',
      () async {
    // No resolver at all: if openFor reached the database this would try the
    // real app-data directory, so passing proves the read-only check comes
    // first.
    expect(await CrdtSession.openFor(engramWith(readOnly: true)), isNull);
  });

  test('a writable engram gets a CRDT writer', () async {
    final session = await CrdtSession.openFor(
      engramWith(readOnly: false),
      resolveRoot: resolveRoot,
    );
    addTearDown(() => session?.close());

    expect(session, isNotNull);
    expect(session!.writer, isA<CrdtNoteWriter>());
  });

  test('a writable engram gets a reconciler over the same op-log', () async {
    final engram = engramWith(readOnly: false);
    final session = await CrdtSession.openFor(engram, resolveRoot: resolveRoot);
    addTearDown(() => session?.close());
    expect(session!.reconciler, isA<DriftReconciler>());

    // Same catalog: a note the writer minted is one the reconciler can see.
    await session.writer.write('inbox/today.md', 'one\n');
    await engram.store.writeString('inbox/today.md', 'one\ntwo\n');

    expect(await session.reconciler.reconcile('inbox/today.md'), isTrue);
  });

  test('a save and a reconciliation of one note never overlap', () async {
    // The lock is shared between the two, which is what a session exists to
    // arrange: nothing above it sequences a debounced save against a scan.
    final engram = engramWith(readOnly: false);
    final session = await CrdtSession.openFor(engram, resolveRoot: resolveRoot);
    addTearDown(() => session?.close());
    await session!.writer.write('inbox/today.md', 'one\n');
    await engram.store.writeString('inbox/today.md', 'one\ntwo\n');

    // Both queued at once: the reconciliation absorbs the external line, then
    // the save applies the buffer against the result.
    final reconcile = session.reconciler.reconcile('inbox/today.md');
    final save = session.writer.write('inbox/today.md', 'ONE\ntwo\n');
    await Future.wait([reconcile, save]);

    expect(await engram.store.readString('inbox/today.md'), 'ONE\ntwo\n');
  });

  test('close ends the reconciled stream', () async {
    final session = await CrdtSession.openFor(
      engramWith(readOnly: false),
      resolveRoot: resolveRoot,
    );
    final done = session!.reconciler.reconciled.listen((_) {}).asFuture<void>();

    await session.close();

    await expectLater(done, completes);
  });

  test('the session writes through to the engram', () async {
    final engram = engramWith(readOnly: false);
    final session = await CrdtSession.openFor(
      engram,
      resolveRoot: resolveRoot,
    );
    addTearDown(() => session?.close());

    await session!.writer.write('inbox/today.md', '# Today\n');

    expect(await engram.store.readString('inbox/today.md'), '# Today\n');
  });

  test('close releases the database', () async {
    final session = await CrdtSession.openFor(
      engramWith(readOnly: false),
      resolveRoot: resolveRoot,
    );

    await session!.close();

    // A closed connection refuses further work, which is what makes the
    // close-before-open ordering in the host meaningful rather than cosmetic.
    expect(
      () => session.writer.write('inbox/today.md', 'after close\n'),
      throwsA(anything),
    );
  });
}
