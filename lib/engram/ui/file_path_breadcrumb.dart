import 'package:flutter/material.dart';

import '../../l10n/gen/app_localizations.dart';

/// The small, muted file-path breadcrumb shown above a file's content in every
/// viewer (Markdown, image, and the not-yet-supported placeholder), so the
/// header reads identically whatever the format.
///
/// Always one line, clipped at the edge rather than wrapped: a deep path on a
/// narrow screen would otherwise grow the header and push the file's content
/// off screen. The accessibility label still carries the whole path, so screen
/// readers announce it rather than reading the raw slash-separated string.
class FilePathBreadcrumb extends StatelessWidget {
  const FilePathBreadcrumb({super.key, required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final muted = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor);
    return Semantics(
      label: AppLocalizations.of(context).readerFilePath(path),
      child: Text(
        path,
        style: muted,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.clip,
      ),
    );
  }
}
