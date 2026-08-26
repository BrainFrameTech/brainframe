import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import '../commands/pending_saves.dart';
import '../settings/device_settings.dart';
import '../settings/settings_store.dart';

const Size _defaultSize = Size(1280, 800);
const Size _minimumSize = Size(640, 480);

/// The device-tier settings store used for window geometry (there is no
/// per-engram window state, so the engram tier is null).
SettingsStore _deviceStore(SharedPreferencesAsync prefs) => SettingsStore(
  device: DeviceSettingsBackend(prefs),
  engram: () => const NullSettingsBackend(),
);

/// True for a session started with an explicit `--window-size`. Unlike
/// [_persistenceSuspended] this is never cleared: the override is transient by
/// design, so even a deliberate resize during such a session is not recorded.
/// Without it, opening at a recording size would quietly become the size the
/// app opens at from then on.
bool _persistenceDisabled = false;

/// True from a "reset to defaults" until the user next resizes or moves the
/// window. While set, geometry is not persisted — otherwise the save-on-close
/// (or a stray event) would immediately rewrite the geometry the user just
/// cleared, silently undoing the reset.
bool _persistenceSuspended = false;

/// Suspends persisting window geometry until the next deliberate resize/move.
/// Called by the settings "reset window & layout" action so the reset sticks.
/// No-op where there is no OS window (see the stub).
void suspendWindowStatePersistence() {
  _persistenceSuspended = true;
}

/// Resets the module-level persistence flags between tests.
@visibleForTesting
void resetWindowStatePersistenceForTesting() {
  _persistenceDisabled = false;
  _persistenceSuspended = false;
}

bool get _isDesktop =>
    defaultTargetPlatform == TargetPlatform.windows ||
    defaultTargetPlatform == TargetPlatform.linux ||
    defaultTargetPlatform == TargetPlatform.macOS;

/// Restores the saved desktop window geometry (or applies sensible defaults)
/// and begins persisting future size, position, and maximized changes.
///
/// No-op on mobile — only desktop platforms have an OS window to manage.
/// Assumes `WidgetsFlutterBinding.ensureInitialized()` has already run.
///
/// Note on position: under Wayland the compositor owns window placement and
/// silently ignores client requests to move a window, so position is neither
/// meaningfully restorable nor savable there. Size and maximized state work on
/// all desktops; position additionally works on X11, macOS, and Windows.
Future<void> initWindowManager({Size? startupSize}) async {
  if (!_isDesktop) return;

  await windowManager.ensureInitialized();
  final store = _deviceStore(SharedPreferencesAsync());
  // An explicit --window-size takes the session off the saved geometry
  // entirely: nothing is restored (so no stale position or maximized state
  // fights the requested size) and nothing is written back. Leaving the read in
  // would also mean restoring a maximized state that ignores the size asked
  // for.
  _persistenceDisabled = startupSize != null;
  final saved = startupSize != null ? null : await _readSaved(store);

  final options = WindowOptions(
    size: startupSize ?? saved?.size ?? _defaultSize,
    minimumSize: _minimumSize,
    center: saved == null,
    title: 'BrainFrame',
  );

  await windowManager.waitUntilReadyToShow(options, () async {
    // Size comes from WindowOptions; restore position separately (a no-op on
    // Wayland). Skip it when maximized — maximize() drives the geometry.
    if (saved?.position != null && !(saved!.isMaximized)) {
      await windowManager.setPosition(saved.position!);
    }
    await windowManager.show();
    await windowManager.focus();
    if (saved?.isMaximized ?? false) {
      await windowManager.maximize();
    }
  });

  // Persist on close as well as on change, so the final geometry is never lost.
  await windowManager.setPreventClose(true);
  windowManager.addListener(WindowStatePersister(store));
}

/// Asks the app to quit: the Quit menu item and its hotkey.
///
/// Routed through the window's own close so there is exactly one exit path —
/// `close()` fires the delete-event that [WindowStatePersister.onWindowClose]
/// intercepts, which flushes unsaved edits and saves the geometry before
/// destroying the window. A no-op where there is no OS window to close.
Future<void> requestAppQuit() async {
  if (!_isDesktop) return;
  await windowManager.close();
}

