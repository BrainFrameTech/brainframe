import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../engram/engram.dart';
import '../engram/metadata.dart';
import '../l10n/gen/app_localizations.dart';

/// Renames the open engram, returning it with its new display name.
typedef EngramRenamer = Future<Engram> Function(String displayName);

/// Reads the open engram's on-disk marker, or null when it has none (the
/// bundled built-ins).
typedef EngramMetadataLoader = Future<EngramMetadata?> Function();

/// The Engram settings pane: what the open engram is, and the one field of it
/// the user owns.
///
/// Two halves, deliberately unequal. The **name** is editable, because it is
/// the user's own label and until now could only be chosen once, at creation,
/// leaving people stuck with a folder name like `zettel` in the switcher.
/// Everything else — identifier, creation stamp, folder, marker format — is
/// **read-only**, because it is machine-owned identity; it is shown because
/// "which engram am I actually looking at?" is the first question any bug
/// report has to answer, and there was previously nowhere in the app to find
/// out.
///
/// Renaming rewrites `engram.json` only. The folder on disk keeps its own name:
/// the two are independent by design, so an engram's identity (and every
/// cross-reference to it) survives being renamed or moved on either side.
///
/// A custom [SettingsCategory] detail pane rather than a set of control rows,
/// like Housekeeping and About: it loads the marker asynchronously, validates
/// an editable field, and reports failures. It depends on two capabilities
/// rather than the whole repository, so it stays trivially testable with no
/// filesystem in a widget test.
class EngramPane extends StatefulWidget {
  const EngramPane({
    super.key,
    required this.engram,
    required this.loadMetadata,
    required this.rename,
    this.onRenamed,
  });

  /// The engram this pane describes — the one that is open.
  final Engram engram;

  /// Reads the marker from disk. Kept separate from [engram] on purpose: the
  /// pane reports what is *stored*, not what happens to be in memory.
  final EngramMetadataLoader loadMetadata;

  /// Writes a new display name, returning the renamed engram.
  final EngramRenamer rename;

  /// Notified after a successful rename, so the rest of the app (the switcher
  /// under the pushed Settings route) can pick the new name up.
  final ValueChanged<Engram>? onRenamed;

  @override
  State<EngramPane> createState() => _EngramPaneState();
}

class _EngramPaneState extends State<EngramPane> {
  late Engram _engram = widget.engram;
  late final TextEditingController _name = TextEditingController(
    text: _engram.displayName,
  );
  late Future<EngramMetadata?> _metadata = widget.loadMetadata();

  /// Set when the field is blank on save; cleared as soon as it is edited.
  bool _blank = false;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  /// Whether the typed name differs from what is stored — the Save button is
  /// enabled only then, so an accidental click can never rewrite the marker.
  bool get _dirty => _name.text.trim() != _engram.displayName;

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final trimmed = _name.text.trim();
    if (trimmed.isEmpty) {
      setState(() => _blank = true);
      return;
    }
    setState(() {
      _blank = false;
      _saving = true;
    });
    try {
      final renamed = await widget.rename(trimmed);
      if (!mounted) return;
      setState(() {
        _engram = renamed;
        _name.text = renamed.displayName;
        // The marker changed underneath us; re-read rather than patch the
        // displayed copy, so the pane keeps showing what is actually on disk.
        _metadata = widget.loadMetadata();
      });
      widget.onRenamed?.call(renamed);
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.engramPaneSaved(renamed.displayName))),
      );
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.engramPaneSaveFailed('$error'))),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _copyDetails(EngramMetadata? metadata) async {
    final l10n = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final lines = <String>[
      '${l10n.engramPaneNameLabel}: ${_engram.displayName}',
      '${l10n.engramPaneId}: ${_engram.id}',
      '${l10n.engramPaneLocation}: ${_location(l10n)}',
      if (metadata != null)
        '${l10n.engramPaneCreated}: '
            '${metadata.createdUtc.toIso8601String()}',
      if (metadata != null)
        '${l10n.engramPaneFormat}: ${metadata.schemaVersion}',
      '${l10n.engramPaneReadOnlyLabel}: '
          '${_engram.readOnly ? l10n.engramPaneYes : l10n.engramPaneNo}',
    ];
    await Clipboard.setData(ClipboardData(text: lines.join('\n')));
    if (!mounted) return;
    messenger.showSnackBar(SnackBar(content: Text(l10n.engramPaneCopied)));
  }

  String _location(AppLocalizations l10n) =>
      _engram.store.locationDescription ?? l10n.engramPaneLocationBuiltIn;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final hPad = constraints.maxWidth < 540 ? 18.0 : 32.0;
        return FutureBuilder<EngramMetadata?>(
          future: _metadata,
          builder: (context, snapshot) {
            return ListView(
              padding: EdgeInsets.fromLTRB(hPad, 26, hPad, 44),
              children: [
                Text(
                  l10n.settingsEngramName,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.01 * 22,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.engramPaneIntro,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.45,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 24),
                _SectionHeading(title: l10n.engramPaneNameSection),
                const SizedBox(height: 10),
                _NameField(
                  controller: _name,
                  enabled: !_engram.readOnly && !_saving,
                  errorText: _blank ? l10n.engramPaneNameEmpty : null,
                  onChanged: () => setState(() => _blank = false),
                  onSubmitted: _dirty ? _save : null,
                ),
                const SizedBox(height: 8),
                Text(
                  _engram.readOnly
                      ? l10n.engramPaneReadOnly
                      : l10n.engramPaneNameHelp,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.45,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (!_engram.readOnly) ...[
                  const SizedBox(height: 12),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: FilledButton(
                      onPressed: (_dirty && !_saving) ? _save : null,
                      child: Text(l10n.engramPaneSave),
                    ),
                  ),
                ],
                const SizedBox(height: 28),
                _SectionHeading(title: l10n.engramPaneDetailsSection),
                const SizedBox(height: 10),
                if (snapshot.connectionState == ConnectionState.waiting)
                  const Center(child: CircularProgressIndicator.adaptive())
                else ...[
                  if (snapshot.hasError)
                    _MarkerError(
                      message: l10n.engramPaneMarkerError('${snapshot.error}'),
                    ),
                  _Details(
                    engram: _engram,
                    metadata: snapshot.data,
                    location: _location(l10n),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l10n.engramPaneDetailsHelp,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.45,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: OutlinedButton.icon(
                      onPressed: () => _copyDetails(snapshot.data),
                      icon: const Icon(Icons.copy_outlined, size: 16),
                      label: Text(l10n.engramPaneCopy),
                    ),
                  ),
                ],
              ],
            );
          },
        );
      },
    );
  }
}

