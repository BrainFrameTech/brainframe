import 'package:flutter/material.dart';

import '../engram/crdt/catalog.dart';
import '../engram/engram.dart';
import '../engram/engram_repository.dart';
import '../engram/note_reconciler.dart';
import '../engram/ui/note_status_bar.dart';
import '../l10n/gen/app_localizations.dart';

/// Lists the registry-backed engrams that can be forgotten.
typedef ForgettableEngramsLoader = Future<List<RegisteredEngram>> Function();

/// Forgets the engram with the given id (registry-only, never touches disk).
typedef EngramForgetter = Future<void> Function(String id);

/// Deletes BrainFrame's files for the engram with the given id — its
/// `.brainframe/` tree and this device's store — and forgets it. Throws when
/// a step fails; the entry is then still listed for a retry.
typedef EngramCleaner = Future<void> Function(String id);

/// Records [bytes] as the given engram's note size ceiling and returns the
/// engram enforcing it (the note size ceiling design, Decision 7).
typedef CeilingChanger = Future<Engram> Function(Engram engram, int bytes);

/// The Housekeeping settings pane: what this device knows about the active
/// engram's notes, and maintenance jobs on engrams.
///
/// **The ledger** is Decision 9's promise paid out: instead of a prompt on
/// open asking whether an engram came from another machine — which most users
/// cannot answer, and which would trade a possible history loss for a certain
/// outage — the app reads the shared map, adopts what it finds, and shows the
/// result here: devices seen, notes minted here, notes adopted and awaiting
/// their history, deleted notes remembered, and the scans this session that
/// changed something. Above all the scan that deleted and created in one
/// pass, which is a rename past recognition and a history that stayed with
/// the tombstone — the one cost the design requires to be visible.
///
/// **Forgetting** a registry-backed engram drops it from BrainFrame's list (and
/// the switcher) without touching its files on disk. This is how a user clears
/// a dangling entry (a folder they deleted) or simply stops managing a folder
/// with BrainFrame. Only registry-backed engrams appear; built-in and container
/// engrams aren't forgettable (see [EngramRepository.forget]).
///
/// **Cleaning up** goes further: it deletes everything BrainFrame made for the
/// engram — the `.brainframe/` tree in the folder and this device's store —
/// and then forgets it, so the folder is a plain folder of notes again (see
/// [EngramRepository.cleanUp]). It is refused for the engram that is open,
/// whose store is a live database and whose identity map is rewritten on a
/// timer: the button is disabled with a hint to switch away first.
///
/// A custom [SettingsCategory] detail pane (like About), because it renders a
/// live list with actions rather than a fixed set of control rows. It depends on
/// capabilities rather than the whole repository, so it stays trivially
/// testable (no filesystem in a widget test).
class HousekeepingPane extends StatefulWidget {
  const HousekeepingPane({
    super.key,
    required this.load,
    required this.forget,
    required this.cleanUp,
    this.engram,
    this.notes,
    this.changeCeiling,
    this.onCeilingChanged,
    this.onOpenNote,
  });

  /// Wires the pane to a repository: `HousekeepingPane.forRepository(repo)`,
  /// plus the active engram and its reconciler when there are any.
  HousekeepingPane.forRepository(
    EngramRepository repository, {
    Key? key,
    Engram? engram,
    NoteReconciler? notes,
    void Function(Engram engram)? onCeilingChanged,
    void Function(String path)? onOpenNote,
  }) : this(
         key: key,
         load: repository.registeredEngrams,
         forget: repository.forget,
         cleanUp: repository.cleanUp,
         engram: engram,
         notes: notes,
         changeCeiling: repository.setNoteSizeCeiling,
         onCeilingChanged: onCeilingChanged,
         onOpenNote: onOpenNote,
       );

  final ForgettableEngramsLoader load;
  final EngramForgetter forget;
  final EngramCleaner cleanUp;

  /// Writes a new note size ceiling for the active engram, or null when the
  /// pane cannot (no engram, or nowhere to write it).
  final CeilingChanger? changeCeiling;

  /// Told the engram as it now is after a ceiling change, so the caller can
  /// push it back into the scope the way a rename is.
  final void Function(Engram engram)? onCeilingChanged;

  /// Opens the note at an engram-relative path in the editor — the way out
  /// of a notice to the note it names (Decision 6). Null when the pane has
  /// no editor to hand a note to.
  final void Function(String path)? onOpenNote;

  /// The active engram, or null when no engram is open — in which case the
  /// ledger section is not shown at all.
  final Engram? engram;

