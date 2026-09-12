/// The content sketch: a fixed-width MinHash signature of a note's text, used
/// to recognise a note that was renamed *and* edited in one offline window
/// (Decision 7).
///
/// Pure Dart. Every byte of meaning in the catalog's `sketch` column is
/// assigned here — the column is an untyped `BLOB` precisely so that this file
/// owns the format and step 3's storage never had to know it.
///
/// **What it is for, and what it is not.** A gone catalog path plus a new file
/// whose content hash matches is a move, exactly as `git` detects one. When
/// the content changed too, the hash cannot say, and the sketch is the
/// second question: "of the notes that went missing in this scan, is this new
/// file most of one of them?" That is a pairwise comparison against a handful
/// of candidates, never a nearest-neighbour search over the engram, which is
/// why there is no banding, no LSH index, and no table — one blob per note,
/// compared in a loop.
///
/// **The shingles are never stored.** A note's set of word trigrams is roughly
/// the size of the note; the signature is [sketchWidth] slots regardless of
/// length. MinHash keeps, per slot, the minimum of a distinct hash function
/// over every shingle, and the fraction of slots two signatures agree on is
/// an unbiased estimate of the Jaccard similarity of the shingle sets.
///
/// **The parameters were chosen against `test/fixtures/engram`, biased toward
/// missing a match.** Too low a cutoff re-associates unrelated notes and
/// merges their histories, which is strictly worse than a missed rename — a
/// missed rename costs one note's history and is surfaced; a false match
/// silently corrupts two. The numbers, and the fixture measurements that
/// justify them, are in `sketch_test.dart`.
library;

import 'dart:typed_data';

import 'line_terminators.dart';

/// Format version, the sketch's first byte. A sketch of any other version is
/// treated as absent: the rest of the bytes mean nothing to this build.
const int sketchVersion = 1;

/// Words per shingle. Three is the usual choice for prose: two is too
/// forgiving of reordering, four too sensitive to a single changed word.
const int shingleWords = 3;

/// Slots in the signature. At 128 the standard error of the similarity
/// estimate is about 0.044 at the cutoff, small next to the gap the fixture
/// shows between related and unrelated notes.
const int sketchWidth = 128;

/// Bytes per slot: the low 32 bits of the 64-bit minimum. Equality of two
/// minima is what the comparison needs, and a 32-bit collision between
/// unequal minima is one in four billion per slot.
const int _slotBytes = 4;

/// The estimated similarity at or above which a new file is taken to be a
/// missing note renamed and edited, and the note's identity and history are
/// carried across.
///
/// Measured against the fixture engram, whose notes run from 44 to 670 words:
/// no two distinct notes score above 0.12; a note with a paragraph appended
/// scores at least 0.67 and one with its first fifth deleted at least 0.71;
/// one with every fifth line rewritten can fall to 0.43 and one with every
/// third line rewritten to 0.20. The cutoff sits four times the unrelated
/// maximum and catches the first two edits but not the last two — deliberately,
/// because the two failure modes are not symmetric (see the library comment).
/// A rewrite that heavy has changed most of the note's shingles, and losing
/// its history is the surfaced, recoverable cost; attaching the wrong history
/// is the silent one.
///
/// **Known limit: template-heavy stubs.** Similarity is over words, so two
/// short notes that share a large template (a daily-note skeleton with a line
/// or two of content each) can score above this from the template alone. The
/// comparison only ever runs against notes that went missing in the same scan,
/// which bounds the exposure to "deleted one stub and created another before
/// the next scan", but it does not remove it. Weighting shingles by rarity
/// would; nothing needs it yet.
const double renameSimilarityCutoff = 0.5;

/// The [sketchWidth] hash functions, as pairs `(a, b)` of a wrapping affine
/// map `h ↦ a·h + b` over 64-bit integers. With `a` odd the map is a bijection
/// of the 64-bit integers, so each slot is a genuine permutation of the
/// shingle hashes, which is what MinHash's estimate rests on.
///
/// **Every constant from here to the end of the file is part of the on-disk
/// format.** A sketch written today must compare with one computed years from
/// now, so the numbers must never change, and so each of them has to be
/// something with a name and an origin rather than a value someone typed:
///
/// - **The seed, `0x9E3779B97F4A7C15`, is ⌊2⁶⁴ / φ⌋** — the golden ratio
///   scaled to 64 bits. It is the conventional seed and increment for 64-bit
///   mixers (SplitMix64's Weyl increment, Knuth's multiplicative hashing),
///   chosen because its bits are as far as a constant can be from any
///   pattern a shift-and-xor generator might resonate with.
/// - **The generator is xorshift64\*, exactly as published**: Marsaglia's
///   shift triple `13, 7, 17` scrambled to `12, 25, 27` and the multiplier
///   `0x2545F4914F6CDD1D`, from Vigna, *An experimental exploration of
///   Marsaglia's xorshift generators, scrambled*, ACM TOMS 42(4), 2016. A
///   written-out generator rather than `dart:math`'s `Random(seed)` because
///   the latter's algorithm is an implementation detail, not a contract, and
///   this one has to be reproducible on every VM forever.
/// - **The string hash is FNV-1a**, at the end of the file, with its
///   published 64-bit offset basis and prime.
///
/// One stream supplies both lists: the first [sketchWidth] draws are the
/// multipliers (forced odd), the next [sketchWidth] the offsets. A second
/// seed would be a second constant to account for, for nothing.
final List<int> _multipliers = _permutationConstants.sublist(0, sketchWidth);
final List<int> _offsets = _permutationConstants.sublist(sketchWidth);