/// The display-name field. Its own widget so the [TextField]'s enabled/error
/// state stays readable, and so the semantics label is stated explicitly rather
/// than inferred from the decoration.
class _NameField extends StatelessWidget {
  const _NameField({
    required this.controller,
    required this.enabled,
    required this.errorText,
    required this.onChanged,
    required this.onSubmitted,
  });

  final TextEditingController controller;
  final bool enabled;
  final String? errorText;
  final VoidCallback onChanged;
  final VoidCallback? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // Aligned, not just constrained: a ListView hands its children a *tight*
    // cross-axis width, which a bare ConstrainedBox cannot narrow, so the field
    // would stretch the whole pane.
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Semantics(
          textField: true,
          enabled: enabled,
          label: l10n.engramPaneNameLabel,
          child: ExcludeSemantics(
            child: TextField(
              controller: controller,
              enabled: enabled,
              textInputAction: TextInputAction.done,
              onChanged: (_) => onChanged(),
              onSubmitted: (_) => onSubmitted?.call(),
              decoration: InputDecoration(
                labelText: l10n.engramPaneNameLabel,
                errorText: errorText,
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      header: true,
      child: Text(
        title,
        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// The read-only identity block: what is stored about this engram.
class _Details extends StatelessWidget {
  const _Details({
    required this.engram,
    required this.metadata,
    required this.location,
  });

  final Engram engram;

  /// Null when the engram has no marker (a built-in) or it could not be read;
  /// the rows that come from it are then simply absent rather than guessed at.
  final EngramMetadata? metadata;

  final String location;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final created = metadata?.createdUtc;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          _DetailRow(label: l10n.engramPaneId, value: engram.id),
          _DetailRow(label: l10n.engramPaneLocation, value: location),
          if (created != null)
            _DetailRow(
              label: l10n.engramPaneCreated,
              // The stamp is stored in UTC and shown as stored: a details block
              // exists to be compared with what is on disk and in logs, so a
              // local-time rendering would only make that harder.
              value: created.toIso8601String(),
            ),
          if (metadata != null)
            _DetailRow(
              label: l10n.engramPaneFormat,
              value: '${metadata!.schemaVersion}',
            ),
          _DetailRow(
            label: l10n.engramPaneReadOnlyLabel,
            value: engram.readOnly ? l10n.engramPaneYes : l10n.engramPaneNo,
          ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: label,
      value: value,
      child: ExcludeSemantics(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 118,
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SelectableText(
                  value,
                  style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MarkerError extends StatelessWidget {
  const _MarkerError({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 16, color: scheme.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 13, height: 1.45, color: scheme.error),
            ),
          ),
        ],
      ),
    );
  }
}
