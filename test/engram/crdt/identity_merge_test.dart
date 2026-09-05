import 'package:brainframe/engram/crdt/catalog.dart';
import 'package:brainframe/engram/crdt/identity_map.dart';
import 'package:brainframe/engram/crdt/identity_merge.dart';
import 'package:brainframe/engram/id.dart';
import 'package:crdt_lf/crdt_lf.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hlc_dart/hlc_dart.dart';

import '../../crdt/support/peer_ids.dart';

/// The two merge rules, and what a device does about a note as a result.
void main() {
  OperationId stamp(PeerId peer, int millis) =>
      OperationId(peer, HybridLogicalClock(l: millis, c: 0));

  /// ULIDs that sort in the order given, so "lowest wins" is legible by eye.
  String ulidAt(int order) =>
      newUlid(timestamp: DateTime.utc(2026, 1, 1).add(Duration(days: order)));

  IdentityRow row({
    required String ulid,
    String path = 'inbox/today.md',
    MergePolicy mergePolicy = MergePolicy.fugueText,
    OperationId? recordedAt,
    bool deleted = false,
    OperationId? seedClaim,
  }) => IdentityRow(
    ulid: ulid,
    path: path,
    mergePolicy: mergePolicy,
    recordedAt: recordedAt ?? stamp(peerA, 100),
    deleted: deleted,
    seedClaim: seedClaim,
  );

  group('rule 1 — contradictions about one ULID', () {
    test('the later claim wins on HLC', () {
      final ulid = ulidAt(0);
      final merged = mergeIdentity([
        row(ulid: ulid, path: 'old.md', recordedAt: stamp(peerA, 100)),
        row(ulid: ulid, path: 'new.md', recordedAt: stamp(peerB, 200)),
      ]);

      expect(merged.forUlid(ulid)!.path, 'new.md');
    });

    test('an equal HLC falls through to the peerID', () {
      // The comparator, not a second ordering written here: HLC first, peerID
      // second, exactly as the frozen suite pins it.
      final ulid = ulidAt(0);
      final merged = mergeIdentity([
        row(ulid: ulid, path: 'from-a.md', recordedAt: stamp(peerA, 100)),
        row(ulid: ulid, path: 'from-b.md', recordedAt: stamp(peerB, 100)),
      ]);

      expect(merged.forUlid(ulid)!.path, 'from-b.md');
    });

    test('the winner is independent of the order rows are read in', () {
      final ulid = ulidAt(0);
      final rows = [
        row(ulid: ulid, path: 'a.md', recordedAt: stamp(peerA, 100)),
        row(ulid: ulid, path: 'b.md', recordedAt: stamp(peerB, 300)),
        row(ulid: ulid, path: 'c.md', recordedAt: stamp(peerC, 200)),
      ];

      // Every reader must reach the same answer from the same set of files,
      // and directory listing order is not a guarantee anyone offers.
      expect(mergeIdentity(rows).forUlid(ulid)!.path, 'b.md');
      expect(mergeIdentity(rows.reversed).forUlid(ulid)!.path, 'b.md');
    });

    test('a deletion is an ordinary field update', () {
      final ulid = ulidAt(0);
      final merged = mergeIdentity([
        row(ulid: ulid, recordedAt: stamp(peerA, 100)),
        row(ulid: ulid, recordedAt: stamp(peerB, 200), deleted: true),
      ]);

      expect(merged.forUlid(ulid)!.deleted, isTrue);
    });

    test('a non-minting device\'s rename propagates', () {
      // Device B notices a rename of a note A minted. B cannot write A's file,
      // so it writes its own row — and without the stamp there would be no way
      // to tell B's newer claim from A's older one. Nothing surfaces when this
      // breaks: a third device would simply keep the stale path and, finding
      // nothing at the new one, mint a second ULID for the same file.
      final ulid = ulidAt(0);
      final merged = mergeIdentity([
        row(
          ulid: ulid,
          path: 'trails/cedar.md',
          recordedAt: stamp(peerA, 100),
          seedClaim: stamp(peerA, 100),
        ),
        row(
          ulid: ulid,
          path: 'journal/cedar.md',
          recordedAt: stamp(peerB, 200),
          seedClaim: stamp(peerA, 100),
        ),
      ]);

      expect(merged.forUlid(ulid)!.path, 'journal/cedar.md');
      expect(merged.forPath('journal/cedar.md')!.ulid, ulid);
      expect(merged.forPath('trails/cedar.md'), isNull);
      expect(
        merged.forUlid(ulid)!.seededBy,
        peerA,
        reason: 'recording a rename does not make B the seeder',
      );
    });
  });

  group('rule 2 — two live ULIDs claiming one path', () {
    test('the lowest ULID wins, and the other is retired', () {
      final earliest = ulidAt(0);
      final later = ulidAt(1);
      final merged = mergeIdentity([
        row(ulid: earliest, recordedAt: stamp(peerA, 100)),
        row(ulid: later, recordedAt: stamp(peerB, 999)),
      ]);

      // Not the comparator: this is an election between identities, so the
      // earliest mint survives rather than the latest claim — which is why a
      // much newer stamp on the loser changes nothing.
      expect(merged.forPath('inbox/today.md')!.ulid, earliest);
      expect(merged.retired, {later});
    });

    test('the retired ULID still exists', () {
      // Identity outlives the election: the losing device needs to recognise
      // its own ULID here in order to retire it.
      final earliest = ulidAt(0);
      final later = ulidAt(1);
      final merged = mergeIdentity([row(ulid: earliest), row(ulid: later)]);

      expect(merged.forUlid(later), isNotNull);
      expect(merged.forUlid(later)!.ulid, later);
    });

    test('three claimants elect one and retire two', () {
      final ulids = [ulidAt(0), ulidAt(1), ulidAt(2)];
      final merged = mergeIdentity([for (final u in ulids) row(ulid: u)]);

      expect(merged.forPath('inbox/today.md')!.ulid, ulids.first);
      expect(merged.retired, {ulids[1], ulids[2]});
    });

    test('an uncontested path retires nobody', () {
      final merged = mergeIdentity([
        row(ulid: ulidAt(0), path: 'a.md'),
        row(ulid: ulidAt(1), path: 'b.md'),
      ]);

      expect(merged.retired, isEmpty);
    });

    test('a deleted row does not contend for its path', () {
      final dead = ulidAt(0);
      final live = ulidAt(1);
      final merged = mergeIdentity([
        row(ulid: dead, deleted: true),
        row(ulid: live),
      ]);

      // The lower ULID would win the election if it were contending at all.
      expect(merged.forPath('inbox/today.md')!.ulid, live);
      expect(merged.retired, isEmpty);
    });
  });

  group('a freed path does not resurrect a dead note', () {
    test('a deleted note leaves its path unowned', () {
      final merged = mergeIdentity([
        row(ulid: ulidAt(0), path: 'inbox/today.md', deleted: true),
      ]);

      expect(merged.forPath('inbox/today.md'), isNull);
    });

    test('a new file at a freed path is minted, not adopted', () {
      // Adopting here would give unrelated content the dead note's ULID, and
      // with it a history that has nothing to do with it.
      final merged = mergeIdentity([
        row(ulid: ulidAt(0), path: 'inbox/today.md', deleted: true),
      ]);

      expect(
        dispositionForPath(merged, 'inbox/today.md', self: peerA),
        NoteDisposition.mint,
      );
    });

    test('the dead note keeps its identity for the log that outlives it', () {
      final dead = ulidAt(0);
      final merged = mergeIdentity([row(ulid: dead, deleted: true)]);

      expect(merged.forUlid(dead)!.deleted, isTrue);
    });
  });

  group('dispositions', () {
    test('no map row at all is a mint', () {
      // A folder with no marker has no map to adopt from, so every file in it
      // is a note nobody has minted. This is folder adoption.
      final merged = mergeIdentity(const <IdentityRow>[]);

      expect(
        dispositionForPath(merged, 'anything.md', self: peerA),
        NoteDisposition.mint,
      );
    });

    test('a claimed seed held elsewhere adopts without seeding', () {
      final merged = mergeIdentity([
        row(ulid: ulidAt(0), seedClaim: stamp(peerB, 10)),
      ]);

      expect(
        dispositionForPath(merged, 'inbox/today.md', self: peerA),
        NoteDisposition.adoptPending,
      );
    });

    test('an unclaimed seed is claimable on the first edit', () {
      // The map outlived every op-log that backed it.
      final merged = mergeIdentity([row(ulid: ulidAt(0))]);

      expect(
        dispositionForPath(merged, 'inbox/today.md', self: peerA),
        NoteDisposition.adoptClaimable,
      );
    });

    test('our own seed claim is not an adoption', () {
      final merged = mergeIdentity([
        row(ulid: ulidAt(0), seedClaim: stamp(peerA, 10)),
      ]);

      expect(
        dispositionForPath(merged, 'inbox/today.md', self: peerA),
        NoteDisposition.alreadyOurs,
      );
    });

    test('a cold copy adopts rather than mints', () {
      // An engram copied to a second machine with its identity map intact:
      // every note already has a ULID and a seeder, so nothing is minted and
      // nothing is seeded. Minting here would give one file two identities and
      // seeding would duplicate its content on the merge.
      final rows = [
        for (var i = 0; i < 5; i++)
          row(
            ulid: ulidAt(i),
            path: 'note-$i.md',
            seedClaim: stamp(peerB, 10 + i),
          ),
      ];
      final merged = mergeIdentity(rows);

      for (var i = 0; i < 5; i++) {
        expect(
          dispositionForPath(merged, 'note-$i.md', self: peerA),
          NoteDisposition.adoptPending,
          reason: 'note-$i.md',
        );
      }
    });

    test('deleting the map turns adoption back into minting', () {
      // The degraded path people actually hit: content is unchanged, but the
      // ULIDs are gone and fresh ones get minted. Decision 9's promise is that
      // this costs history, never content.
      final merged = mergeIdentity(const <IdentityRow>[]);

      for (var i = 0; i < 5; i++) {
        expect(
          dispositionForPath(merged, 'note-$i.md', self: peerA),
          NoteDisposition.mint,
        );
      }
    });

    test('a retired ULID\'s path resolves to the winner', () {
      // The losing device asks about the path and is told the winner's ULID —
      // it adopts that identity rather than re-keying its own onto it.
      final earliest = ulidAt(0);
      final later = ulidAt(1);
      final merged = mergeIdentity([
        row(ulid: earliest, seedClaim: stamp(peerB, 10)),
        row(ulid: later, seedClaim: stamp(peerA, 20)),
      ]);

      expect(merged.forPath('inbox/today.md')!.ulid, earliest);
      expect(merged.retired, contains(later));
      expect(
        dispositionForPath(merged, 'inbox/today.md', self: peerA),
        NoteDisposition.adoptPending,
        reason: 'the winner was seeded by B, so A adopts and does not seed',
      );
    });
  });

  group('a contested seed', () {
    test('the comparator picks one', () {
      final ulid = ulidAt(0);
      final merged = mergeIdentity([
        row(
          ulid: ulid,
          recordedAt: stamp(peerA, 100),
          seedClaim: stamp(peerA, 10),
        ),
        row(
          ulid: ulid,
          recordedAt: stamp(peerB, 100),
          seedClaim: stamp(peerB, 20),
        ),
      ]);

      expect(merged.contestedSeeds[ulid], stamp(peerB, 20));
      expect(merged.forUlid(ulid)!.seededBy, peerB);
    });

    test('the loser is told to retract', () {
      final ulid = ulidAt(0);
      final ours = stamp(peerA, 10);
      final merged = mergeIdentity([
        row(ulid: ulid, recordedAt: stamp(peerA, 100), seedClaim: ours),
        row(
          ulid: ulid,
          recordedAt: stamp(peerB, 100),
          seedClaim: stamp(peerB, 20),
        ),
      ]);

      expect(mustRetractSeed(merged, ulid, ourClaim: ours), isTrue);
    });

    test('the winner retracts nothing', () {
      final ulid = ulidAt(0);
      final ours = stamp(peerB, 20);
      final merged = mergeIdentity([
        row(
          ulid: ulid,
          recordedAt: stamp(peerA, 100),
          seedClaim: stamp(peerA, 10),
        ),
        row(ulid: ulid, recordedAt: stamp(peerB, 100), seedClaim: ours),
      ]);

      expect(mustRetractSeed(merged, ulid, ourClaim: ours), isFalse);
    });

    test('an uncontested seed is not a contest', () {
      final ulid = ulidAt(0);
      final ours = stamp(peerA, 10);
      final merged = mergeIdentity([row(ulid: ulid, seedClaim: ours)]);

      expect(merged.contestedSeeds, isEmpty);
      expect(mustRetractSeed(merged, ulid, ourClaim: ours), isFalse);
    });

    test('a device with no claim retracts nothing', () {
      final ulid = ulidAt(0);
      final merged = mergeIdentity([
        row(
          ulid: ulid,
          recordedAt: stamp(peerA, 100),
          seedClaim: stamp(peerA, 10),
        ),
        row(
          ulid: ulid,
          recordedAt: stamp(peerB, 100),
          seedClaim: stamp(peerB, 20),
        ),
      ]);

      expect(mustRetractSeed(merged, ulid, ourClaim: null), isFalse);
    });

    test('a claim taken during another device\'s read is not dropped', () {
      // The race the union defends against. Writers write whole rows having
      // read the directory first, so in the ordinary case the rule-1 winner
      // already carries the right claim — but the read and the write are not
      // one atomic step, and no lock exists across machines that may never be
      // online together:
      //
      //   1. B reads the map and sees this note unclaimed.
      //   2. C takes the seed and writes its row.
      //   3. B writes a newer row — a rename — still carrying "unclaimed".
      //
      // B's row wins rule 1. Taking its claim verbatim would republish a
      // seeded note as unclaimed and invite a fourth device to seed a ULID
      // that already has C's history.
      final ulid = ulidAt(0);
      final merged = mergeIdentity([
        row(
          ulid: ulid,
          path: 'seeded.md',
          recordedAt: stamp(peerC, 100),
          seedClaim: stamp(peerC, 50),
        ),
        row(ulid: ulid, path: 'renamed.md', recordedAt: stamp(peerB, 900)),
      ]);

      expect(merged.forUlid(ulid)!.path, 'renamed.md');
      expect(merged.forUlid(ulid)!.seededBy, peerC);
      expect(
        merged.contestedSeeds,
        isEmpty,
        reason: 'one claim and a stale read is not a contested seed',
      );
    });

    test('a device reading the recovered claim does not seed', () {
      // The consequence that makes the case above worth defending: with the
      // claim recovered, the disposition is adopt-without-seeding rather than
      // the claimable one that would produce a second seed.
      final ulid = ulidAt(0);
      final merged = mergeIdentity([
        row(
          ulid: ulid,
          path: 'note.md',
          recordedAt: stamp(peerC, 100),
          seedClaim: stamp(peerC, 50),
        ),
        row(ulid: ulid, path: 'note.md', recordedAt: stamp(peerB, 900)),
      ]);

      expect(
        dispositionForPath(merged, 'note.md', self: peerA),
        NoteDisposition.adoptPending,
      );
    });
  });

  group('the merged view is stable', () {
    test('merging nothing yields nothing', () {
      final merged = mergeIdentity(const <IdentityRow>[]);

      expect(merged.byUlid, isEmpty);
      expect(merged.pathOwners, isEmpty);
      expect(merged.retired, isEmpty);
      expect(merged.contestedSeeds, isEmpty);
    });

    test('an unknown ULID resolves to nothing', () {
      expect(mergeIdentity(const <IdentityRow>[]).forUlid(ulidAt(0)), isNull);
    });

    test('merging one device\'s rows is the identity function', () {
      final rows = [
        row(ulid: ulidAt(0), path: 'a.md', seedClaim: stamp(peerA, 1)),
        row(ulid: ulidAt(1), path: 'b.md', seedClaim: stamp(peerA, 2)),
      ];

      final merged = mergeIdentity(rows);

      expect(merged.byUlid.values.toSet(), rows.toSet());
      expect(merged.retired, isEmpty);
      expect(merged.contestedSeeds, isEmpty);
    });
  });
}
