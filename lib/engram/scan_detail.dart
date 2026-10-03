/// The facts a scan event carries beyond its path (the device names design,
/// Decision 4): who made an identity and when, how a move was matched, what
/// an election or a conversion cost, how far a file was over the ceiling.
///
/// **Captured when the event is recorded, never looked up when it is shown.**
/// The identity map does not hold still — rows are renamed, deleted,
/// re-elected, and devices come and go — so a card read next month must say
/// what was true when it happened, and only the moment of recording knows.
///
/// Plain Dart, with no SQLite and no CRDT types, so the UI can read them: a
/// peer is the text of its ID, and a time is a UTC [DateTime]. Each is a few
/// fields; none holds a list, so a detail is tens of bytes however large the
/// engram.
library;

/// A note's seed claim, as a card shows it: who seeded its history, and
/// when.
///
/// **The seeder of the current history, not always the first minter.** For
/// a note never converted they are the same device and moment, which is
/// every case an election decides. A conversion to a plain file starts a
/// new epoch under the same ULID and takes a fresh claim, so after one this
/// names the converting device. The identity map keeps no other record of
/// the original mint, so there is nothing truer to capture; a card says
/// "seeded", not "created", where the difference could show.
class Mint {
  const Mint({required this.peer, required this.at});

  /// A mint at [millis] after the epoch, UTC; null when no [DateTime] can
  /// hold it — a clock read from another device's file is input.
  static Mint? fromClock(String peer, int millis) {
    final when = _utc(millis);
    return when == null ? null : Mint(peer: peer, at: when);
  }

  /// The seeding device's peer ID, as text.
  final String peer;

  /// When it seeded, UTC — the claim's clock, to the millisecond.
  final DateTime at;

  Map<String, Object?> toJson() => {
    'peer': peer,
    'at': at.toUtc().millisecondsSinceEpoch,
  };

  /// Null for anything that is not a mint as [toJson] writes one.
  static Mint? fromJson(Object? json) {
    if (json is! Map) return null;
    final peer = json['peer'];
    final at = json['at'];
    final when = _utc(at);
    if (peer is! String || when == null) return null;
    return Mint(peer: peer, at: when);
  }

  @override
  bool operator ==(Object other) =>
      other is Mint && other.peer == peer && other.at == at;

  @override
  int get hashCode => Object.hash(peer, at);

  @override
  String toString() => 'Mint($peer at ${at.toIso8601String()})';
}

/// How a moved note was recognized at its new path.
enum MoveMatch {
  /// The same content hash: a rename, nothing else.
  identical,

  /// The content sketch: a rename with an edit, reconciled as drift too.
  similar,
}

/// How a move was matched, and — for a sketch match — how close it was.
class MoveDetail {
  const MoveDetail.identical() : match = MoveMatch.identical, similarity = null;

  const MoveDetail.similar(double this.similarity) : match = MoveMatch.similar;

  final MoveMatch match;

  /// The sketch similarity, 0–1, for a [MoveMatch.similar] match; null for
  /// an identical one.
  final double? similarity;

  Map<String, Object?> toJson() => {
    'match': match.name,
    if (similarity != null) 'similarity': similarity,
  };

  static MoveDetail? fromJson(Object? json) {
    if (json is! Map) return null;
    final similarity = json['similarity'];
    return switch (json['match']) {
      'identical' => const MoveDetail.identical(),
      'similar' when similarity is num => MoveDetail.similar(
        similarity.toDouble(),
      ),
      _ => null,
    };
  }

  @override
  bool operator ==(Object other) =>
      other is MoveDetail &&
      other.match == match &&
      other.similarity == similarity;

  @override
  int get hashCode => Object.hash(match, similarity);

  @override
  String toString() => similarity == null
      ? 'MoveDetail(${match.name})'
      : 'MoveDetail(${match.name}, $similarity)';
}

/// A lost identity election: who won, and what losing cost.
class Retirement {
  const Retirement({
    required this.winner,
    required this.winnerMint,
    required this.loserMintedAt,
    required this.loserChanges,
  });

  /// The winning identity's ULID.
  final String winner;

  /// Who minted the winner, and when; null when its row carries no seed
  /// claim.
  final Mint? winnerMint;

  /// When this device minted the identity it gave up, UTC; null when its
  /// row carried no seed claim.
  final DateTime? loserMintedAt;

  /// How many changes the retired identity's op-log held — one, its seed,
  /// in the case the election mostly serves, which is "nothing was lost".
  final int loserChanges;

  Map<String, Object?> toJson() => {
    'winner': winner,
    if (winnerMint != null) 'winnerMint': winnerMint!.toJson(),
    if (loserMintedAt != null)
      'loserMintedAt': loserMintedAt!.toUtc().millisecondsSinceEpoch,
    'loserChanges': loserChanges,
  };

  static Retirement? fromJson(Object? json) {
    if (json is! Map) return null;
    final winner = json['winner'];
    final loserMintedAt = json['loserMintedAt'];
    final loserChanges = json['loserChanges'];
    if (winner is! String || loserChanges is! int) return null;
    return Retirement(
      winner: winner,
      winnerMint: Mint.fromJson(json['winnerMint']),
      loserMintedAt: _utc(loserMintedAt),
      loserChanges: loserChanges,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is Retirement &&
      other.winner == winner &&
      other.winnerMint == winnerMint &&
      other.loserMintedAt == loserMintedAt &&
      other.loserChanges == loserChanges;

  @override
  int get hashCode =>
      Object.hash(winner, winnerMint, loserMintedAt, loserChanges);

  @override
  String toString() =>
      'Retirement(to $winner, $winnerMint, loser minted $loserMintedAt, '
      '$loserChanges change(s))';
}

/// A file found over the note size ceiling: how large, against what.
class OverCeiling {
  const OverCeiling({required this.sizeBytes, required this.ceilingBytes});

  /// The file's size on disk, from the stat that decided it.
  final int sizeBytes;

  /// The engram's ceiling at the time.
  final int ceilingBytes;

  Map<String, Object?> toJson() => {'size': sizeBytes, 'ceiling': ceilingBytes};

  static OverCeiling? fromJson(Object? json) {
    if (json is! Map) return null;
    final size = json['size'];
    final ceiling = json['ceiling'];
    if (size is! int || ceiling is! int) return null;
    return OverCeiling(sizeBytes: size, ceilingBytes: ceiling);
  }

  @override
  bool operator ==(Object other) =>
      other is OverCeiling &&
      other.sizeBytes == sizeBytes &&
      other.ceilingBytes == ceilingBytes;

  @override
  int get hashCode => Object.hash(sizeBytes, ceilingBytes);

  @override
  String toString() => 'OverCeiling($sizeBytes > $ceilingBytes)';
}

/// The UTC time [millis] milliseconds after the epoch, or null for anything
/// that is not one: not an integer, or beyond what a [DateTime] can hold —
/// which would otherwise throw, and take every card in the history with it.
DateTime? _utc(Object? millis) {
  const limit = 8640000000000000; // DateTime's range, either side of 1970
  // Compared both ways, never by abs(): the smallest int's abs() overflows
  // to itself, negative, and would pass.
  if (millis is! int || millis < -limit || millis > limit) return null;
  return DateTime.fromMillisecondsSinceEpoch(millis, isUtc: true);
}
