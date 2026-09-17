// bfmon — the BrainFrame store monitor.
//
// A read-only window onto one or more devices' `metadata.db` files: what the
// catalog says about each note, what each scan did, and every operation in
// the op-log as the text it inserted or deleted. Meant to sit beside two
// BrainFrame windows over one engram folder and narrate what the CRDT layer
// is doing underneath them.
//
//   dart run bin/bfmon.dart watch /tmp/deviceA /tmp/deviceB
//   dart run bin/bfmon.dart notes /tmp/deviceA
//   dart run bin/bfmon.dart log   /tmp/deviceA index.md
//
// A store argument is a `metadata.db`, its directory, or an app-data home
// (the `XDG_DATA_HOME` an instance was launched with) holding one engram's
// store. Plain Dart: no Flutter, and SQLite is bundled by its package, so
// `dart build cli -t bin/bfmon.dart` gives a standalone bundle that runs on the
// Pi.
//
// Never writes. Opens every database read-only and touches nothing else, so
// it is safe to point at the stores of instances that are running.
import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';

import '../tool/bfmon/commands.dart';
import '../tool/bfmon/store.dart';
import '../tool/bfmon/watch.dart';

const String _usage = '''
bfmon — watch what BrainFrame's CRDT layer is doing, from its stores.

Usage:
  bfmon watch <store> [<store>...]   narrate every change as it lands
  bfmon notes <store>                the catalog: state, seed, change count
  bfmon log   <store> <path|ulid>    one note's op-log, replayed

A <store> is a metadata.db, the directory holding one, or an app-data home
(the XDG_DATA_HOME an instance runs with) containing engrams/<ulid>/metadata.db.
Stores are labelled A, B, C… in the order given.
''';

Future<void> main(List<String> arguments) async {
  final parser = ArgParser()
    ..addOption(
      'engram',
      help: 'The engram ULID to pick when an app-data home holds several.',
    )
    ..addOption(
      'interval',
      defaultsTo: '250',
      help: 'watch: milliseconds between polls.',
    )
    ..addFlag(
      'color',
      defaultsTo: stdout.supportsAnsiEscapes,
      help: 'Colour the store labels.',
    )
    ..addFlag('help', abbr: 'h', negatable: false);

  final ArgResults options;
  try {
    options = parser.parse(arguments);
  } on ArgParserException catch (error) {
    stderr.writeln(error.message);
    stderr.writeln(_usage);
    exitCode = 64;
    return;
  }
  if (options['help'] as bool || options.rest.isEmpty) {
    stdout.writeln(_usage);
    stdout.writeln(parser.usage);
    return;
  }

  final command = options.rest.first;
  final operands = options.rest.sublist(1);
  final engramId = options['engram'] as String?;
  try {
    switch (command) {
      case 'watch':
        if (operands.isEmpty) throw ArgumentError('watch needs a store');
        await _watch(
          operands,
          engramId: engramId,
          interval: Duration(
            milliseconds: int.parse(options['interval'] as String),
          ),
          color: options['color'] as bool,
        );
      case 'notes':
        if (operands.length != 1) throw ArgumentError('notes needs one store');
        final store = _open(operands.single, 'A', engramId: engramId);
        try {
          printNotes(store, stdout);
        } finally {
          store.close();
        }
      case 'log':
        if (operands.length != 2) {
          throw ArgumentError('log needs a store and a path or ULID');
        }
        final store = _open(operands.first, 'A', engramId: engramId);
        try {
          if (!printLog(store, operands.last, stdout)) exitCode = 1;
        } finally {
          store.close();
        }
      default:
        throw ArgumentError('unknown command: $command');
    }
  } on ArgumentError catch (error) {
    stderr.writeln('bfmon: ${error.message}');
    exitCode = 64;
  }
}

StoreReader _open(String argument, String label, {String? engramId}) =>
    StoreReader.open(
      resolveStorePath(argument, engramId: engramId),
      label: label,
    );

Future<void> _watch(
  List<String> arguments, {
  required String? engramId,
  required Duration interval,
  required bool color,
}) async {
  final stores = <StoreReader>[];
  String? folder;
  for (final (index, argument) in arguments.indexed) {
    final label = String.fromCharCode('A'.codeUnitAt(0) + index);
    final store = _open(argument, label, engramId: engramId);
    stores.add(store);
    folder ??= engramFolderOf(store.path);
  }
  final stopped = Completer<void>();
  final signals = ProcessSignal.sigint.watch().listen((_) {
    if (!stopped.isCompleted) stopped.complete();
  });
  final watcher = Watcher(
    stores,
    out: stdout,
    engramFolder: folder,
    color: color,
  );
  try {
    await watcher.run(interval: interval, until: stopped.future);
  } finally {
    await signals.cancel();
    for (final store in stores) {
      store.close();
    }
  }
}
