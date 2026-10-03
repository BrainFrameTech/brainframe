import 'package:brainframe/engram/scan_detail.dart';
import 'package:flutter_test/flutter_test.dart';

/// The detail types: each reads back what it wrote, and anything else —
/// a row damaged, or written by a build that spelled it differently — as
/// no detail rather than an error.
void main() {
  final at = DateTime.utc(2026, 9, 30, 11, 54, 22, 123);
  final mint = Mint(peer: 'peer-a', at: at);

  test('each reads back what it wrote', () {
    expect(Mint.fromJson(mint.toJson()), mint);
    expect(
      MoveDetail.fromJson(const MoveDetail.identical().toJson()),
      const MoveDetail.identical(),
    );
    expect(
      MoveDetail.fromJson(const MoveDetail.similar(0.75).toJson()),
      const MoveDetail.similar(0.75),
    );
    final retirement = Retirement(
      winner: 'W',
      winnerMint: mint,
      loserMintedAt: at,
      loserChanges: 3,
    );
    expect(Retirement.fromJson(retirement.toJson()), retirement);
    const over = OverCeiling(sizeBytes: 10, ceilingBytes: 5);
    expect(OverCeiling.fromJson(over.toJson()), over);
  });

  test('a retirement without seed claims leaves their fields out', () {
    const bare = Retirement(
      winner: 'W',
      winnerMint: null,
      loserMintedAt: null,
      loserChanges: 0,
    );
    expect(bare.toJson().keys, unorderedEquals(['winner', 'loserChanges']));
    expect(Retirement.fromJson(bare.toJson()), bare);
  });

  test('a time is kept to the millisecond, in UTC', () {
    final local = Mint(peer: 'p', at: at.toLocal());
    final back = Mint.fromJson(local.toJson())!;
    expect(back.at.isUtc, isTrue);
    expect(back.at, at);
  });

  test('a similarity written as a whole number still reads', () {
    expect(
      MoveDetail.fromJson({'match': 'similar', 'similarity': 1}),
      const MoveDetail.similar(1),
    );
  });

  test('anything malformed is no detail, never an error', () {
    for (final json in <Object?>[
      null,
      'text',
      42,
      <String, Object?>{},
      {'peer': 1, 'at': 0},
      {'peer': 'p', 'at': '0'},
    ]) {
      expect(Mint.fromJson(json), isNull, reason: '$json');
    }
    for (final json in <Object?>[
      null,
      {'match': 'teleported'},
      {'match': 'similar'},
      {'match': 'similar', 'similarity': 'high'},
    ]) {
      expect(MoveDetail.fromJson(json), isNull, reason: '$json');
    }
    for (final json in <Object?>[
      null,
      {'winner': 'W'},
      {'winner': 1, 'loserChanges': 1},
    ]) {
      expect(Retirement.fromJson(json), isNull, reason: '$json');
    }
    for (final json in <Object?>[
      null,
      {'size': 1},
      {'size': '1', 'ceiling': 2},
    ]) {
      expect(OverCeiling.fromJson(json), isNull, reason: '$json');
    }
  });

  test('a time out of DateTime\'s range is no time, not an error', () {
    const beyond = 8640000000000001;
    expect(Mint.fromJson({'peer': 'p', 'at': beyond}), isNull);
    expect(Mint.fromJson({'peer': 'p', 'at': -beyond}), isNull);
    // The smallest int, whose abs() overflows to itself.
    expect(Mint.fromJson({'peer': 'p', 'at': -9223372036854775808}), isNull);
    final back = Retirement.fromJson({
      'winner': 'W',
      'winnerMint': {'peer': 'p', 'at': beyond},
      'loserMintedAt': beyond,
      'loserChanges': 1,
    })!;
    expect(back.winnerMint, isNull);
    expect(back.loserMintedAt, isNull);
  });

  test('a mint from a clock is null past DateTime\'s range', () {
    expect(
      Mint.fromClock('p', at.millisecondsSinceEpoch),
      Mint(peer: 'p', at: at),
    );
    expect(Mint.fromClock('p', 8640000000000001), isNull);
  });

  test('a retirement with a damaged mint keeps the rest', () {
    final back = Retirement.fromJson({
      'winner': 'W',
      'winnerMint': 'damaged',
      'loserMintedAt': 'damaged',
      'loserChanges': 2,
    })!;
    expect(back.winnerMint, isNull);
    expect(back.loserMintedAt, isNull);
    expect(back.loserChanges, 2);
  });

  test('each says what it holds', () {
    expect(mint.toString(), contains('peer-a'));
    expect(const MoveDetail.identical().toString(), contains('identical'));
    expect(const MoveDetail.similar(0.5).toString(), contains('0.5'));
    expect(
      const Retirement(
        winner: 'W',
        winnerMint: null,
        loserMintedAt: null,
        loserChanges: 1,
      ).toString(),
      contains('W'),
    );
    expect(
      const OverCeiling(sizeBytes: 10, ceilingBytes: 5).toString(),
      contains('10'),
    );
    expect({
      mint.hashCode,
      const MoveDetail.identical().hashCode,
      const OverCeiling(sizeBytes: 1, ceilingBytes: 1).hashCode,
      const Retirement(
        winner: 'W',
        winnerMint: null,
        loserMintedAt: null,
        loserChanges: 1,
      ).hashCode,
    }, hasLength(4));
  });
}
