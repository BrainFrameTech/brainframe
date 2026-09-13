import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engram/engram_scope.dart';
import '../engram/ui/crdt_session_scope.dart';
import '../l10n/gen/app_localizations.dart';
import '../widgets/app_scaffold.dart';
import 'settings_shell.dart';

/// Pushes the [SettingsScreen] as a full page. This is the seam any entry point
/// uses — an app-bar button today, a menu item later.
///
/// The active engram is captured *before* the push and re-published inside the
/// route with an [EngramScopeProxy]: `EngramScope` lives at the `MaterialApp`'s
/// `home`, so a pushed route is its sibling, not its descendant, and would
/// otherwise not see the open engram at all (the same capture the engram
/// switcher does before opening its sheet). Writes through the proxy — the
/// Engram pane's rename — still reach the real scope underneath. The engram's
/// op-log session is captured and re-published the same way, so Housekeeping
/// can ask the reconciler what it knows about the notes.
Future<void> openSettingsScreen(
  BuildContext context, {
  String? initialCategoryId,
}) {
  final engramScope = EngramScope.maybeOf(context);
  final writer = CrdtSessionScope.maybeOf(context);
  final reconciler = CrdtSessionScope.maybeReconcilerOf(context);
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) {
        Widget screen = SettingsScreen(initialCategoryId: initialCategoryId);
        if (writer != null || reconciler != null) {
          screen = CrdtSessionScope.republish(
            writer: writer,
            reconciler: reconciler,
            child: screen,
          );
        }
        if (engramScope == null) return screen;
        return EngramScopeProxy(source: engramScope, child: screen);
      },
    ),
  );
}

/// The Settings screen: app chrome around the reusable [SettingsShell].
///
/// The shell is self-contained and reflows on its own width, so it drops
/// unchanged into other hosts (a future embedded settings pane) — this screen
/// only supplies the [AppScaffold] title and back affordance.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, this.initialCategoryId});

  final String? initialCategoryId;

  @override
  Widget build(BuildContext context) {
    // Escape pops one level off the navigation stack — back to whatever pushed
    // Settings (today, always the engram browser). Mirrors the app-bar back
    // button. `maybePop` respects any route (e.g. a dialog) on top.
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).maybePop(),
      },
      child: Focus(
        autofocus: true,
        child: AppScaffold(
          title: AppLocalizations.of(context).settingsTitle,
          body: SettingsShell(initialCategoryId: initialCategoryId),
        ),
      ),
    );
  }
}
