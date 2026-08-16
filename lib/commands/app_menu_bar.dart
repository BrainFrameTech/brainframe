import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/gen/app_localizations.dart';
import '../window/window_state.dart';
import 'app_commands.dart';
import 'app_shortcuts.dart';
import 'text_editing_commands.dart';

/// The desktop menu bar, wrapped around the whole app.
///
/// Each desktop gets the menu its users expect:
///
/// * **macOS** — a real system menu bar via [PlatformMenuBar], laid out to the
///   platform's conventions: About, Preferences and Quit live in the
///   application menu, not under File and Edit.
/// * **Linux / Windows** — an in-app [MenuBar] strip above the app bar, with
///   Quit under File and Preferences under Edit.
/// * **Everything else** — no menu bar. Phones, tablets and the e-ink panel
///   have neither the chrome for one nor the keyboard to drive it.
///
/// It sits *outside* the [Navigator] (see `BrainFrameApp`), so it stays put
/// across screens and a dialog never covers it. That position costs it the
/// Navigator's [Overlay], which menus need somewhere to draw, so the Material
/// variant brings its own (see [_MenuOverlayHost]).
class AppMenuBar extends StatefulWidget {
  const AppMenuBar({super.key, required this.child});

  final Widget child;

  @override
  State<AppMenuBar> createState() => _AppMenuBarState();
}

class _AppMenuBarState extends State<AppMenuBar> {
  late final TextEditingCommands _text = TextEditingCommands();

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final platform = Theme.of(context).platform;
    final commands = AppCommandsScope.of(context);
    final l10n = AppLocalizations.of(context);
    final shortcuts = AppShortcuts.forPlatform(platform);

