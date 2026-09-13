// Generates lib/l10n/app_en_XA.arb — a pseudo-locale — from the template
// lib/l10n/app_en.arb. Pseudo-localization accents every letter, expands the
// text ~40%, and brackets it, so during development a glance reveals strings
// that are still hardcoded (they stay plain ASCII), truncated (the closing
// bracket vanishes), or too tight to fit a longer translation.
//
// It is generated, never hand-edited: the enforcement gate (tool/check_l10n.dart)
// fails if the checked-in app_en_XA.arb drifts from this generator's output, so
// the pseudo-locale is always in perfect key-sync with the template. Placeholders
// ({name}) and ICU keywords are left untouched so substitution still works.
//
// Run manually with: dart run tool/gen_pseudo_arb.dart
import 'dart:convert';
import 'dart:io';

/// Latin look-alikes for pseudo-localization. Letters with no entry (e.g. q, x)
/// pass through unchanged — full coverage is unnecessary for the visual signal.
const Map<String, String> _accents = {
  'a': 'á', 'b': 'ƀ', 'c': 'ç', 'd': 'đ', 'e': 'é', 'f': 'ƒ', 'g': 'ǵ',
  'h': 'ħ', 'i': 'í', 'j': 'ĵ', 'k': 'ķ', 'l': 'ł', 'm': 'ɱ', 'n': 'ñ',
  'o': 'ó', 'p': 'þ', 'r': 'ŕ', 's': 'š', 't': 'ŧ', 'u': 'ú', 'w': 'ŵ',
  'y': 'ý', 'z': 'ž',
  'A': 'Á', 'B': 'Ɓ', 'C': 'Ç', 'D': 'Đ', 'E': 'É', 'F': 'Ƒ', 'G': 'Ǵ',
  'H': 'Ħ', 'I': 'Í', 'J': 'Ĵ', 'K': 'Ķ', 'L': 'Ł', 'M': 'Ḿ', 'N': 'Ñ',
  'O': 'Ó', 'P': 'Þ', 'R': 'Ŕ', 'S': 'Š', 'T': 'Ŧ', 'U': 'Ú', 'W': 'Ŵ',
  'Y': 'Ý', 'Z': 'Ž',
};

/// The head of an ICU plural or select block: `{count, plural, ` up to and
/// including the second comma. What follows is a run of `key{text}` cases.
final RegExp _pluralHead = RegExp(r'^\s*\w+\s*,\s*(plural|select)\s*,');

/// One case inside a plural or select block: its key (`=0`, `one`, `other`,
/// or a select value) up to the brace that opens its text.
final RegExp _caseKey = RegExp(r'\s*(=\d+|\w+)\s*\{');

String _accent(String text) {
  final buffer = StringBuffer();
  for (final rune in text.runes) {
    final ch = String.fromCharCode(rune);
    buffer.write(_accents[ch] ?? ch);
  }
  return buffer.toString();
}

/// Pseudo-localizes one message: accents letters (outside `{placeholders}`),
/// pads ~40% to expose overflow, and brackets the whole so truncation shows.
///
/// ICU plural and select blocks keep their structure — the argument, the
/// keyword, and every case key stay verbatim, since the ICU parser needs them
/// — and only the text inside each case is accented. Anything else in braces
/// is a placeholder and is copied through.
String pseudoLocalize(String message) {
  final buffer = StringBuffer('[');
  final visibleLetters = _localize(message, buffer);
  buffer.write('~' * ((visibleLetters * 0.4).round()));
  buffer.write(']');
  return buffer.toString();
}

/// Writes the pseudo-localized [message] to [out] and returns how many
/// non-whitespace letters were accented, which sizes the padding.
int _localize(String message, StringBuffer out) {
  var visibleLetters = 0;
  var index = 0;
  while (index < message.length) {
    final open = message.indexOf('{', index);
    if (open == -1) break;
    final close = _matchingBrace(message, open);
    final segment = message.substring(index, open);
    out.write(_accent(segment));
    visibleLetters += _letters(segment);
    final inner = message.substring(open + 1, close);
    final head = _pluralHead.firstMatch(inner);
    if (head == null) {
      out.write(message.substring(open, close + 1)); // a placeholder
    } else {
      out.write('{${inner.substring(0, head.end)}');
      visibleLetters += _localizeCases(inner.substring(head.end), out);
      out.write('}');
    }
    index = close + 1;
  }
  final tail = message.substring(index);
  out.write(_accent(tail));
  return visibleLetters + _letters(tail);
}

/// Writes the cases of a plural or select block, keys verbatim and texts
/// localized, and returns the letters accented.
int _localizeCases(String cases, StringBuffer out) {
  var visibleLetters = 0;
  var index = 0;
  while (index < cases.length) {
    final key = _caseKey.matchAsPrefix(cases, index);
    if (key == null) {
      out.write(cases.substring(index)); // trailing whitespace, or malformed
      break;
    }
    final open = key.end - 1;
    final close = _matchingBrace(cases, open);
    out.write(cases.substring(index, key.end));
    visibleLetters += _localize(cases.substring(open + 1, close), out);
    out.write('}');
    index = close + 1;
  }
  return visibleLetters;
}

/// The index of the `}` that closes the `{` at [open], allowing for nesting.
/// A message that never closes it is malformed, and the whole rest of the
/// message is taken as the block so the error surfaces in gen-l10n's output
/// rather than being silently mangled here.
int _matchingBrace(String text, int open) {
  var depth = 0;
  for (var i = open; i < text.length; i++) {
    if (text[i] == '{') depth++;
    if (text[i] == '}' && --depth == 0) return i;
  }
  return text.length - 1;
}

int _letters(String text) => text.replaceAll(RegExp(r'\s'), '').length;

/// Builds the pseudo-locale ARB JSON from the template ARB [templateJson].
/// Keeps `@@locale` (rewritten to `en_XA`) and every message, drops the
/// `@`-metadata (only the template carries descriptions/placeholders). The
/// output is deterministic so a freshness check can compare it byte-for-byte.
String buildPseudoArb(String templateJson) {
  final template = jsonDecode(templateJson) as Map<String, dynamic>;
  final out = <String, dynamic>{'@@locale': 'en_XA'};
  for (final entry in template.entries) {
    if (entry.key.startsWith('@')) continue; // @@locale + @-metadata
    out[entry.key] = pseudoLocalize(entry.value as String);
  }
  return '${const JsonEncoder.withIndent('  ').convert(out)}\n';
}

void main() {
  final template = File('lib/l10n/app_en.arb');
  if (!template.existsSync()) {
    stderr.writeln('gen_pseudo_arb: template not found at ${template.path}');
    exit(1);
  }
  final output = File('lib/l10n/app_en_XA.arb');
  output.writeAsStringSync(buildPseudoArb(template.readAsStringSync()));
  stdout.writeln('gen_pseudo_arb: wrote ${output.path}');
}
