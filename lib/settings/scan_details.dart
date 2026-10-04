/// What a scan card shows behind its Details toggle (the device names
/// design, Decision 5): each kind's paths, moves as from → to, a sentence
/// saying why for anything unusual, what it cost, the devices involved, and
/// exact times.
///
/// **Everything here was captured when the event was recorded** (Decision 4)
/// except the devices' names, which are looked up now (Decision 2): a name is
/// for recognizing a device today, so an old card shows a device by the name
/// it has now. A record from before the details shows its paths, and the
/// sentences it has the facts for.
///
/// Static, like the rest of the pane: nothing here animates or changes on
/// hover, so it reads the same on an e-ink panel as anywhere else.
library;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../engram/note_reconciler.dart';
import '../l10n/gen/app_localizations.dart';
import '../engram/ui/note_status_bar.dart' show formatDecimal;

/// How many paths a kind lists before "and N more".
const int scanDetailsPathCap = 5;

/// How [peer] is named: its name, or its short ID for one with none, and
/// "(this device)" after this device.
String deviceLabel(
  AppLocalizations l10n,
  List<SeenDevice> devices,
  String peer,
) {
  SeenDevice? known;
  for (final device in devices) {
    if (device.peer == peer) known = device;
  }
  final name =
      known?.name ??
      l10n.housekeepingUnnamedDevice(SeenDevice(peer: peer).shortId);
  return known?.isThisDevice ?? false
      ? l10n.housekeepingThisDevice(name)
      : name;
}

/// [items] as one phrase — "a, b and c" — with at most [cap] named and the
/// rest counted: "a, b and 3 more".
String nameList(AppLocalizations l10n, List<String> items, {int cap = 5}) {
  final shown = items.take(cap).toList();
  final hidden = items.length - shown.length;
  final all = [...shown, if (hidden > 0) l10n.housekeepingAndMore(hidden)];
  if (all.length < 2) return all.join();
  return l10n.housekeepingListPair(
    all.take(all.length - 1).join(', '),
    all.last,
  );
}

/// The Details of one scan card.
class ScanDetails extends StatelessWidget {
  const ScanDetails({
    super.key,
    required this.scan,
    required this.devices,
    required this.onOpenNote,
  });

  final ScanNotice scan;

  /// The devices the ledger knows, for names; empty until it has loaded,
  /// when every device reads as its short ID and nothing is attributed.
  final List<SeenDevice> devices;

  /// Opens a note the card names, or null with no editor to open it in.
  final void Function(String path)? onOpenNote;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final report = scan.report;
    final locale = Localizations.localeOf(context).toString();
    final seconds = DateFormat.jms(locale);
    String time(DateTime at) => seconds.format(at.toLocal());
    String device(String peer) => deviceLabel(l10n, devices, peer);

    // A change found on disk was taken in here, never "made" here (Decision
    // 3): said once for the card, since it is the same device for every
    // such kind, and only once the ledger has said which device that is.
    final foundOnDisk =
        report.reconciled.isNotEmpty ||
        report.created.isNotEmpty ||
        report.moved.isNotEmpty ||
        report.tombstoned.isNotEmpty;
    String? takenIn;
    for (final known in devices) {
      if (known.isThisDevice && foundOnDisk) {
        takenIn = l10n.housekeepingTakenIn(device(known.peer));
      }
    }

    String? gap(DateTime earlier, DateTime later) {
      final span = later.difference(earlier);
      if (span <= Duration.zero) return null;
      if (span < const Duration(minutes: 1)) {
        return l10n.housekeepingGapSeconds(span.inSeconds);
      }
      if (span < const Duration(hours: 1)) {
        return l10n.housekeepingGapMinutes(span.inMinutes);
      }
      if (span < const Duration(days: 2)) {
        return l10n.housekeepingGapHours(span.inHours);
      }
      return l10n.housekeepingGapDays(span.inDays);
    }