    switch (platform) {
      case TargetPlatform.macOS:
        // The OS owns this menu bar, so it takes no Flutter focus and the Edit
        // items can read the focused field directly. Rebuilt on every tracker
        // change so what macOS shows is never stale.
        return ListenableBuilder(
          listenable: _text,
          builder: (context, child) => PlatformMenuBar(
            menus: _platformMenus(l10n, commands, shortcuts),
            child: child!,
          ),
          child: widget.child,
        );
      case TargetPlatform.linux:
      case TargetPlatform.windows:
        return _MenuOverlayHost(
          builder: (context) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _materialMenuBar(l10n, commands, shortcuts),
              Expanded(child: widget.child),
            ],
          ),
        );
      case TargetPlatform.android:
      case TargetPlatform.fuchsia:
      case TargetPlatform.iOS:
        return widget.child;
    }
  }

  // ---------------------------------------------------------------- Material

  Widget _materialMenuBar(
    AppLocalizations l10n,
    AppCommands commands,
    AppShortcuts shortcuts,
  ) {
    return MenuBar(
      children: [
        SubmenuButton(
          menuChildren: [
            MenuItemButton(
              shortcut: shortcuts.newNote,
              onPressed: commands.newNote,
              child: Text(l10n.newNote),
            ),
            MenuItemButton(
              shortcut: shortcuts.newFolder,
              onPressed: commands.newFolder,
              child: Text(l10n.newFolder),
            ),
            const Divider(),
            MenuItemButton(
              shortcut: shortcuts.quit,
              onPressed: _quit,
              child: Text(l10n.menuQuit),
            ),
          ],
          child: Text(l10n.menuFile),
        ),
        SubmenuButton(
          // Opening the menu is about to take focus off the text field; tell
          // the tracker so it holds on to it (see [TextEditingCommands]).
          onOpen: _text.menuOpened,
          onClose: _text.menuClosed,
          menuChildren: [
            _editItem(
              label: l10n.menuCut,
              shortcut: shortcuts.cut,
              enabled: () => _text.canCut,
              onPressed: _text.cut,
            ),
            _editItem(
              label: l10n.menuCopy,
              shortcut: shortcuts.copy,
              enabled: () => _text.canCopy,
              onPressed: _text.copy,
            ),
            _editItem(
              label: l10n.menuPaste,
              shortcut: shortcuts.paste,
              enabled: () => _text.canPaste,
              onPressed: _text.paste,
            ),
            _editItem(
              label: l10n.menuSelectAll,
              shortcut: shortcuts.selectAll,
              enabled: () => _text.canSelectAll,
              onPressed: _text.selectAll,
            ),
            const Divider(),
            MenuItemButton(
              shortcut: shortcuts.preferences,
              onPressed: commands.preferences,
              child: Text(l10n.menuPreferences),
            ),
          ],
          child: Text(l10n.menuEdit),
        ),
        SubmenuButton(
          menuChildren: [
            MenuItemButton(
              onPressed: commands.help,
              child: Text(l10n.helpTitle),
            ),
            MenuItemButton(
              onPressed: commands.about,
              child: Text(l10n.aboutTitle),
            ),
          ],
          child: Text(l10n.helpTitle),
        ),
      ],
    );
  }

  /// A clipboard item that re-reads its own enabled state whenever the tracked
  /// field changes.
  ///
  /// The wrapper matters: a menu's children are built by its *parent*, so
  /// without it the item's enabled state would freeze at whatever it was when
  /// the menu bar last rebuilt, rather than following the live selection.
  Widget _editItem({
    required String label,
    required MenuSerializableShortcut? shortcut,
    required bool Function() enabled,
    required VoidCallback onPressed,
  }) {
    return ListenableBuilder(
      listenable: _text,
      builder: (context, _) => MenuItemButton(
        shortcut: shortcut,
        onPressed: enabled() ? onPressed : null,
        child: Text(label),
      ),
    );
  }

  // ----------------------------------------------------------------- Apple

  List<PlatformMenuItem> _platformMenus(
    AppLocalizations l10n,
    AppCommands commands,
    AppShortcuts shortcuts,
  ) {
    return <PlatformMenuItem>[
      // The first menu is the application menu; macOS titles it with the app
      // name itself. About, Preferences and Quit belong here, not under File
      // and Edit as they do on Linux and Windows.
      PlatformMenu(
        label: l10n.appTitle,
        menus: <PlatformMenuItem>[
          PlatformMenuItem(label: l10n.aboutTitle, onSelected: commands.about),
          PlatformMenuItemGroup(
            members: <PlatformMenuItem>[
              PlatformMenuItem(
                label: l10n.menuPreferences,
                shortcut: shortcuts.preferences,
                onSelected: commands.preferences,
              ),
            ],
          ),
          PlatformMenuItemGroup(
            members: <PlatformMenuItem>[
              PlatformMenuItem(
                label: l10n.menuQuit,
                shortcut: shortcuts.quit,
                onSelected: _quit,
              ),
            ],
          ),
        ],
      ),
      PlatformMenu(
        label: l10n.menuFile,
        menus: <PlatformMenuItem>[
          PlatformMenuItem(
            label: l10n.newNote,
            shortcut: shortcuts.newNote,
            onSelected: commands.newNote,
          ),
          PlatformMenuItem(
            label: l10n.newFolder,
            shortcut: shortcuts.newFolder,
            onSelected: commands.newFolder,
          ),
        ],
      ),
      PlatformMenu(
        label: l10n.menuEdit,
        menus: <PlatformMenuItem>[
          PlatformMenuItem(
            label: l10n.menuCut,
            shortcut: shortcuts.cut,
            onSelected: _text.canCut ? _text.cut : null,
          ),
          PlatformMenuItem(
            label: l10n.menuCopy,
            shortcut: shortcuts.copy,
            onSelected: _text.canCopy ? _text.copy : null,
          ),
          PlatformMenuItem(
            label: l10n.menuPaste,
            shortcut: shortcuts.paste,
            onSelected: _text.canPaste ? _text.paste : null,
          ),
          PlatformMenuItem(
            label: l10n.menuSelectAll,
            shortcut: shortcuts.selectAll,
            onSelected: _text.canSelectAll ? _text.selectAll : null,
          ),
        ],
      ),
      PlatformMenu(
        label: l10n.helpTitle,
        menus: <PlatformMenuItem>[
          PlatformMenuItem(label: l10n.helpTitle, onSelected: commands.help),
        ],
      ),
    ];
  }

  void _quit() => unawaited(requestAppQuit());
}

/// Hosts [builder]'s subtree inside an [Overlay] of its own.
///
/// Menus draw into the nearest overlay, and the menu bar deliberately sits
/// above the app's [Navigator] — which is where the only other overlay lives.
/// This supplies one that spans the whole window, so submenus can float over
/// everything below, routes and dialogs included.
class _MenuOverlayHost extends StatefulWidget {
  const _MenuOverlayHost({required this.builder});

  final WidgetBuilder builder;

  @override
  State<_MenuOverlayHost> createState() => _MenuOverlayHostState();
}

class _MenuOverlayHostState extends State<_MenuOverlayHost> {
  late final OverlayEntry _entry = OverlayEntry(
    opaque: true,
    maintainState: true,
    builder: (context) => widget.builder(context),
  );

  @override
  void didUpdateWidget(_MenuOverlayHost oldWidget) {
    super.didUpdateWidget(oldWidget);
    // The entry is created once, so it has to be told when the app above it
    // rebuilds — otherwise it would keep serving the subtree it first built.
    _entry.markNeedsBuild();
  }

  @override
  Widget build(BuildContext context) =>
      Overlay(initialEntries: <OverlayEntry>[_entry]);
}
