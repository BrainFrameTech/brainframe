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

  test('the app-wide instance is a single shared registry', () {
    expect(identical(PendingSaves.instance, PendingSaves.instance), isTrue);
  });
}
