import 'dart:async';

/// The registry of "there may be unwritten work here" flush callbacks, awaited
/// before the app exits — and, since the note size ceiling, of work that
/// *cannot* be written and must be decided on before anything leaves it.
///
/// The editor autosaves on a debounce, so at any instant a keystroke can be in
/// the buffer but not yet on disk. Leaving must never drop it — and unlike a
/// mobile pause/detach (which `DocumentEditController` already observes), a
/// desktop exit gives no lifecycle warning: the window is simply told to close.
/// Every live [DocumentEditController] registers its flush here for its
/// lifetime, and the desktop close path awaits [flushAll] before the window is
/// destroyed, whether the exit came from Quit, its hotkey, or the window's own
/// close button.
///
/// A buffer over the note size limit is different: it is not written on a
/// flush, by design, so a flush cannot protect it (the note size ceiling
/// design, Decisions 4 and 5). Such a registrant says so through
/// [isWithheld], and offers a [resolve] that puts the decision — roll back or
/// convert — in front of the user. Every way of leaving a note asks
/// [resolveWithheld] first and stays put when the answer is no: closing the
/// window, selecting another file, switching engrams. "Nothing is lost until
/// the user picks" holds only if leaving is one of the things that asks.
class PendingSaves {
  /// The app-wide registry. Registrants take theirs by injection so a test can
  /// pass its own instance instead of leaking registrations between cases.
  static final PendingSaves instance = PendingSaves();

  final Map<Object, _Registration> _registrations = <Object, _Registration>{};

  /// How many flushes are registered. Exposed so a test can assert that a
  /// disposed registrant left nothing behind.
  int get length => _registrations.length;

  /// Registers [flush] under [owner], replacing any previous entry for it.
  ///
  /// [isWithheld] says whether the owner holds work a flush will not write;
  /// [resolve] then asks the user to settle it and returns whether it is
  /// settled — rolled back, converted, or otherwise made flushable. A
  /// registrant with neither is never withheld.
  void register(
    Object owner,
    Future<void> Function() flush, {
    bool Function()? isWithheld,
    Future<bool> Function()? resolve,
  }) {
    _registrations[owner] = _Registration(flush, isWithheld, resolve);
  }

  void unregister(Object owner) {
    _registrations.remove(owner);
  }

  /// Whether any registrant holds work a flush will not write.
  bool get hasWithheld =>
      _registrations.values.any((r) => r.isWithheld?.call() ?? false);

  /// Puts every withheld buffer's decision in front of the user, one at a
  /// time, and reports whether all of them were settled.
  ///
  /// False the moment one is not — the user cancelled — and nothing after
  /// it is asked: the caller is not leaving, so there is nothing further to
  /// decide. A withheld registrant with no [resolve] cannot be settled and
  /// answers false, which keeps the app from leaving work it cannot ask
  /// about; that is the safe failure.
  ///
  /// Today exactly one controller is ever registered — the one editor pane
  /// — so this asks at most once. The loop is the registry's shape, the same
  /// as [flushAll]'s, not an expectation of several; a second editor could
  /// register without changing anything here.
  Future<bool> resolveWithheld() async {
    for (final registration in List.of(_registrations.values)) {
      if (!(registration.isWithheld?.call() ?? false)) continue;
      final resolve = registration.resolve;
      if (resolve == null) return false;
      if (!await resolve()) return false;
    }
    return true;
  }

  /// Runs every registered flush, in registration order.
  ///
  /// A failing flush must neither strand its siblings nor block the exit, so
  /// errors are swallowed: the buffer stays dirty and the editor's own save
  /// status already reports the failure.
  Future<void> flushAll() async {
    for (final registration in List.of(_registrations.values)) {
      try {
        await registration.flush();
      } catch (_) {
        // Deliberately ignored — see above.
      }
    }
  }
}

class _Registration {
  const _Registration(this.flush, this.isWithheld, this.resolve);

  final Future<void> Function() flush;
  final bool Function()? isWithheld;
  final Future<bool> Function()? resolve;
}
