import 'dart:io';

/// Prints [message] to standard output and terminates the process successfully.
///
/// Used for `--help`, which must emit its text and exit before any window is
/// created. Returns `Never`: the `exit(0)` ends the process, so nothing after
/// the call runs and callers need no `return` to say so.
Never printHelpAndExit(String message) {
  stdout.writeln(message);
  exit(0);
}

/// Writes [line] to standard error, for diagnostics that must reach a console
/// with nothing else attached — `--trace-scan`. Unbuffered by design: a line
/// held in a buffer when the OOM killer arrives is a line nobody reads.
void traceLine(String line) {
  stderr.writeln(line);
}

/// The raw `BRAINFRAME_ARGS` environment variable, or null when unset — the
/// argument channel for a host that gives `main` no `argv` (flutter-pi). See
/// [StartupOptions.splitEnvironmentArgs] for how it is read.
String? environmentArgs() => Platform.environment['BRAINFRAME_ARGS'];
