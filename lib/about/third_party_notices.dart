import 'package:flutter/foundation.dart';

import '../engram/crdt/bounded_myers_diff.dart';

/// Registers the notices for third-party code that lives in this repository
/// — as opposed to code pulled in as a package, whose notices the build
/// collects on its own — so the About screen's licenses page shows them.
///
/// One entry today: the MIT-licensed Myers diff ported from `crdt_lf` into
/// `bounded_myers_diff.dart`. Anything else copied in rather than depended
/// on belongs here too; the header of the file that carries it says what was
/// taken and what was changed, and this is what makes the notice reach a
/// built app, which ships no source headers.
///
/// The registry appends, so this is called exactly once, from `main`.
void registerThirdPartyNotices() {
  LicenseRegistry.addLicense(
    () => Stream<LicenseEntry>.value(
      const LicenseEntryWithLineBreaks([
        'crdt_lf (Myers diff, ported into bounded_myers_diff.dart)',
      ], crdtLfLicense),
    ),
  );
}
