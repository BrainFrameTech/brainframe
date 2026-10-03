/// What a device's name may be: its limits and how one is normalized (the
/// device names design, Decision 1).
///
/// Plain Dart, apart from the rest of `device_name.dart`, which reaches the
/// platform through Flutter: the map
/// file's reader needs these rules, and `bin/bfmon.dart` — a standalone Dart
/// CLI with no Flutter runtime — reaches that reader.
library;

// For `String.characters`: a name is cut by what a reader sees as
// characters, so an emoji or an accented letter is never split in two.
import 'package:characters/characters.dart';

/// The longest a device's name may be, in characters as a reader sees them:
/// enough for any hostname and any phone's name, short enough to fit a card
/// line.
const int deviceNameMaxLength = 64;

/// The longest a device's name may be in Unicode code points, beside
/// [deviceNameMaxLength].
///
/// **Why a second limit.** One character as a reader sees it can be any
/// number of code points — a letter followed by hundreds of combining marks
/// is still one. Counted only by [deviceNameMaxLength], such a name could be
/// stored and published whole here while another device, reading it back
/// with a bounded query, cut it shorter — and the two would disagree about
/// what this device is called. Capped in code points as well, and read back
/// with exactly this many, every name a device stores is read back
/// unchanged by every other. Four per character is far beyond any real
/// name, accents and emoji included.
const int deviceNameMaxCodePoints = deviceNameMaxLength * 4;

/// [raw] as a name may be stored: control characters made spaces, trimmed,
/// then as many whole characters as fit both [deviceNameMaxLength] and
/// [deviceNameMaxCodePoints]. A character is never split, so a cut never
/// leaves half an emoji or a stray accent. Null when nothing is left — which
/// is how a name is cleared, the next in the order then applying.
///
/// **No control characters**, NUL above all: SQLite's `substr` stops at a
/// NUL, so a name holding one would be stored whole here and read back cut
/// short by every other device. A tab or line break pasted into the field
/// becomes a space rather than running two words together.
///
/// Idempotent, so a name read back from another device and normalized again
/// is the name that device stored.
String? normalizeDeviceName(String? raw) {
  final trimmed = raw?.replaceAll(_controlCharacters, ' ').trim() ?? '';
  if (trimmed.isEmpty) return null;
  final kept = StringBuffer();
  var characters = 0;
  var codePoints = 0;
  for (final character in trimmed.characters) {
    final size = character.runes.length;
    if (characters == deviceNameMaxLength ||
        codePoints + size > deviceNameMaxCodePoints) {
      break;
    }
    kept.write(character);
    characters++;
    codePoints += size;
  }
  // Cutting can leave a trailing space where a word was split.
  final name = kept.toString().trimRight();
  return name.isEmpty ? null : name;
}

/// The C0 and C1 control characters, and DEL: never part of a name.
final RegExp _controlCharacters = RegExp('[\u0000-\u001F\u007F-\u009F]');
