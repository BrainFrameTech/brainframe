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
//   dart run bin/bfmon.dart deliver /tmp/deviceA /tmp/deviceB [index.md]
//
// A store argument is a `metadata.db`, its directory, or an app-data home
// (the `XDG_DATA_HOME` an instance was launched with) holding one engram's
// store. Plain Dart: no Flutter, and SQLite is bundled by its package, so
// `dart build cli -t bin/bfmon.dart` gives a standalone bundle that runs on the
// Pi.
//
// The reading commands open every database read-only and touch nothing
// else, so they are safe to point at the stores of instances that are
// running. `deliver` is the one that writes: it carries one device's
// operations into another's op-log — sync's local half, by hand — and needs
// the receiving app closed.
import 'dart:async';
import 'dart:io';

import 'package:args/args.dart';

import '../tool/bfmon/commands.dart';
import '../tool/bfmon/deliver.dart';
import '../tool/bfmon/store.dart';
import '../tool/bfmon/watch.dart';

const String _usage = '''
bfmon — watch what BrainFrame's CRDT layer is doing, from its stores.

Usage:
  bfmon watch <store> [<store>...]   narrate every change as it lands
  bfmon notes <store>                the catalog: state, seed, change count
  bfmon log   <store> <path|ulid>    one note's op-log, replayed
  bfmon deliver <from> <to> [<path|ulid>]
                                     carry the sender's operations into the
                                     receiver's op-log (receiving app closed)

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
    ..addFlag(
      'force',
      negatable: false,
      help: 'deliver: proceed even if the receiving store looks open.',
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
        final store = _open(
          operands.single,
          _basename(operands.single),
          engramId: engramId,
        );
        try {
          printNotes(store, stdout);
        } finally {
          store.close();
        }
      case 'log':
        if (operands.length != 2) {
          throw ArgumentError('log needs a store and a path or ULID');
        }
        final store = _open(
          operands.first,
          _basename(operands.first),
          engramId: engramId,
        );
        try {
          if (!printLog(store, operands.last, stdout)) exitCode = 1;
        } finally {
          store.close();
        }
      case 'deliver':
        if (operands.length < 2 || operands.length > 3) {
          throw ArgumentError(
            'deliver needs a sender, a receiver, and optionally one note',
          );
        }
        final outcomes = await deliver(
          fromStorePath: resolveStorePath(operands[0], engramId: engramId),
          toStorePath: resolveStorePath(operands[1], engramId: engramId),
          note: operands.length == 3 ? operands[2] : null,
          out: stdout,
          force: options['force'] as bool,
        );
        if ((outcomes[DeliveryOutcome.failed] ?? 0) > 0) exitCode = 1;
      default:
        throw ArgumentError('unknown command: $command');
    }
  } on ArgumentError catch (error) {
    stderr.writeln('bfmon: ${error.message}');
    exitCode = 64;
  }
}

/// A one-store command's label: the argument as the user spelled it, last
/// segment only — `deviceB`, not `A`.
String _basename(String argument) {
  final segments = argument.split('/').where((s) => s.isNotEmpty).toList();
  if (segments.isEmpty) return argument;
  final last = segments.last;
  return last == 'metadata.db' && segments.length > 1
      ? segments[segments.length - 2]
      : last;
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
