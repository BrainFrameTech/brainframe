/// The one place line terminators are normalized on the way into a note.
///
/// Pure Dart: no filesystem, no `crdt_lf`, nothing to stub. It is its own
/// library rather than a private helper because Decision 10's rule is that
/// *every* path into a `fugueText` sequence calls the same function, and a
/// rule with one implementation is the only kind that stays true.
///
/// **Why normalize at all.** Terminators are ordinary content in the locked
/// storage model, so without this a file round-tripped through a Windows
/// editor comes back CRLF and reconciliation turns every line ending into a
/// real operation — a 100-line note yields 100 insertions, in a permanent log,
/// attributed to whichever device happened to reconcile. They propagate, the
/// other device's file is silently rewritten, and a tool that converts back
/// adds 100 more. Decision 10 in
/// [note-identity-and-crdt.md](../../../docs/design/note-identity-and-crdt.md)
/// records why the canonical form is LF on every platform rather than one
/// convention per platform.
library;

/// [text] with every `\r\n` reduced to `\n`.
///
/// **A lone `\r` is content and is left alone.** It is not a terminator
/// anywhere else in the system — the line splitter in the reconciliation diff
/// breaks only on `\n` — and treating it as one here would create a second,
/// disagreeing notion of where a line ends. A stray carriage return inside a
/// line is text the user typed, and it survives.
///
/// Returns [text] itself when there is nothing to change, which is the
/// overwhelmingly common case: this runs on every seed and every insert, and
/// the check is a scan for two bytes against an allocation and a copy.
String normalizeTerminators(String text) =>
    text.contains('\r\n') ? text.replaceAll('\r\n', '\n') : text;
