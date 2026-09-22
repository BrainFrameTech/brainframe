/// Web / no-`dart:io` stub: the web build has no standard output and receives
/// no command-line arguments, so `--help` never reaches this and there is
/// nothing to print. Kept as an inert return (not a throw) so the seam stays
/// harmless if it is ever reached.
void printHelpAndExit(String message) {}

/// Web has no standard error to write to, and no scan to narrate.
void traceLine(String line) {}

/// Web has no process environment to read.
String? environmentArgs() => null;