  /// The active engram's reconciler, or null when it has no note catalog: a
  /// read-only engram, or a platform with no local database. Then the
  /// section says so instead of counting.
  final NoteReconciler? notes;

  @override
  State<HousekeepingPane> createState() => _HousekeepingPaneState();
}

class _HousekeepingPaneState extends State<HousekeepingPane> {
  late Future<List<RegisteredEngram>> _engrams;

  /// The active engram as this pane knows it: the widget's, until a ceiling
  /// change hands back a copy enforcing the new value.
  late Engram? _engram = widget.engram;
  Future<NoteLedger>? _ledger;
  Future<List<ScanNotice>>? _scans;
  Future<List<PendingNote>>? _pending;

  @override
  void initState() {
    super.initState();
    _engrams = widget.load();
    _ledger = widget.notes?.ledger();
    _scans = widget.notes?.recentScans();
    _pending = widget.notes?.awaitingDecision();
  }

  /// After a decision, every part of the section re-reads: the note left
  /// the pending list, the ledger's counts moved, and a scan card was added.
  void _reloadNotes() {
    setState(() {
      _ledger = widget.notes?.ledger();
      _scans = widget.notes?.recentScans();
      _pending = widget.notes?.awaitingDecision();
    });
  }

  Future<void> _reconstruct(PendingNote note) async {
    await widget.notes?.reconstruct(note.path);
    if (mounted) _reloadNotes();
  }

  Future<void> _convert(PendingNote note) async {
    await widget.notes?.convertToPlainFile(note.path);
    if (mounted) _reloadNotes();
  }

  /// The Housekeeping job that changes the engram's ceiling (Decision 7):
  /// counted, confirmed, written to the marker, pushed into the scope, and
  /// enforced by the reconciler at once, so a note the new limit puts over
  /// the line is listed above before the pane is even reopened.
  Future<void> _changeCeiling(int bytes) async {
    final engram = _engram;
    final change = widget.changeCeiling;
    final notes = widget.notes;
    if (engram == null || change == null || notes == null) return;
    final l10n = AppLocalizations.of(context);
    final lowering = bytes < engram.noteSizeCeilingBytes;
    final over = lowering ? await notes.countTextNotesOver(bytes) : 0;
    if (!mounted) return;
    final limit = formatDecimal(context, bytes);
    final confirmed = await showAdaptiveDialog<bool>(
      context: context,
      builder: (context) => AlertDialog.adaptive(
        title: Text(
          lowering
              ? l10n.housekeepingCeilingLowerTitle(limit)
              : l10n.housekeepingCeilingRaiseTitle(limit),
        ),
        content: Text(
          lowering
              ? l10n.housekeepingCeilingLowerBody(over)
              : l10n.housekeepingCeilingRaiseBody,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.housekeepingCeilingChange),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final updated = await change(engram, bytes);
      await notes.setNoteSizeCeiling(bytes);
      if (!mounted) return;
      widget.onCeilingChanged?.call(updated);
      setState(() => _engram = updated);
      _reloadNotes();
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.housekeepingCeilingChanged(limit))),
      );
    } catch (error) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(l10n.housekeepingCeilingFailed('$error'))),
      );
    }
  }

  Future<void> _dismiss(ScanNotice scan) async {
    final id = scan.id;
    if (id == null) return;
    await widget.notes?.dismissScan(id);
    if (!mounted) return;
    // A block, not an arrow: an arrow would hand setState the Future the
    // assignment evaluates to, which it refuses.
    setState(() {
      _scans = widget.notes?.recentScans();
    });
  }

  void _reload() {
    setState(() {
      _engrams = widget.load();
    });
  }

  Future<void> _forget(RegisteredEngram engram) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showAdaptiveDialog<bool>(
      context: context,
      builder: (context) => AlertDialog.adaptive(
        title: Text(l10n.housekeepingConfirmTitle(engram.displayName)),
        content: Text(l10n.housekeepingConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.housekeepingForget),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.forget(engram.id);
    if (mounted) _reload();
  }

  Future<void> _cleanUp(RegisteredEngram engram) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showAdaptiveDialog<bool>(
      context: context,
      builder: (context) => AlertDialog.adaptive(
        title: Text(l10n.housekeepingCleanUpConfirmTitle(engram.displayName)),
        content: Text(l10n.housekeepingCleanUpConfirmBody(engram.path)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l10n.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l10n.housekeepingCleanUp),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await widget.cleanUp(engram.id);
    } catch (error) {
      if (!mounted) return;
      // Reload first: a failure part-way may have removed the marker, which
      // the row now shows as missing — and the entry is still there to retry.
      _reload();
      await showAdaptiveDialog<void>(
        context: context,
        builder: (context) => AlertDialog.adaptive(
          title: Text(l10n.housekeepingCleanUpFailedTitle(engram.displayName)),
          content: Text(l10n.housekeepingCleanUpFailedBody(error.toString())),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.ok),
            ),
          ],
        ),
      );
      return;
    }
    if (mounted) _reload();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

    return LayoutBuilder(
      builder: (context, constraints) {
        final hPad = constraints.maxWidth < 540 ? 18.0 : 32.0;
        return FutureBuilder<List<RegisteredEngram>>(
          future: _engrams,
          builder: (context, snapshot) {
            final engrams = snapshot.data;
            return ListView(
              padding: EdgeInsets.fromLTRB(hPad, 26, hPad, 44),
              children: [
                Text(
                  l10n.settingsHousekeepingName,
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.01 * 22,
                  ),
                ),
                const SizedBox(height: 24),
                if (_engram != null) ...[
                  _LedgerSection(
                    engram: _engram!,
                    notes: widget.notes,
                    ledger: _ledger,
                    scans: _scans,
                    pending: _pending,
                    onDismiss: _dismiss,
                    onReconstruct: _reconstruct,
                    onConvert: _convert,
                    onChangeCeiling: widget.changeCeiling == null
                        ? null
                        : _changeCeiling,
                    onOpenNote: widget.onOpenNote,
                  ),
                  const SizedBox(height: 28),
                ],
                Text(
                  l10n.housekeepingForgetTitle,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  l10n.housekeepingIntro,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.45,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                if (engrams == null)
                  const Center(child: CircularProgressIndicator.adaptive())
                else if (engrams.isEmpty)
                  _EmptyState(message: l10n.housekeepingEmpty)
                else
                  for (final engram in engrams)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: _EngramRow(
                        engram: engram,
                        active: engram.id == widget.engram?.id,
                        onForget: () => _forget(engram),
                        onCleanUp: () => _cleanUp(engram),
                      ),
                    ),
              ],
            );
          },
        );
      },
    );
  }
}

