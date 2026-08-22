import 'package:flutter/widgets.dart';

import 'engram.dart';

/// The active-engram state [EngramScope] exposes to the widget tree: the single
/// open [engram] plus [switchTo] to change it.
@immutable
class EngramScopeData {
  const EngramScopeData({
    required this.engram,
    required this.switchTo,
    required this.updateActive,
  });

  /// The one engram open right now — never a collection (Decision 2).
  final Engram engram;

  /// Switches the active engram, releasing the outgoing engram's store first.
  /// Switching to the already-active engram is a no-op.
  final Future<void> Function(Engram engram) switchTo;

  /// Replaces the *same* engram with an updated value — a rename, where the id
  /// and store are unchanged and only the display name differs.
  ///
  /// Distinct from [switchTo], which swaps engrams and releases the outgoing
  /// store; here the store keeps being used, so releasing it would close the
  /// engram the user is still reading.
  ///
  /// Throws [ArgumentError] if the engram has a different id. That is not
  /// pedantry about a misuse that "can't happen": this path deliberately skips
  /// everything a switch does — releasing the outgoing store, recording the new
  /// last-opened engram — so a different engram arriving here would be adopted
  /// with its predecessor's store leaked and the bookkeeping silently out of
  /// step. Refusing it turns that into an immediate, located failure. Use
  /// [switchTo] to open a different engram.
  final Future<void> Function(Engram engram) updateActive;
}

/// Holds the single active engram and exposes it to descendants, the way
/// `AppSettings` exposes look-and-feel. Screens read
/// `EngramScope.of(context).engram`; the picker calls
/// `EngramScope.of(context).switchTo(next)`.
///
/// Switching swaps one value: engram-scoped subtrees rebuild while everything
/// *above* this widget (the `MaterialApp` root) is untouched, and the previous
/// engram's store is released (Decision 2). Because the active engram lives in
/// this widget's own [State], place [EngramScope] below the app root — as the
/// shell's `home`, not around the `MaterialApp` — so a switch never rebuilds the
/// root or tears down the navigator.
class EngramScope extends StatefulWidget {
  const EngramScope({
    super.key,
    required this.initialEngram,
    required this.child,
    this.onSwitched,
  });

  /// The engram open when the scope is first built (resolved at startup).
  final Engram initialEngram;

  /// Invoked after the active engram changes, e.g. to persist "last opened".
  /// Not called for a no-op switch to the already-active engram.
  final Future<void> Function(Engram engram)? onSwitched;

  final Widget child;

  /// The active-engram state, or throws if there is no [EngramScope] ancestor.
  static EngramScopeData of(BuildContext context) {
    final data = maybeOf(context);
    assert(data != null, 'No EngramScope found in the widget tree.');
    return data!;
  }

  /// The active-engram state, or null if there is no [EngramScope] ancestor.
  static EngramScopeData? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<_EngramScopeMarker>()
      ?.data;

  @override
  State<EngramScope> createState() => _EngramScopeState();
}

class _EngramScopeState extends State<EngramScope> {
  late Engram _engram = widget.initialEngram;

  Future<void> _switchTo(Engram next) async {
    if (next.id == _engram.id) return; // already open — nothing to swap/release
    final previous = _engram;
    // Swap first so the new (already-resolved) engram renders immediately, then
    // free the outgoing store. For v1's stateless stores release is a no-op;
    // this is where a Location-B security-scoped handle is freed in v2.
    setState(() => _engram = next);
    await previous.store.release();
    await widget.onSwitched?.call(next);
  }

  Future<void> _updateActive(Engram next) async {
    // Checked in release too, not just asserted in debug: the damage here is
    // silent (a leaked store, stale last-opened) rather than a crash, so a
    // stripped assert would let it ship and surface later as something else.
    if (next.id != _engram.id) {
      throw ArgumentError.value(
        next.id,
        'engram',
        'updateActive replaces the active engram (${_engram.id}) in place; '
            'use switchTo to open a different one',
      );
    }
    // No release: this is the same engram over the same store.
    setState(() => _engram = next);
  }

  @override
  void dispose() {
    // Free the active store when the scope itself is torn down.
    _engram.store.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _EngramScopeMarker(
        data: EngramScopeData(
          engram: _engram,
          switchTo: _switchTo,
          updateActive: _updateActive,
        ),
        child: widget.child,
      );
}

class _EngramScopeMarker extends InheritedWidget {
  const _EngramScopeMarker({required this.data, required super.child});

  final EngramScopeData data;

  @override
  bool updateShouldNotify(_EngramScopeMarker oldWidget) =>
      data.engram.id != oldWidget.data.engram.id ||
      data.engram.displayName != oldWidget.data.engram.displayName;
}

/// Re-publishes a captured [EngramScopeData] into a subtree that is not a
/// descendant of the [EngramScope] that owns it.
///
/// [EngramScope] deliberately sits at the `MaterialApp`'s `home`, below the
/// Navigator, so switching engrams never rebuilds the app root. The cost is
/// that anything *pushed* — the Settings route, a modal sheet — is a sibling of
/// the scope rather than a child, and `EngramScope.of` there finds nothing. The
/// established fix is to capture the data before the push (see
/// `EngramSwitcher`); this widget makes the captured value readable through the
/// ordinary `EngramScope.of` lookup inside the pushed subtree.
///
/// It keeps its own copy of the engram and updates it on [updateActive], so a
/// rename performed inside the pushed subtree is reflected both there and in
/// the real scope underneath. Without that, reads through a captured snapshot
/// would silently go stale the moment the pushed route changed anything.
class EngramScopeProxy extends StatefulWidget {
  const EngramScopeProxy({
    super.key,
    required this.source,
    required this.child,
  });

  /// The scope data captured from below, before the push.
  final EngramScopeData source;

  final Widget child;

  @override
  State<EngramScopeProxy> createState() => _EngramScopeProxyState();
}

class _EngramScopeProxyState extends State<EngramScopeProxy> {
  late Engram _engram = widget.source.engram;

  Future<void> _updateActive(Engram next) async {
    // Forward *first*, so an update the owning scope refuses cannot leave this
    // proxy displaying an engram the real scope never adopted.
    await widget.source.updateActive(next);
    if (!mounted) return;
    setState(() => _engram = next);
  }

  @override
  Widget build(BuildContext context) => _EngramScopeMarker(
    data: EngramScopeData(
      engram: _engram,
      switchTo: widget.source.switchTo,
      updateActive: _updateActive,
    ),
    child: widget.child,
  );
}
