import 'package:flutter/material.dart';

import '../engram/engram.dart';
import '../engram/engram_repository.dart';
import '../engram/note_reconciler.dart';
import '../l10n/gen/app_localizations.dart';

/// Lists the registry-backed engrams that can be forgotten.
typedef ForgettableEngramsLoader = Future<List<RegisteredEngram>> Function();

/// Forgets the engram with the given id (registry-only, never touches disk).
typedef EngramForgetter = Future<void> Function(String id);

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
/// A custom [SettingsCategory] detail pane (like About), because it renders a
/// live list with actions rather than a fixed set of control rows. It depends on
/// capabilities rather than the whole repository, so it stays trivially
/// testable (no filesystem in a widget test).
class HousekeepingPane extends StatefulWidget {
  const HousekeepingPane({
    super.key,
    required this.load,
    required this.forget,
    this.engram,
    this.notes,
  });

  /// Wires the pane to a repository: `HousekeepingPane.forRepository(repo)`,
  /// plus the active engram and its reconciler when there are any.
  HousekeepingPane.forRepository(
    EngramRepository repository, {
    Key? key,
    Engram? engram,
    NoteReconciler? notes,
  }) : this(
         key: key,
         load: repository.registeredEngrams,
         forget: repository.forget,
         engram: engram,
         notes: notes,
       );

  final ForgettableEngramsLoader load;
  final EngramForgetter forget;

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
  Future<NoteLedger>? _ledger;

  @override
  void initState() {
    super.initState();
    _engrams = widget.load();
    _ledger = widget.notes?.ledger();
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
                if (widget.engram != null) ...[
                  _LedgerSection(
                    engram: widget.engram!,
                    notes: widget.notes,
                    ledger: _ledger,
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
                        onForget: () => _forget(engram),
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
  });

  final Engram engram;
  final NoteReconciler? notes;
  final Future<NoteLedger>? ledger;

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
        if (notes == null || ledger == null)
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
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 16),
          Text(
            l10n.housekeepingScansTitle,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          if (notes.recentScans.isEmpty)
            _Card(child: _Line(l10n.housekeepingScansEmpty))
          else
            for (final scan in notes.recentScans)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: _ScanCard(scan: scan),
              ),
        ],
      ],
    );
  }
}

/// One scan that changed something or failed: a summary line, then the
/// details that matter — a history loss, an unlisted folder, each failure.
class _ScanCard extends StatelessWidget {
  const _ScanCard({required this.scan});

  final ScanNotice scan;

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
    return _Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                time,
                style: TextStyle(
                  fontSize: 12,
                  fontFamily: 'monospace',
                  color: scheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(child: _Line(parts.join(', '))),
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
          if (!report.complete) _Line(l10n.housekeepingScanIncomplete),
          for (final failure in report.failed.entries)
            _Line(
              l10n.housekeepingScanFailure(
                failure.key,
                failure.value.toString(),
              ),
              emphasis: true,
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

class _EngramRow extends StatelessWidget {
  const _EngramRow({required this.engram, required this.onForget});

  final RegisteredEngram engram;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;

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
                style: OutlinedButton.styleFrom(
                  foregroundColor: scheme.error,
                  side: BorderSide(color: scheme.error),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 13,
                    vertical: 8,
                  ),
                ),
                child: Text(l10n.housekeepingForget),
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
