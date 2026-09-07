import 'dart:io';

import 'package:brainframe/engram/crdt/app_data_resolver_io.dart';
import 'package:brainframe/engram/crdt/crdt_note_writer_io.dart';
import 'package:brainframe/engram/crdt/crdt_session_io.dart';
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
