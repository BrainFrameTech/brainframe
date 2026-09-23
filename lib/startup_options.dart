import 'dart:ui' show Size;

import 'package:args/args.dart';

/// Startup options parsed from the process command line.
///
/// Desktop only in practice — Flutter forwards `argv` to `main` on desktop,
/// while mobile always starts `main` with an empty list — but parsing is pure
/// string work with no `dart:io`, so it is unit-testable and safe to run on
/// every platform (an empty list yields the default behavior).
///
/// These options exist for development and testing. See [engramPath],
/// [ignoreConfig], [windowSize], and [showHelp].
class StartupOptions {
  const StartupOptions({
    this.engramPath,
    this.ignoreConfig = false,
    this.windowSize,
    this.windowTitle,
    this.traceScan = false,
    this.showHelp = false,
  });

  /// An explicit engram folder to open at startup (`--engram <path>` or
  /// `--engram=<path>`), bypassing the normally remembered last-opened engram.
  /// Null when the flag is absent or empty.
  ///
  /// The override is transient: it is not added to the registry or recorded as
  /// the last-opened engram, so a later ordinary launch resolves as usual.
  final String? engramPath;

  /// Start without reading or writing the saved configuration
  /// (`--ignore-config`). When set, the app backs its preferences with an
  /// ephemeral in-memory store, so the real engram registry, last-opened
  /// engram, window geometry, and theme are neither loaded nor overwritten.
  final bool ignoreConfig;

  /// An explicit startup size for the desktop window
  /// (`--window-size <W>x<H>`), overriding both the remembered geometry and
  /// the built-in default. Null when the flag is absent, malformed, or
  /// non-positive.
  ///
  /// The override is transient in both directions: a session started with it
  /// neither restores the saved geometry nor records the one it was given, so
  /// a size chosen for a screen recording never becomes the size the app
  /// opens at afterwards. Sizes below the window's minimum are clamped by the
  /// window manager, not rejected here.
  final Size? windowSize;

  /// An explicit title for the desktop window (`--window-title <text>`),
  /// replacing the application's name. Null when the flag is absent or
  /// blank.
  ///
  /// For telling two instances apart — "BrainFrame A" and "BrainFrame B"
  /// over one engram folder, in the task switcher and in a screen recording
  /// — and nothing else: it is not remembered, not localized, and not shown
  /// anywhere but the window frame and the switcher.
  final String? windowTitle;

  /// Narrate the drift scan on standard error, one line per note, before the
  /// note is touched (`--trace-scan`). A diagnostic for a target with no
  /// debugger attached: when a scan takes the process down — out of memory
  /// on a small board — the last line names the file it was on, which the
  /// kernel's report never does.
  final bool traceScan;

  /// Print [usage] and exit without starting the app (`--help` or `-h`). When
  /// set it takes precedence over every other option.
  final bool showHelp;

  /// Parses [args] with [ArgParser], recognizing `--engram <path>` /
  /// `--engram=<path>`, `--ignore-config`, `--window-size <W>x<H>`,
  /// `--window-title <text>`, `--trace-scan`, and `--help` / `-h`.
  ///
  /// Never throws: if [args] can't be parsed — an unknown option, a malformed
  /// value — it falls back to defaults so a stray or injected argument can never
  /// stop the app from launching. (Bare positional arguments are simply ignored
  /// and do not trigger the fallback.)
  ///
  /// A malformed `--window-size` value is dropped on its own rather than
  /// discarding the whole command line: the other options were still spelled
  /// correctly, and losing `--ignore-config` over a typo in an unrelated flag
  /// would be the more damaging failure.
  factory StartupOptions.parse(List<String> args) {
    final ArgResults results;
    try {
      results = _parser.parse(args);
    } on ArgParserException {
      // Launch anyway on a bad argument rather than aborting a GUI app.
      return const StartupOptions();
    }
    final engram = results['engram'] as String?;
    final title = (results['window-title'] as String?)?.trim();
    return StartupOptions(
      engramPath: (engram != null && engram.isNotEmpty) ? engram : null,
      ignoreConfig: results['ignore-config'] as bool,
      windowSize: _parseWindowSize(results['window-size'] as String?),
      windowTitle: (title != null && title.isNotEmpty) ? title : null,
      traceScan: results['trace-scan'] as bool,
      showHelp: results['help'] as bool,
    );
  }