/// What this device knows about the active engram's notes: the counts, and
/// this session's scans that changed something.
class _LedgerSection extends StatelessWidget {
  const _LedgerSection({
    required this.engram,
    required this.notes,
    required this.ledger,
    required this.scans,
    required this.pending,
    required this.onDismiss,
    required this.onReconstruct,
    required this.onConvert,
    required this.onChangeCeiling,
    required this.onOpenNote,
  });

  final Engram engram;
  final NoteReconciler? notes;
  final Future<NoteLedger>? ledger;
  final Future<List<ScanNotice>>? scans;
  final Future<List<PendingNote>>? pending;
  final void Function(ScanNotice scan) onDismiss;
  final void Function(PendingNote note) onReconstruct;
  final void Function(PendingNote note) onConvert;

  /// Null when the ceiling cannot be changed here.
  final void Function(int bytes)? onChangeCeiling;
  final void Function(String path)? onOpenNote;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final notes = this.notes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.housekeepingLedgerTitle(engram.displayName),
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(
          l10n.housekeepingLedgerIntro,
          style: TextStyle(
            fontSize: 13,
            height: 1.45,
            color: scheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 12),
        if (notes == null || ledger == null || scans == null)
          _Card(child: _Line(l10n.housekeepingLedgerUnavailable))
        else ...[
          FutureBuilder<NoteLedger>(
            future: ledger,
            builder: (context, snapshot) {
              final counts = snapshot.data;
              if (counts == null) {
                return const Center(
                  child: CircularProgressIndicator.adaptive(),
                );
              }
              return _Card(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Line(l10n.housekeepingPeers(counts.peers)),
                    _Line(l10n.housekeepingMinted(counts.minted)),
                    _Line(l10n.housekeepingAdopted(counts.adopted)),
                    if (counts.unclaimed > 0)
                      _Line(l10n.housekeepingUnclaimed(counts.unclaimed)),
                    _Line(l10n.housekeepingTombstoned(counts.tombstoned)),
                    if (counts.plainFiles > 0)
                      _Line(
                        l10n.housekeepingPlainFiles(
                          counts.plainFiles,
                          formatDecimal(context, engram.noteSizeCeilingBytes),
                        ),
                      ),
                    if (counts.lastScanAt != null)
                      _Line(
                        l10n.housekeepingLastScan(
                          MaterialLocalizations.of(context).formatTimeOfDay(
                            TimeOfDay.fromDateTime(counts.lastScanAt!),
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
          if (onChangeCeiling != null) ...[
            const SizedBox(height: 16),
            Text(
              l10n.housekeepingCeilingTitle,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            _CeilingCard(
              ceilingBytes: engram.noteSizeCeilingBytes,
              onChange: onChangeCeiling!,
            ),
          ],
          FutureBuilder<List<PendingNote>>(
            future: pending,
            builder: (context, snapshot) {
              final waiting = snapshot.data;
              // Nothing at all when there is nothing to decide — the
              // ordinary case — so the pane is exactly as it was.
              if (waiting == null || waiting.isEmpty) {
                return const SizedBox.shrink();
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 16),
                  Text(
                    l10n.housekeepingPendingTitle,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.housekeepingPendingIntro,
                    style: TextStyle(
                      fontSize: 13,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  for (final note in waiting)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _PendingCard(
                        note: note,
                        ceilingBytes: engram.noteSizeCeilingBytes,
                        onReconstruct: () => onReconstruct(note),
                        onConvert: () => onConvert(note),
                        onOpen: onOpenNote == null
                            ? null
                            : () => onOpenNote!(note.path),
                      ),
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 16),
          Text(
            l10n.housekeepingScansTitle,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          FutureBuilder<List<ScanNotice>>(
            future: scans,
            builder: (context, snapshot) {
              final recent = snapshot.data;
              if (recent == null) return const SizedBox.shrink();
              if (recent.isEmpty) {
                return _Card(child: _Line(l10n.housekeepingScansEmpty));
              }
              return Column(
                children: [
                  for (final scan in recent)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: _ScanCard(
                        scan: scan,
                        ceilingBytes: engram.noteSizeCeilingBytes,
                        onDismiss: scan.id == null
                            ? null
                            : () => onDismiss(scan),
                        onOpenNote: onOpenNote,
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ],
    );
  }
}

/// One scan that changed something or failed: a summary line, then the
/// details that matter — a history loss, an unlisted folder, each failure.
class _ScanCard extends StatelessWidget {
  const _ScanCard({
    required this.scan,
    required this.ceilingBytes,
    required this.onDismiss,
    required this.onOpenNote,
  });

  /// Opens a note the card names, or null when there is no editor to open
  /// it in.
  final void Function(String path)? onOpenNote;

  /// The notes a reader of this card would want to go to: the ones the
  /// ceiling touched. Created, moved, and deleted notes are not offered —
  /// the first two are the ordinary case, the last cannot be opened.
  List<String> get _openable => {
    ...scan.report.oversized,
    ...scan.report.awaitingDecision,
    ...scan.report.converted,
    ...scan.report.convertedElsewhere.keys,
    ...scan.report.reconstructed.keys,
    ...scan.report.reconstructed.values,
  }.toList();

  final ScanNotice scan;

  /// The engram's note size ceiling, for the line that explains why a file
  /// was tracked as a plain file.
  final int ceilingBytes;

  /// Hides the card; null for a notice that was never recorded and so
  /// cannot be dismissed.
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final report = scan.report;
    final parts = <String>[
      if (report.reconciled.isNotEmpty)
        l10n.housekeepingScanUpdated(report.reconciled.length),
      if (report.created.isNotEmpty)
        l10n.housekeepingScanCreated(report.created.length),
      if (report.oversized.isNotEmpty)
        l10n.housekeepingScanOversized(report.oversized.length),
      if (report.awaitingDecision.isNotEmpty)
        l10n.housekeepingScanAwaiting(report.awaitingDecision.length),
      if (report.reconstructed.isNotEmpty)
        l10n.housekeepingScanReconstructed(report.reconstructed.length),
      if (report.converted.isNotEmpty)
        l10n.housekeepingScanConverted(report.converted.length),
      if (report.convertedElsewhere.isNotEmpty)
        l10n.housekeepingScanConvertedElsewhere(
          report.convertedElsewhere.length,
        ),
      if (report.adopted.isNotEmpty)
        l10n.housekeepingScanAdopted(report.adopted.length),
      if (report.moved.isNotEmpty)
        l10n.housekeepingScanMoved(report.moved.length),
      if (report.tombstoned.isNotEmpty)
        l10n.housekeepingScanDeleted(report.tombstoned.length),
      if (report.retired.isNotEmpty)
        l10n.housekeepingScanRetired(report.retired.length),
      if (report.failed.isNotEmpty)
        l10n.housekeepingScanFailed(report.failed.length),
    ];
    final time = MaterialLocalizations.of(
      context,
    ).formatTimeOfDay(TimeOfDay.fromDateTime(scan.at));
    final when = '$time · ${l10n.housekeepingScanTrigger(scan.trigger.name)}';
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                when,
                style: TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(child: _Line(parts.join(', '))),
              if (onDismiss != null) ...[
                const SizedBox(width: 12),
                Semantics(
                  button: true,
                  label: l10n.housekeepingDismissScan(time),
                  child: ExcludeSemantics(
                    child: TextButton(
                      onPressed: onDismiss,
                      child: Text(l10n.housekeepingDismiss),
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (scan.lostHistory)
            _Line(
              l10n.housekeepingHistoryLoss(
                report.tombstoned.join(', '),
                report.created.join(', '),
              ),
              emphasis: true,
            ),
          if (report.oversized.isNotEmpty)
            _Line(
              l10n.housekeepingOversizedDetail(
                formatDecimal(context, ceilingBytes),
                report.oversized.join(', '),
              ),
              emphasis: true,
            ),
          if (report.awaitingDecision.isNotEmpty)
            _Line(
              l10n.housekeepingAwaitingDetail(
                report.awaitingDecision.join(', '),
              ),
              emphasis: true,
            ),
          for (final entry in report.reconstructed.entries)
            _Line(l10n.housekeepingReconstructedDetail(entry.key, entry.value)),
          if (report.converted.isNotEmpty)
            _Line(
              l10n.housekeepingConvertedDetail(report.converted.join(', ')),
            ),
          for (final entry in report.convertedElsewhere.entries)
            _Line(
              l10n.housekeepingConvertedElsewhereDetail(entry.key, entry.value),
              emphasis: true,
            ),
          if (!report.complete) _Line(l10n.housekeepingScanIncomplete),
          for (final failure in report.failed.entries)
            _Line(
              l10n.housekeepingScanFailure(
                failure.key,
                failure.value.toString(),
              ),
              emphasis: true,
            ),
          if (onOpenNote != null && _openable.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: 8,
                children: [
                  for (final path in _openable)
                    _OpenNoteButton(
                      path: path,
                      onOpen: () => onOpenNote!(path),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// A small button that opens a note the pane names (Decision 6: one tap
/// from the notice to the note).
class _OpenNoteButton extends StatelessWidget {
  const _OpenNoteButton({required this.path, required this.onOpen});

  final String path;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Semantics(
      button: true,
      label: l10n.housekeepingOpenNote(path),
      child: ExcludeSemantics(
        child: TextButton.icon(
          onPressed: onOpen,
          icon: const Icon(Icons.open_in_new, size: 14),
          label: Text(path, style: const TextStyle(fontSize: 12)),
        ),
      ),
    );
  }
}

/// The engram's note size ceiling and the presets it can be changed to —
/// the Housekeeping job of Decision 7. The card states what the limit means
/// and what this build can open; the confirmation, which [onChange] shows,
/// states the consequence of the particular change and its count.
class _CeilingCard extends StatelessWidget {
  const _CeilingCard({required this.ceilingBytes, required this.onChange});

  /// The values offered: the capability and the two halvings below it.
  /// Enough to lower an engram for a small device and raise it back; a free
  /// number would invite values nobody has measured.
  static const List<int> presets = [
    noteSizeCapabilityBytes ~/ 4,
    noteSizeCapabilityBytes ~/ 2,
    noteSizeCapabilityBytes,
  ];

  final int ceilingBytes;
  final void Function(int bytes) onChange;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Line(
            l10n.housekeepingCeilingCurrent(
              formatDecimal(context, ceilingBytes),
              formatDecimal(context, noteSizeCapabilityBytes),
            ),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            children: [
              for (final bytes in presets)
                if (bytes != ceilingBytes)
                  Semantics(
                    button: true,
                    label: l10n.housekeepingCeilingChangeToLabel(
                      formatDecimal(context, bytes),
                    ),
                    child: ExcludeSemantics(
                      child: OutlinedButton(
                        onPressed: () => onChange(bytes),
                        child: Text(
                          l10n.housekeepingCeilingChangeTo(
                            formatDecimal(context, bytes),
                          ),
                        ),
                      ),
                    ),
                  ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One note awaiting a decision: what happened, the two ways out, and a
/// button for each. The card is the asking — it says what each choice
/// keeps and loses (the note size ceiling design, Decisions 4 and 5) — so
/// the buttons act at once rather than opening a second dialog that would
/// say the same thing again.
class _PendingCard extends StatelessWidget {
  const _PendingCard({
    required this.note,
    required this.ceilingBytes,
    required this.onReconstruct,
    required this.onConvert,
    required this.onOpen,
  });

  final PendingNote note;
  final int ceilingBytes;
  final VoidCallback onReconstruct;
  final VoidCallback onConvert;

  /// Opens the note read-only, where the same two verbs are on the status
  /// bar; null when there is no editor to open it in.
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Line(
            l10n.housekeepingPendingNote(
              note.path,
              formatDecimal(context, note.sizeBytes),
              formatDecimal(context, ceilingBytes),
            ),
            emphasis: true,
          ),
          _Line(
            l10n.housekeepingPendingChoices(
              asidePathFor(note.path).split('/').last,
            ),
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            children: [
              Semantics(
                button: true,
                label: l10n.housekeepingReconstructNote(note.path),
                child: ExcludeSemantics(
                  child: FilledButton.tonal(
                    onPressed: onReconstruct,
                    child: Text(l10n.housekeepingReconstruct),
                  ),
                ),
              ),
              Semantics(
                button: true,
                label: l10n.housekeepingConvertNote(note.path),
                child: ExcludeSemantics(
                  child: TextButton(
                    onPressed: onConvert,
                    child: Text(l10n.housekeepingConvert),
                  ),
                ),
              ),
              if (onOpen != null)
                _OpenNoteButton(path: note.path, onOpen: onOpen!),
            ],
          ),
        ],
      ),
    );
  }
}

class _Card extends StatelessWidget {
  const _Card({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      child: child,
    );
  }
}

/// One line of the ledger. [emphasis] marks a line the user should read —
/// a history loss, a failure — in the error colour, without an icon that
/// would need its own label.
class _Line extends StatelessWidget {
  const _Line(this.text, {this.emphasis = false});
  final String text;
  final bool emphasis;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          height: 1.45,
          color: emphasis ? scheme.error : scheme.onSurface,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 40),
      child: Center(
        child: Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            height: 1.5,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// One engram added from a folder: its name, path, and the two actions.
///
/// Clean up is disabled while [active] — the engram is open, so its store is
/// a live database and its identity map is rewritten on a timer — and a hint
/// under the path says to switch away first. Forget stays available: it only
/// touches the registry, and the open engram survives it for the session.
class _EngramRow extends StatelessWidget {
  const _EngramRow({
    required this.engram,
    required this.active,
    required this.onForget,
    required this.onCleanUp,
  });

  final RegisteredEngram engram;
  final bool active;
  final VoidCallback onForget;
  final VoidCallback onCleanUp;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    // The error outline only while enabled: a disabled Clean up falls
    // through (null) to the theme's disabled outline, so it reads as
    // disabled rather than as a red button that does not respond.
    final destructive =
        OutlinedButton.styleFrom(
          foregroundColor: scheme.error,
          padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        ).copyWith(
          side: WidgetStateProperty.resolveWith(
            (states) => states.contains(WidgetState.disabled)
                ? null
                : BorderSide(color: scheme.error),
          ),
        );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        engram.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    if (!engram.available) ...[
                      const SizedBox(width: 8),
                      _MissingBadge(label: l10n.housekeepingMissing),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  engram.path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (active) ...[
                  const SizedBox(height: 4),
                  Text(
                    l10n.housekeepingCleanUpActive,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 16),
          Semantics(
            button: true,
            label: '${l10n.housekeepingForget} ${engram.displayName}',
            child: ExcludeSemantics(
              child: OutlinedButton(
                onPressed: onForget,
                style: destructive,
                child: Text(l10n.housekeepingForget),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Semantics(
            button: true,
            enabled: !active,
            label: '${l10n.housekeepingCleanUp} ${engram.displayName}',
            child: ExcludeSemantics(
              child: OutlinedButton(
                onPressed: active ? null : onCleanUp,
                style: destructive,
                child: Text(l10n.housekeepingCleanUp),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MissingBadge extends StatelessWidget {
  const _MissingBadge({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label.toUpperCase(),
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.05 * 10,
          color: scheme.onErrorContainer,
        ),
      ),
    );
  }
}
