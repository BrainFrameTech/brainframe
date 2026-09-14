import 'package:brainframe/commands/pending_saves.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('flushAll runs every registered flush, in registration order', () async {
    final saves = PendingSaves();
    final order = <String>[];
    saves.register('a', () async => order.add('a'));
    saves.register('b', () async => order.add('b'));

    await saves.flushAll();

    expect(order, ['a', 'b']);
  });

  test('re-registering the same owner replaces its flush', () async {
    final saves = PendingSaves();
    var first = 0;
    var second = 0;
    final owner = Object();
    saves.register(owner, () async => first++);
    saves.register(owner, () async => second++);

    await saves.flushAll();

    expect(saves.length, 1);
    expect(first, 0);
    expect(second, 1);
  });

  test('an unregistered owner is not flushed', () async {
    final saves = PendingSaves();
    var flushed = 0;
    saves.register('a', () async => flushed++);
    saves.unregister('a');

    await saves.flushAll();

    expect(saves.length, 0);
    expect(flushed, 0);
  });

  test('a failing flush neither escapes nor strands the ones after it',
      () async {
    final saves = PendingSaves();
    var reached = false;
    saves.register('bad', () async => throw StateError('disk full'));
    saves.register('good', () async => reached = true);

    await saves.flushAll();

    expect(reached, isTrue, reason: 'the second flush must still run');
  });

  group('withheld work (the note size ceiling)', () {
    test('nothing withheld resolves at once, asking nobody', () async {
      final saves = PendingSaves();
      var asked = 0;
      saves.register('a', () async {});
      saves.register(
        'b',
        () async {},
        isWithheld: () => false,
        resolve: () async {
          asked++;
          return true;
        },
      );

      expect(saves.hasWithheld, isFalse);
      expect(await saves.resolveWithheld(), isTrue);
      expect(asked, 0);
    });

    test('a withheld registrant is asked, and its answer is the answer',
        () async {
      final saves = PendingSaves();
      var answer = false;
      saves.register(
        'editor',
        () async {},
        isWithheld: () => true,
        resolve: () async => answer,
      );

      expect(saves.hasWithheld, isTrue);
      expect(await saves.resolveWithheld(), isFalse);
      answer = true;
      expect(await saves.resolveWithheld(), isTrue);
    });

    test('a refusal stops the asking: the caller is not leaving', () async {
      final saves = PendingSaves();
      final asked = <String>[];
      for (final name in ['first', 'second']) {
        saves.register(
          name,
          () async {},
          isWithheld: () => true,
          resolve: () async {
            asked.add(name);
            return false;
          },
        );
      }

      expect(await saves.resolveWithheld(), isFalse);
      expect(asked, ['first']);
    });

    test('withheld with no way to ask cannot be left', () async {
      // The safe failure: work that cannot be asked about is not walked
      // away from.
      final saves = PendingSaves();
      saves.register('mute', () async {}, isWithheld: () => true);

      expect(await saves.resolveWithheld(), isFalse);
    });

    test('a registrant that settles is no longer withheld', () async {
      final saves = PendingSaves();
      var withheld = true;
      saves.register(
        'editor',
        () async {},
        isWithheld: () => withheld,
        resolve: () async {
          withheld = false;
          return true;
        },
      );

      expect(await saves.resolveWithheld(), isTrue);
      expect(saves.hasWithheld, isFalse);
    });
  });

  test('the app-wide instance is a single shared registry', () {
    expect(identical(PendingSaves.instance, PendingSaves.instance), isTrue);
  });
}