  /// Splits the `BRAINFRAME_ARGS` environment variable into arguments, for
  /// a host that starts `main` with an empty list.
  ///
  /// flutter-pi is the case: it hands everything after the bundle path to
  /// the engine as switches and passes **no** arguments to the Dart
  /// entrypoint, so on that target the only channel into [parse] is the
  /// environment. `main` prepends what this returns to `argv`, so on a
  /// desktop the variable is honoured too and an explicit argument wins.
  ///
  /// Whitespace-separated, nothing more: no quoting, no escapes. A path with
  /// a space in it cannot be passed this way, which is an accepted limit of
  /// a diagnostic channel rather than a reason to grow a shell parser.
  static List<String> splitEnvironmentArgs(String? value) {
    if (value == null) return const [];
    return value.split(RegExp(r'\s+')).where((a) => a.isNotEmpty).toList();
  }

  /// Human-readable usage text for `--help`, printed to the terminal before
  /// Flutter starts (plain output, not a localized UI string). The options block
  /// is generated by [ArgParser] from [_parser], so it can never drift from the
  /// flags actually recognized.
  static final String usage =
      '''
BrainFrame — an open-source Second Brain / E-Reader.

Usage: brainframe [options]

${_parser.usage}

These options apply to desktop builds; mobile ignores them. A host that
passes no arguments to the app (flutter-pi) reads them from the BRAINFRAME_ARGS
environment variable instead, whitespace-separated.''';
}

/// The argument grammar, shared by [StartupOptions.parse] and
/// [StartupOptions.usage] so parsing and help text stay in lockstep.
final ArgParser _parser = ArgParser(usageLineLength: 80)
  ..addOption(
    'engram',
    valueHelp: 'path',
    help:
        'Open the engram at <path> at startup instead of the last-opened '
        'one. If <path> is a plain folder it is turned into an engram in '
        'place. Transient: not remembered next run.',
  )
  ..addFlag(
    'ignore-config',
    negatable: false,
    help:
        'Start without reading or writing saved configuration — the engram '
        'registry, last-opened engram, window geometry, and theme. Handy for '
        'a clean-slate testing session.',
  )
  ..addOption(
    'window-size',
    valueHelp: 'WxH',
    help:
        'Open the window at <W>x<H> logical pixels (e.g. 1600x1000) instead '
        'of the remembered size. Transient: the saved geometry is neither '
        'read nor overwritten, so a size used for a recording does not '
        'become the size the app opens at next time.',
  )
  ..addOption(
    'window-title',
    valueHelp: 'text',
    help:
        'Title the desktop window <text> instead of the application name, '
        'to tell two instances apart. Transient: not remembered.',
  )
  ..addFlag(
    'trace-scan',
    negatable: false,
    help:
        'Narrate the drift scan on standard error: one line per note, '
        'written before the note is touched, so a scan that crashes the '
        'process leaves the name of the file it was on. Diagnostic; noisy '
        'on a large engram.',
  )
  ..addFlag(
    'help',
    abbr: 'h',
    negatable: false,
    help: 'Print this message and exit.',
  );

/// Parses a `<width>x<height>` value into a [Size], or null if it is absent or
/// does not describe a positive whole-pixel size.
///
/// Deliberately strict — `1600x1000` only. Accepting decimals or stray
/// whitespace would invite values that survive parsing but land the window
/// somewhere unintended, and a rejected value degrades to the ordinary startup
/// size rather than to something surprising.
Size? _parseWindowSize(String? value) {
  if (value == null) return null;
  final match = RegExp(r'^(\d+)[xX](\d+)$').firstMatch(value);
  if (match == null) return null;
  final width = int.parse(match.group(1)!);
  final height = int.parse(match.group(2)!);
  if (width <= 0 || height <= 0) return null;
  return Size(width.toDouble(), height.toDouble());
}