    // Where a path's note is now, as far as this card can say for certain.
    // A folded card can hold an update to a.md and a later move of it to
    // b.md; Open should then go to b.md, not to a path that is gone. But a
    // folded card is a union of paths with the order of its events lost:
    // a.md → b.md beside b.md → c.md may be one note moved twice, or c.md
    // made of b.md first and a.md moved into the space. So **no chain is
    // followed**, and one move is taken only when nothing else touched
    // either end — no creation, adoption, other move into it, or move on
    // out of it. Anything less certain opens the path as listed, which is
    // never worse than before. The line keeps the path as it was, either way.
    final arrivals = <String, int>{};
    for (final to in report.moved.values) {
      arrivals[to] = (arrivals[to] ?? 0) + 1;
    }
    bool untouched(String path, {required int movedIn}) =>
        !report.created.contains(path) &&
        !report.adopted.contains(path) &&
        (arrivals[path] ?? 0) == movedIn;
    String? whereNow(String path, {bool arrived = false}) {
      if (!untouched(path, movedIn: arrived ? 1 : 0)) return path;
      final to = report.moved[path];
      if (to == null) {
        // Deleted, with nothing else ever at the path: gone. A move's
        // destination deleted may have been deleted before the move in.
        return report.tombstoned.contains(path) && !arrived ? null : path;
      }
      // A destination that moved on again: which came first is unknown.
      if (arrived) return path;
      if (!untouched(to, movedIn: 1) ||
          report.moved.containsKey(to) ||
          report.tombstoned.contains(to)) {
        return path;
      }
      return to;
    }

    String overCeiling(String path) {
      final over = report.overCeiling[path];
      if (over == null) return path;
      return l10n.housekeepingDetailOverCeiling(
        path,
        formatDecimal(context, over.sizeBytes),
        formatDecimal(context, over.ceilingBytes),
      );
    }

    final sections = <_Section>[
      if (report.reconciled.isNotEmpty)
        _Section(l10n.housekeepingScanUpdated(report.reconciled.length), [
          for (final path in report.reconciled) _Entry(path, open: path),
        ]),
      if (report.created.isNotEmpty)
        _Section(l10n.housekeepingScanCreated(report.created.length), [
          for (final path in report.created) _Entry(path, open: path),
        ]),
      if (report.oversized.isNotEmpty)
        _Section(l10n.housekeepingScanOversized(report.oversized.length), [
          for (final path in report.oversized)
            _Entry(overCeiling(path), open: path),
        ]),
      if (report.awaitingDecision.isNotEmpty)
        _Section(
          l10n.housekeepingScanAwaiting(report.awaitingDecision.length),
          [
            for (final path in report.awaitingDecision)
              _Entry(overCeiling(path), open: path),
          ],
        ),
      if (report.reconstructed.isNotEmpty)
        _Section(
          l10n.housekeepingScanReconstructed(report.reconstructed.length),
          [
            for (final entry in report.reconstructed.entries)
              _Entry(
                l10n.housekeepingDetailArrow(entry.key, entry.value),
                open: entry.key,
              ),
          ],
        ),
      if (report.converted.isNotEmpty)
        _Section(l10n.housekeepingScanConverted(report.converted.length), [
          for (final path in report.converted)
            _Entry(switch (report.dropped[path]) {
              final count? => l10n.housekeepingDetailDropped(path, count),
              null => path,
            }, open: path),
        ]),
      if (report.convertedElsewhere.isNotEmpty)
        _Section(
          l10n.housekeepingScanConvertedElsewhere(
            report.convertedElsewhere.length,
          ),
          [
            for (final path in report.convertedElsewhere.keys)
              _Entry(switch (report.convertedBy[path]) {
                final by? => l10n.housekeepingDetailConvertedBy(
                  path,
                  device(by),
                ),
                null => path,
              }, open: path),
          ],
        ),
      if (report.adopted.isNotEmpty)
        _Section(l10n.housekeepingScanAdopted(report.adopted.length), [
          for (final path in report.adopted)
            _Entry(switch (report.adoptedFrom[path]) {
              final mint? => l10n.housekeepingDetailAdopted(
                path,
                device(mint.peer),
                time(mint.at),
              ),
              null => path,
            }, open: path),
        ]),
      if (report.moved.isNotEmpty)
        _Section(l10n.housekeepingScanMoved(report.moved.length), [
          for (final move in report.moved.entries)
            _Entry(
              () {
                final arrow = l10n.housekeepingDetailArrow(
                  move.key,
                  move.value,
                );
                return switch (report.moveMatches[move.key]) {
                  MoveDetail(match: MoveMatch.identical) =>
                    l10n.housekeepingDetailMoveIdentical(arrow),
                  MoveDetail(:final similarity?) =>
                    l10n.housekeepingDetailMoveSimilar(
                      arrow,
                      (similarity * 100).round(),
                    ),
                  _ => arrow,
                };
              }(),
              open: move.value,
              arrived: true,
            ),
        ]),
      if (report.tombstoned.isNotEmpty)
        _Section(l10n.housekeepingScanDeleted(report.tombstoned.length), [
          for (final path in report.tombstoned) _Entry(path),
        ]),
      if (report.retired.isNotEmpty)
        _Section(l10n.housekeepingScanRetired(report.retired.length), [
          for (final path in report.retired)
            switch (report.retirements[path]) {
              Retirement(:final winnerMint?, :final loserMintedAt) => _Entry(
                switch (loserMintedAt == null
                    ? null
                    : gap(winnerMint.at, loserMintedAt)) {
                  final earlier? => l10n.housekeepingDetailRetiredEarlier(
                    path,
                    device(winnerMint.peer),
                    time(winnerMint.at),
                    earlier,
                  ),
                  null => l10n.housekeepingDetailRetired(
                    path,
                    device(winnerMint.peer),
                    time(winnerMint.at),
                  ),
                },
                cost: l10n.housekeepingDetailRetiredCost(
                  report.retirements[path]!.loserChanges,
                ),
              ),
              final Retirement retirement => _Entry(
                l10n.housekeepingDetailRetiredUnknown(path),
                cost: l10n.housekeepingDetailRetiredCost(
                  retirement.loserChanges,
                ),
              ),
              null => _Entry(l10n.housekeepingDetailRetiredUnknown(path)),
            },
        ]),
      if (report.failed.isNotEmpty)
        _Section(l10n.housekeepingScanFailed(report.failed.length), [
          for (final path in report.failed.keys) _Entry(path),
        ]),
    ];

