import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';
import '../desktop_folder_adoption.dart';
import '../fs/fs_store.dart';
import 'note_status_bar.dart' show formatDecimal;

/// The adoption dialog (F30), up from the moment a folder is picked.
///
/// While the folder is being looked at it is *Looking at “Vault”…* over a
/// progress bar — indeterminate while the folder is listed, then *n of N
/// files* — with **Cancel**. Once the counts are in it becomes the
/// confirmation in place: what will be written, how many files become notes,
/// how many are rewritten from CRLF, and **Adopt**. It pops with true to
/// adopt and false otherwise; a folder that is already an engram asks
/// nothing, and the dialog pops true as soon as the preview says so.
///
/// Leaving the dialog any way but Adopt — Cancel, the barrier, Escape —
/// cancels the pass, so a walk over thousands of files never continues
/// behind a dialog that is gone.
///
/// **It repaints at most every [repaintInterval], not once per file**, the
/// discipline of the sidebar's adoption bar and for its reason: the pass and
/// the UI share one isolate, and painting a frame per file costs more than
/// looking at the file does. The first count and the finish always paint at
/// once. On e-ink that is also the only shape that works — a handful of
/// discrete redraws, none once it is done — and under Reduce Motion the
/// indeterminate bar does not sweep.
class AdoptFolderDialog extends StatefulWidget {
  const AdoptFolderDialog({
    super.key,
    required this.previewing,
    this.repaintInterval = const Duration(milliseconds: 250),
  });

  /// The folder being looked at, made by [pickAndAdoptFolder].
  final FolderPreviewing previewing;

  /// The least time between two repaints of an advancing count.
  final Duration repaintInterval;

  /// Shows the dialog for [previewing] and answers whether to adopt.
  static Future<bool> show(
    BuildContext context,
    FolderPreviewing previewing,
  ) async {
    final adopt = await showDialog<bool>(
      context: context,
      builder: (_) => AdoptFolderDialog(previewing: previewing),
    );
    return adopt ?? false;
  }

  @override
  State<AdoptFolderDialog> createState() => _AdoptFolderDialogState();
}

class _AdoptFolderDialogState extends State<AdoptFolderDialog> {
  ({int done, int total})? _shown;
  Timer? _repaint;
  FolderAdoptionPreview? _preview;

  @override
  void initState() {
    super.initState();
    _shown = widget.previewing.progress.value;
    widget.previewing.progress.addListener(_onProgress);
    unawaited(widget.previewing.preview.then(_onPreview));
  }

  void _onProgress() {
    if (_shown == null) {
      // The first count: the total is now known, and the bar is shown at
      // once so the listing's indeterminate sweep does not linger.
      _repaint?.cancel();
      _show();
      return;
    }
    // A step in the middle: shown at the next tick, together with whatever
    // else arrives before it.
    _repaint ??= Timer(widget.repaintInterval, _show);
  }

  void _show() {
    _repaint = null;
    final latest = widget.previewing.progress.value;
    if (!mounted || _shown == latest) return;
    setState(() => _shown = latest);
  }

  void _onPreview(FolderAdoptionPreview preview) {
    if (!mounted || widget.previewing.cancelled) return;
    if (preview.isEngram) {
      // Opened as it is, with nothing new written: nothing to ask.
      Navigator.of(context).pop(true);
      return;
    }
    _repaint?.cancel();
    _repaint = null;
    setState(() => _preview = preview);
  }

  @override
  void dispose() {
    widget.previewing.progress.removeListener(_onProgress);
    _repaint?.cancel();
    if (_preview == null) widget.previewing.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final preview = _preview;
    if (preview == null) return _looking(context, l10n);
    final body = StringBuffer(
      l10n.adoptFolderBody(preview.name, preview.fileCount),
    );
    if (preview.crlfCount > 0) {
      body
        ..write(' ')
        ..write(l10n.adoptFolderLineEndings(preview.crlfCount));
    }
    return AlertDialog.adaptive(
      title: Text(l10n.adoptFolderTitle),
      content: Text(body.toString()),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.cancel),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l10n.adopt),
        ),
      ],
    );
  }

  /// The dialog while the pass runs: the folder's name, a bar, a caption
  /// that is also the accessible, live-region label, and Cancel.
  Widget _looking(BuildContext context, AppLocalizations l10n) {
    final progress = _shown;
    final caption = progress == null
        ? l10n.adoptFolderListing
        : l10n.adoptFolderLooked(
            formatDecimal(context, progress.done),
            formatDecimal(context, progress.total),
          );
    // Indeterminate while listing — unless motion is to be reduced, in
    // which case a still, empty bar says the same without sweeping.
    final value = progress != null
        ? (progress.total == 0 ? 1.0 : progress.done / progress.total)
        : MediaQuery.disableAnimationsOf(context)
            ? 0.0
            : null;
    return AlertDialog.adaptive(
      title: Text(l10n.adoptFolderLooking(widget.previewing.name)),
      content: Semantics(
        label: caption,
        liveRegion: true,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LinearProgressIndicator(value: value, minHeight: 3),
            const SizedBox(height: 8),
            ExcludeSemantics(
              child: Text(
                caption,
                style: Theme.of(context).textTheme.bodySmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l10n.cancel),
        ),
      ],
    );
  }
}