final List<int> _permutationConstants = () {
  var state = 0x9E3779B97F4A7C15;
  return List<int>.generate(2 * sketchWidth, (i) {
    state ^= state >>> 12;
    state ^= state << 25;
    state ^= state >>> 27;
    final value = state * 0x2545F4914F6CDD1D;
    // A multiplier must be odd to be a bijection mod 2^64; an offset may be
    // anything.
    return i < sketchWidth ? value | 1 : value;
  });
}();

/// The signature of [text], as the bytes the catalog stores.
///
/// The text is normalized to LF first (Decision 10), then split into words on
/// whitespace, then shingled into runs of [shingleWords]. A note shorter than
/// one shingle contributes its whole word sequence as its only shingle; a
/// note with no words at all yields a sketch with no slots, which
/// [sketchSimilarity] never matches to anything — an empty note has no
/// history worth carrying and no content to be similar to.
Uint8List computeSketch(String text) {
  final words = normalizeTerminators(
    text,
  ).split(RegExp(r'\s+')).where((word) => word.isNotEmpty).toList();
  if (words.isEmpty) return Uint8List.fromList(const [sketchVersion]);

  final shingleCount = words.length <= shingleWords
      ? 1
      : words.length - shingleWords + 1;
  final minima = List<int>.filled(sketchWidth, _unsetMinimum);
  for (var i = 0; i < shingleCount; i++) {
    final shingle = words
        .sublist(i, (i + shingleWords).clamp(0, words.length))
        .join(' ');
    final h = _fnv1a64(shingle);
    for (var slot = 0; slot < sketchWidth; slot++) {
      final permuted = _multipliers[slot] * h + _offsets[slot];
      // Unsigned comparison: the affine map wraps, so the sign bit is just
      // another bit and a signed compare would bias every slot toward the
      // "negative" half of the range.
      if (_unsignedLess(permuted, minima[slot])) minima[slot] = permuted;
    }
  }

  final bytes = ByteData(1 + sketchWidth * _slotBytes);
  bytes.setUint8(0, sketchVersion);
  for (var slot = 0; slot < sketchWidth; slot++) {
    bytes.setUint32(
      1 + slot * _slotBytes,
      minima[slot] & 0xFFFFFFFF,
      Endian.little,
    );
  }
  return bytes.buffer.asUint8List();
}

/// The estimated Jaccard similarity of the texts behind two sketches, in
/// `[0, 1]`.
///
/// Zero — never a match — when either sketch is missing, of another version,
/// malformed, or empty. Every one of those is "we cannot say", and the answer
/// to "cannot say" is the conservative one.
double sketchSimilarity(Uint8List? a, Uint8List? b) {
  if (a == null || b == null) return 0;
  if (!_wellFormed(a) || !_wellFormed(b)) return 0;
  if (a.length == 1 || b.length == 1) return 0;
  final av = ByteData.sublistView(a, 1);
  final bv = ByteData.sublistView(b, 1);
  var agree = 0;
  for (var slot = 0; slot < sketchWidth; slot++) {
    final offset = slot * _slotBytes;
    if (av.getUint32(offset, Endian.little) ==
        bv.getUint32(offset, Endian.little)) {
      agree++;
    }
  }
  return agree / sketchWidth;
}

bool _wellFormed(Uint8List sketch) =>
    sketch.isNotEmpty &&
    sketch[0] == sketchVersion &&
    (sketch.length == 1 || sketch.length == 1 + sketchWidth * _slotBytes);

/// All ones: larger than every value under unsigned comparison.
const int _unsetMinimum = -1;

bool _unsignedLess(int a, int b) => (a ^ _signBit) < (b ^ _signBit);

const int _signBit = 0x8000000000000000;

/// FNV-1a over the string's UTF-16 code units, 64-bit, wrapping: the
/// Fowler–Noll–Vo hash, with the published 64-bit offset basis
/// `0xcbf29ce484222325` and prime `0x100000001b3`. Chosen for being tiny,
/// well understood, and fully specified — a shingle hash needs to spread
/// similar strings apart and nothing more, and this is part of the format.
int _fnv1a64(String s) {
  var hash = 0xcbf29ce484222325;
  for (var i = 0; i < s.length; i++) {
    hash ^= s.codeUnitAt(i);
    hash *= 0x100000001b3;
  }
  return hash;
}
