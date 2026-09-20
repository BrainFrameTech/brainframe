import 'dart:io';

/// Prints [message] to standard output and terminates the process successfully.
///
/// Used for `--help`, which must emit its text and exit before any window is
/// created. Declared `void` (not `Never`) to match the web stub's signature, so
/// the shared seam presents one API and callers need no platform branch; the
/// `exit(0)` still ends the process, so nothing after the call runs.
void printHelpAndExit(String message) {
  stdout.writeln(message);
  exit(0);
}

/// Writes [line] to standard error, for diagnostics that must reach a console
/// with nothing else attached — `--trace-scan`. Unbuffered by design: a line
/// held in a buffer when the OOM killer arrives is a line nobody reads.
void traceLine(String line) {
  stderr.writeln(line);
}
