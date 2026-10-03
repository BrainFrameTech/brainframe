import 'package:flutter/material.dart';

import '../engram/device_name.dart';
import '../l10n/gen/app_localizations.dart';

/// Settings › Engram's "This device" section: what the open engram's other
/// devices call this one (the device names design, Decisions 1 and 2).
///
/// Two names, the theme's model: the device's **default**, for every engram
/// with no name of its own for it, and **this engram's** name, which wins
/// when set. Each saves on its own, and saving one blank clears it, so the
/// next in the order applies — each field's help says what that is. A line
/// below says the name the other devices actually see.
///
/// Only for an engram with a session: a read-only engram has no map file to
/// publish a name in, and the pane leaves this out for it.
class DeviceNameSection extends StatefulWidget {
  const DeviceNameSection({super.key, required this.naming});

  /// The open engram's names, and how to change them.
  final DeviceNaming naming;

  @override
  State<DeviceNameSection> createState() => _DeviceNameSectionState();
}

class _DeviceNameSectionState extends State<DeviceNameSection> {
  late DeviceNames _names = widget.naming.names;
  late final TextEditingController _default = TextEditingController(
    text: _names.deviceDefault ?? '',
  );
  late final TextEditingController _engram = TextEditingController(
    text: _names.engram ?? '',
  );
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    widget.naming.changes.addListener(_changed);
  }

  @override
  void didUpdateWidget(DeviceNameSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.naming, widget.naming)) return;
    oldWidget.naming.changes.removeListener(_changed);
    widget.naming.changes.addListener(_changed);
    _changed();
  }

  /// The names changed — perhaps by a save this section did not start, such
  /// as one begun by an earlier copy of it that was left mid-save. A field
  /// holding no edit of its own follows; one being edited is left alone.
  void _changed() {
    final names = widget.naming.names;
    setState(() {
      if (!_defaultDirty) _default.text = names.deviceDefault ?? '';
      if (!_engramDirty) _engram.text = names.engram ?? '';
      _names = names;
    });
  }

  @override
  void dispose() {
    widget.naming.changes.removeListener(_changed);
    _default.dispose();
    _engram.dispose();
    super.dispose();
  }

  bool get _defaultDirty =>
      normalizeDeviceName(_default.text) != _names.deviceDefault;

  bool get _engramDirty => normalizeDeviceName(_engram.text) != _names.engram;

  /// Saves one field through [change], then shows in [field] what was
  /// stored. Only that field: the other may hold an edit not yet saved, and
  /// resetting it from what is stored would erase it.
  Future<void> _save(
    TextEditingController field,
    Future<DeviceNames> Function() change,
  ) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _saving = true);
    try {
      final names = await change();
      if (!mounted) return;
      setState(() {
        _names = names;
        // What was stored, not what was typed: trimmed, and cut to length.
        field.text =
            (identical(field, _default) ? names.deviceDefault : names.engram) ??
            '';
      });
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.engramPaneDeviceSaved(names.resolved))),
      );
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.engramPaneDeviceSaveFailed('$error'))),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final help = TextStyle(
      fontSize: 12,
      height: 1.45,
      color: scheme.onSurfaceVariant,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Semantics(
          // A node of its own, or the heading merges into the list around it
          // and a screen reader never announces it as one.
          container: true,
          header: true,
          child: Text(
            l10n.engramPaneDeviceSection,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
        ),
        const SizedBox(height: 4),
        Text(l10n.engramPaneDeviceIntro, style: help),
        const SizedBox(height: 14),
        _DeviceNameField(
          key: const ValueKey('device-default-name'),
          controller: _default,
          label: l10n.engramPaneDeviceDefaultLabel,
          hint: _names.platform,
          help: l10n.engramPaneDeviceDefaultHelp(_names.platform),
          enabled: !_saving,
          dirty: _defaultDirty,
          isDirty: () => _defaultDirty,
          onChanged: () => setState(() {}),
          onSave: () => _save(
            _default,
            () => widget.naming.setDeviceDefault(_default.text),
          ),
        ),
        const SizedBox(height: 18),
        _DeviceNameField(
          key: const ValueKey('device-engram-name'),
          controller: _engram,
          label: l10n.engramPaneDeviceEngramLabel,
          hint: _names.withoutEngram,
          help: l10n.engramPaneDeviceEngramHelp(_names.withoutEngram),
          enabled: !_saving,
          dirty: _engramDirty,
          isDirty: () => _engramDirty,
          onChanged: () => setState(() {}),
          onSave: () =>
              _save(_engram, () => widget.naming.setEngramName(_engram.text)),
        ),
        const SizedBox(height: 14),
        Text(
          l10n.engramPaneDeviceSeenAs(_names.resolved),
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }
}

/// One name: its field, what a blank means, and its own Save.
class _DeviceNameField extends StatelessWidget {
  const _DeviceNameField({
    super.key,
    required this.controller,
    required this.label,
    required this.hint,
    required this.help,
    required this.enabled,
    required this.dirty,
    required this.isDirty,
    required this.onChanged,
    required this.onSave,
  });

  final TextEditingController controller;
  final String label;

  /// What applies while the field is blank, shown in it as a hint.
  final String hint;
  final String help;
  final bool enabled;

  /// Whether the field differs from what is stored: Save is enabled only
  /// then, so a stray click never rewrites the map file.
  final bool dirty;

  /// The same question asked now, for Done on the keyboard: [dirty] is as of
  /// the last build, and a keystroke and Done can arrive with no build
  /// between them.
  final bool Function() isDirty;
  final VoidCallback onChanged;
  final VoidCallback onSave;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Aligned, not just constrained: a ListView hands its children a
        // tight cross-axis width, which a bare ConstrainedBox cannot narrow.
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            // The field's own semantics, not a replacement: its label comes
            // from the decoration, and a screen reader also hears the name
            // being edited and its limit, which a wrapper excluding them
            // would silence.
            child: TextField(
              controller: controller,
              enabled: enabled,
              // Counted as a reader counts characters, the limit the name is
              // stored at.
              maxLength: deviceNameMaxLength,
              textInputAction: TextInputAction.done,
              onChanged: (_) => onChanged(),
              onSubmitted: (_) {
                if (isDirty()) onSave();
              },
              decoration: InputDecoration(
                labelText: label,
                hintText: hint,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
        ),
        Text(
          help,
          style: TextStyle(
            fontSize: 12,
            height: 1.45,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        // The button keeps its own semantics — its role, its enabled state,
        // and the tap action a screen reader activates it by. Only its label
        // is replaced, on the text inside it, so "Save" says which name it
        // saves; wrapping the button and excluding its semantics would drop
        // the action, leaving a control that can be found but not pressed.
        FilledButton(
          onPressed: dirty && enabled ? onSave : null,
          child: Semantics(
            label: l10n.engramPaneDeviceSaveLabel(label),
            excludeSemantics: true,
            child: Text(l10n.engramPaneSave),
          ),
        ),
      ],
    );
  }
}
