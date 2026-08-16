import 'dart:async';

/// The registry of "there may be unwritten work here" flush callbacks, awaited
/// before the app exits.
///
/// The editor autosaves on a debounce, so at any instant a keystroke can be in
/// the buffer but not yet on disk. Leaving must never drop it — and unlike a
/// mobile pause/detach (which `DocumentEditController` already observes), a
/// desktop exit gives no lifecycle warning: the window is simply told to close.
/// Every live [DocumentEditController] registers its flush here for its
/// lifetime, and the desktop close path awaits [flushAll] before the window is
/// destroyed, whether the exit came from Quit, its hotkey, or the window's own
/// close button.
class PendingSaves {
  /// The app-wide registry. Registrants take theirs by injection so a test can
  /// pass its own instance instead of leaking registrations between cases.
  static final PendingSaves instance = PendingSaves();

  final Map<Object, Future<void> Function()> _flushes =
      <Object, Future<void> Function()>{};

  /// How many flushes are registered. Exposed so a test can assert that a
  /// disposed registrant left nothing behind.
  int get length => _flushes.length;

  /// Registers [flush] under [owner], replacing any previous entry for it.
  void register(Object owner, Future<void> Function() flush) {
    _flushes[owner] = flush;
  }

  void unregister(Object owner) {
    _flushes.remove(owner);
  }

  /// Runs every registered flush, in registration order.
  ///
  /// A failing flush must neither strand its siblings nor block the exit, so
  /// errors are swallowed: the buffer stays dirty and the editor's own save
  /// status already reports the failure.
  Future<void> flushAll() async {
    for (final flush in List.of(_flushes.values)) {
      try {
        await flush();
      } catch (_) {
        // Deliberately ignored — see above.
      }
    }
  }
}
