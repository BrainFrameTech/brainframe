import 'dart:async';

import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';
import '../note_reconciler.dart';

/// A thin progress bar with a caption, shown in the sidebar while the scan is
/// bringing a folder's files into the note catalog for the first time.
///
/// Adoption runs behind the UI — a first scan over a large folder mints every
/// note in it, which on the slowest target is minutes — and the engram is
/// usable throughout, so this is the only thing that says it is happening.
/// It renders nothing at all when no adoption is running: not a collapsed
/// bar, not an empty row, so the sidebar is pixel-identical to how it was
/// before the scan existed, and a steady-state scan — a stat per note on
/// every launch and resume — never flashes anything.
///
/// **It repaints at most every [repaintInterval], not once per note.** The
/// reconciler reports every file, and a desktop seeds several hundred a
/// second; painting a frame for each would cost more than the seeding does
/// and — since the scan and the UI share one isolate — slow the scan itself.
/// Under a software renderer the first cut of this widget made adoption ten
/// times slower than the same scan with nobody watching. The first event and
/// the last always paint at once, so the bar appears promptly and never
/// lingers; only the steps between are coalesced. That is also the shape
/// e-ink can live with: a handful of discrete redraws, none once it is done.
class AdoptionProgressBar extends StatefulWidget {
  const AdoptionProgressBar({
    super.key,
    required this.reconciler,
    this.repaintInterval = const Duration(milliseconds: 250),
  });

  /// Where the progress comes from, or null when the engram has no catalog
  /// — in which case nothing is ever adopted and nothing is ever shown.
  final NoteReconciler? reconciler;

  /// The least time between two repaints of an advancing bar.
  final Duration repaintInterval;

  @override
  State<AdoptionProgressBar> createState() => _AdoptionProgressBarState();
}

class _AdoptionProgressBarState extends State<AdoptionProgressBar> {
  StreamSubscription<AdoptionProgress?>? _subscription;
  AdoptionProgress? _shown;
  AdoptionProgress? _latest;
  Timer? _repaint;

  @override
  void initState() {
    super.initState();
    _listen();
  }

  @override
  void didUpdateWidget(AdoptionProgressBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.reconciler != oldWidget.reconciler) {
      _subscription?.cancel();
      _repaint?.cancel();
      _repaint = null;
      _listen();
    }
  }

  void _listen() {
    final reconciler = widget.reconciler;
    _shown = _latest = reconciler?.currentAdoption;
    _subscription = reconciler?.adoption.listen(_onProgress);
  }

  void _onProgress(AdoptionProgress? progress) {
    _latest = progress;
    final terminal = progress == null || !progress.isRunning;
    final first = _shown == null;
    if (terminal || first) {
      _repaint?.cancel();
      _repaint = null;
      _show();
      return;
    }
    // A step in the middle: shown at the next tick, together with whatever
    // else arrives before it.
    _repaint ??= Timer(widget.repaintInterval, _show);
  }

  void _show() {
    _repaint = null;
    if (!mounted || _shown == _latest) return;
    setState(() => _shown = _latest);
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _repaint?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final progress = _shown;
    if (progress == null || !progress.isRunning) {
      return const SizedBox.shrink();
    }
    final l10n = AppLocalizations.of(context);
    final caption = l10n.adoptionProgress(progress.done, progress.total);
    return Semantics(
      label: caption,
      // Announced as it changes, so a screen reader hears the scan finish
      // without the user polling the sidebar for it.
      liveRegion: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            LinearProgressIndicator(
              value: progress.done / progress.total,
              minHeight: 3,
            ),
            const SizedBox(height: 4),
            ExcludeSemantics(
              child: Text(
                caption,
                style: Theme.of(context).textTheme.labelSmall,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