/// Persists window geometry whenever it changes, and flushes unsaved edits on
/// the way out.
///
/// Linux (GTK) emits only the present-tense `resize`/`move` events, while
/// macOS and Windows emit the past-tense `resized`/`moved` variants. We listen
/// for both and debounce, since the present-tense events fire continuously
/// during a drag.
@visibleForTesting
class WindowStatePersister extends WindowListener {
  WindowStatePersister(this._store, {PendingSaves? pendingSaves})
    : _pendingSaves = pendingSaves ?? PendingSaves.instance;

  final SettingsStore _store;

  /// The unwritten editor buffers to flush before the window is destroyed.
  /// Injectable so a test can supply its own registry.
  final PendingSaves _pendingSaves;

  Timer? _debounce;

  /// True once a close is underway. `windowManager.destroy()` re-fires the GTK
  /// delete-event, which re-enters [onWindowClose]; without this guard the
  /// second entry runs a redundant save and `destroy()` while the engine is
  /// already tearing down, which on Linux/Wayland stalls the exit for ~1s and
  /// then segfaults. See [onWindowClose].
  bool _closing = false;

  void _scheduleSave() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), _save);
  }

  /// A deliberate user resize/move re-enables persistence after a reset — the
  /// user is choosing a new geometry, which should be remembered again.
  void _onGeometryChanged() {
    _persistenceSuspended = false;
    _scheduleSave();
  }

  Future<void> _save() async {
    if (_persistenceDisabled || _persistenceSuspended) return;
    final isMaximized = await windowManager.isMaximized();

    if (isMaximized) {
      // Keep the previously stored "normal" geometry so that un-maximizing on
      // next launch restores a sensible size rather than the full-screen one.
      final previous = await _readSaved(_store);
      await _write(
        position: previous?.position,
        size: previous?.size ?? _defaultSize,
        isMaximized: true,
      );
      return;
    }

    await _write(
      position: await windowManager.getPosition(),
      size: await windowManager.getSize(),
      isMaximized: false,
    );
  }

  Future<void> _write({
    required Offset? position,
    required Size size,
    required bool isMaximized,
  }) async {
    await _store.write(windowStateSetting, {
      if (position != null) 'x': position.dx,
      if (position != null) 'y': position.dy,
      'width': size.width,
      'height': size.height,
      'maximized': isMaximized,
    });
  }

  // Present-tense (Linux) and past-tense (macOS/Windows) geometry events.
  @override
  void onWindowResize() => _onGeometryChanged();

  @override
  void onWindowResized() => _onGeometryChanged();

  @override
  void onWindowMove() => _onGeometryChanged();

  @override
  void onWindowMoved() => _onGeometryChanged();

  @override
  void onWindowMaximize() => _onGeometryChanged();

  @override
  void onWindowUnmaximize() => _onGeometryChanged();

  @override
  Future<void> onWindowClose() async {
    // `destroy()` below re-fires the delete-event and re-enters this handler;
    // ignore the re-entry so we save and destroy exactly once (see [_closing]).
    if (_closing) return;
    _closing = true;
    _debounce?.cancel();
    try {
      // Desktop gets no lifecycle warning before an exit, so the editor's
      // debounced autosave could still be holding the last few keystrokes.
      // Write them before anything tears down.
      await _pendingSaves.flushAll();
      await _save();
    } finally {
      // We intercepted the close (setPreventClose); always actually close,
      // even if the final save failed.
      await windowManager.destroy();
    }
  }
}

class _SavedWindowState {
  const _SavedWindowState({
    required this.position,
    required this.size,
    required this.isMaximized,
  });

  /// Null when no position was stored (e.g. saved under Wayland).
  final Offset? position;
  final Size size;
  final bool isMaximized;
}

Future<_SavedWindowState?> _readSaved(SettingsStore store) async {
  final map = await store.read(windowStateSetting);
  if (map == null) return null;
  try {
    final x = map['x'] as num?;
    final y = map['y'] as num?;
    return _SavedWindowState(
      position: (x != null && y != null)
          ? Offset(x.toDouble(), y.toDouble())
          : null,
      size: Size(
        (map['width'] as num).toDouble(),
        (map['height'] as num).toDouble(),
      ),
      isMaximized: map['maximized'] as bool? ?? false,
    );
  } catch (_) {
    // Corrupt or outdated state — fall back to defaults.
    return null;
  }
}
