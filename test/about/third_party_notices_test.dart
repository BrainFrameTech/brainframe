import 'package:brainframe/about/third_party_notices.dart';
import 'package:brainframe/engram/crdt/bounded_myers_diff.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('registers the crdt_lf notice for the ported Myers diff', () async {
    registerThirdPartyNotices();

    final entries = await LicenseRegistry.licenses.toList();
    final ported = entries.where(
      (e) => e.packages.any((p) => p.startsWith('crdt_lf')),
    );
    expect(ported, hasLength(1));
    final text = ported.single.paragraphs.map((p) => p.text).join('\n');
    expect(text, contains('Copyright (c) 2025 Mattia'));
    expect(text, contains('MIT License'));
    // The notice shipped is the one the source header carries, verbatim.
    for (final line in crdtLfLicense.split('\n').where((l) => l.isNotEmpty)) {
      expect(text, contains(line.trim()));
    }
  });
}