    final since = scan.since;
    final span = since == null
        ? l10n.housekeepingDetailRecordedAt(time(scan.at))
        : l10n.housekeepingDetailFolded(
            scan.ids.length,
            time(since),
            time(scan.at),
          );

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (takenIn != null) _DetailText(takenIn, muted: true),
          for (final section in sections)
            _SectionView(
              section: section,
              onOpenNote: onOpenNote,
              whereNow: whereNow,
            ),
          _DetailText(span, muted: true),
        ],
      ),
    );
  }
}

/// One kind's group: its heading, who took it in, and its first paths.
class _Section {
  const _Section(this.heading, this.entries);

  final String heading;
  final List<_Entry> entries;
}

/// One path's line, the note it opens, and — for a retirement — its cost.
class _Entry {
  const _Entry(this.text, {this.open, this.cost, this.arrived = false});

  final String text;

  /// The path the line's Open button opens; null for one with nothing to
  /// open — a deleted note, a retired identity, a failure.
  final String? open;

  /// Whether [open] is the destination of this line's own move, so the one
  /// move into it is this one and not a sign of ambiguity.
  final bool arrived;

  /// What the event cost, on its own line.
  final String? cost;
}

class _SectionView extends StatelessWidget {
  const _SectionView({
    required this.section,
    required this.onOpenNote,
    required this.whereNow,
  });

  final _Section section;
  final void Function(String path)? onOpenNote;

  /// Where a path's note is now, or null when it has nowhere to open.
  final String? Function(String path, {bool arrived}) whereNow;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final shown = section.entries.take(scanDetailsPathCap);
    final hidden = section.entries.length - shown.length;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _DetailText(section.heading, strong: true),
          for (final entry in shown) ...[
            // The Open beside the line it opens, not at the far edge: on a
            // wide window a lone icon there could belong to any line.
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(child: _DetailText(entry.text)),
                if (entry.open case final path? when onOpenNote != null)
                  if (whereNow(path, arrived: entry.arrived) case final target?)
                    _OpenButton(
                      path: target,
                      onOpen: () => onOpenNote!(target),
                    ),
              ],
            ),
            if (entry.cost case final cost?) _DetailText(cost, muted: true),
          ],
          if (hidden > 0) _DetailText(l10n.housekeepingAndMore(hidden)),
        ],
      ),
    );
  }
}

/// A compact Open for a path the line already names.
class _OpenButton extends StatelessWidget {
  const _OpenButton({required this.path, required this.onOpen});

  final String path;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Semantics(
      button: true,
      enabled: true,
      label: l10n.housekeepingOpenNote(path),
      onTap: onOpen,
      child: ExcludeSemantics(
        child: IconButton(
          onPressed: onOpen,
          visualDensity: VisualDensity.compact,
          iconSize: 16,
          icon: const Icon(Icons.open_in_new),
        ),
      ),
    );
  }
}

class _DetailText extends StatelessWidget {
  const _DetailText(this.text, {this.strong = false, this.muted = false});

  final String text;
  final bool strong;
  final bool muted;

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
          fontWeight: strong ? FontWeight.w600 : null,
          color: muted ? scheme.onSurfaceVariant : scheme.onSurface,
        ),
      ),
    );
  }
}
