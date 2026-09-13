import 'dart:convert';

import 'package:brainframe/engram/crdt/catalog.dart';
import 'package:brainframe/engram/id.dart';
import 'package:brainframe/engram/metadata.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final sampleId = newUlid(timestamp: DateTime.utc(2026, 6, 29), random: null);

  EngramMetadata sample() => EngramMetadata(
        schemaVersion: EngramMetadata.currentSchemaVersion,
        id: sampleId,
        displayName: 'Personal',
        createdUtc: DateTime.utc(2026, 6, 29, 12),
      );

  group('EngramMetadata.create', () {
    test('stamps the current schema version and normalizes time to UTC', () {
      final local = DateTime(2026, 6, 29, 12); // local time
      final meta = EngramMetadata.create(
        id: sampleId,
        displayName: 'Personal',
        createdUtc: local,
      );
      expect(meta.schemaVersion, EngramMetadata.currentSchemaVersion);
      expect(meta.createdUtc.isUtc, isTrue);
      expect(meta.createdUtc, local.toUtc());
    });

    test('defaults createdUtc to now in UTC', () {
      final before = DateTime.now().toUtc();
      final meta = EngramMetadata.create(id: sampleId, displayName: 'X');
      final after = DateTime.now().toUtc();
      expect(meta.createdUtc.isUtc, isTrue);
      expect(
        meta.createdUtc.isBefore(before.subtract(const Duration(seconds: 1))),
        isFalse,
      );
      expect(
        meta.createdUtc.isAfter(after.add(const Duration(seconds: 1))),
        isFalse,
      );
    });
  });

  group('round-trip', () {
    test('encode then decode reproduces the value', () {
      final meta = sample();
      expect(EngramMetadata.decode(meta.encode()), meta);
    });

    test('toJson then fromJson reproduces the value', () {
      final meta = sample();
      expect(EngramMetadata.fromJson(meta.toJson()), meta);
    });

    test('encode is pretty-printed and newline-terminated', () {
      final text = sample().encode();
      expect(text.endsWith('\n'), isTrue);
      expect(text.contains('\n  "id"'), isTrue); // two-space indent
      final asMap = jsonDecode(text) as Map<String, dynamic>;
      expect(asMap['schemaVersion'], 1);
      expect(asMap['displayName'], 'Personal');
      expect(asMap['createdUtc'], '2026-06-29T12:00:00.000Z');
    });
  });

  group('schema-version handling', () {
    test('rejects a missing schemaVersion', () {
      final json = sample().toJson()..remove('schemaVersion');
      expect(
        () => EngramMetadata.fromJson(json),
        throwsA(isA<EngramMetadataException>()),
      );
    });

    test('rejects a non-integer schemaVersion', () {
      final json = sample().toJson()..['schemaVersion'] = '1';
      expect(
        () => EngramMetadata.fromJson(json),
        throwsA(isA<EngramMetadataException>()),
      );
    });

    test('rejects a schemaVersion below 1', () {
      final json = sample().toJson()..['schemaVersion'] = 0;
      expect(
        () => EngramMetadata.fromJson(json),
        throwsA(isA<EngramMetadataException>()),
      );
    });

    test('rejects a future schemaVersion this build cannot read', () {
      final json = sample().toJson()
        ..['schemaVersion'] = EngramMetadata.currentSchemaVersion + 1;
      expect(
        () => EngramMetadata.fromJson(json),
        throwsA(
          isA<EngramMetadataException>().having(
            (e) => e.message,
            'message',
            contains('unsupported schemaVersion'),
          ),
        ),
      );
    });
  });

  group('field validation', () {
    test('rejects an id that is not a canonical ULID', () {
      final json = sample().toJson()..['id'] = 'not-a-ulid';
      expect(
        () => EngramMetadata.fromJson(json),
        throwsA(isA<EngramMetadataException>()),
      );
    });

    test('rejects a non-string id', () {
      final json = sample().toJson()..['id'] = 42;
      expect(
        () => EngramMetadata.fromJson(json),
        throwsA(isA<EngramMetadataException>()),
      );
    });

    test('rejects a missing or empty displayName', () {
      final missing = sample().toJson()..remove('displayName');
      final empty = sample().toJson()..['displayName'] = '';
      expect(
        () => EngramMetadata.fromJson(missing),
        throwsA(isA<EngramMetadataException>()),
      );
      expect(
        () => EngramMetadata.fromJson(empty),
        throwsA(isA<EngramMetadataException>()),
      );
    });

    test('rejects a non-string createdUtc', () {
      final json = sample().toJson()..['createdUtc'] = 0;
      expect(
        () => EngramMetadata.fromJson(json),
        throwsA(isA<EngramMetadataException>()),
      );
    });

    test('rejects an unparseable createdUtc', () {
      final json = sample().toJson()..['createdUtc'] = 'not-a-date';
      expect(
        () => EngramMetadata.fromJson(json),
        throwsA(isA<EngramMetadataException>()),
      );
    });
  });

  group('decode', () {
    test('rejects text that is not JSON', () {
      expect(
        () => EngramMetadata.decode('{not json'),
        throwsA(isA<EngramMetadataException>()),
      );
    });

    test('rejects JSON that is not an object', () {
      expect(
        () => EngramMetadata.decode('[1, 2, 3]'),
        throwsA(isA<EngramMetadataException>()),
      );
    });
  });

  group('value semantics', () {
    test('equal metadata are equal and share a hashCode', () {
      expect(sample(), sample());
      expect(sample().hashCode, sample().hashCode);
    });

    test('differing fields are unequal', () {
      final other = EngramMetadata(
        schemaVersion: sample().schemaVersion,
        id: sampleId,
        displayName: 'Different',
        createdUtc: sample().createdUtc,
      );
      expect(sample(), isNot(other));
    });

    test('toString and exception toString include useful context', () {
      expect(sample().toString(), contains('Personal'));
      expect(
        const EngramMetadataException('boom').toString(),
        'EngramMetadataException: boom',
      );
    });
  });

  group('withDisplayName', () {
    final original = EngramMetadata(
      schemaVersion: 1,
      id: '01JAB2CD3EFGHJKMNPQRSTVWXY',
      displayName: 'zettel',
      createdUtc: DateTime.utc(2026, 5, 1, 9),
    );

    test('changes only the display name', () {
      final renamed = original.withDisplayName('Field Notebook');

      expect(renamed.displayName, 'Field Notebook');
      expect(renamed.id, original.id);
      expect(renamed.createdUtc, original.createdUtc);
      expect(renamed.schemaVersion, original.schemaVersion);
    });

    test('trims surrounding whitespace', () {
      expect(original.withDisplayName('  Notes  ').displayName, 'Notes');
    });

    test('rejects a blank name, which would not parse back', () {
      expect(() => original.withDisplayName(''), throwsArgumentError);
      expect(() => original.withDisplayName('   '), throwsArgumentError);
    });

    test('keeps a marker at its stored schema version rather than upgrading',
        () {
      // Written by a hypothetical older build; renaming must not restamp it.
      final v1 = EngramMetadata(
        schemaVersion: 1,
        id: original.id,
        displayName: 'old',
        createdUtc: original.createdUtc,
      );
      expect(v1.withDisplayName('new').schemaVersion, 1);
    });

    test('round-trips through encode/decode', () {
      final renamed = original.withDisplayName('Field Notebook');
      expect(EngramMetadata.decode(renamed.encode()), renamed);
    });
  });

  group('the note size ceiling (design Decision 7)', () {
    // The fixture engram's marker, as every engram created before the field
    // existed looks: no ceiling recorded.
    final legacy = EngramMetadata(
      schemaVersion: 1,
      id: '01JAB2CD3EFGHJKMNPQRSTVWXY',
      displayName: 'Field Notebook',
      createdUtc: DateTime.utc(2026, 5, 1, 9),
    );

    test('absent means 128 KiB, and stays absent', () {
      final json = legacy.toJson();
      expect(json.containsKey('noteSizeCeilingBytes'), isFalse);

      final parsed = EngramMetadata.fromJson(json);
      expect(parsed.recordedNoteSizeCeilingBytes, isNull);
      expect(parsed.noteSizeCeilingBytes, 131072);
      expect(parsed.noteSizeCeilingBytes, defaultNoteSizeCeilingBytes);
      // Encoding it back does not invent the field: opening never writes it.
      expect(parsed.toJson().containsKey('noteSizeCeilingBytes'), isFalse);
      expect(parsed.toString(), contains('(default)'));
    });

    test('the default is a literal, not the capability', () {
      // Both 128 KiB today. If the capability ever rises, engrams with no
      // recorded value must keep the number that was implicitly true of
      // them, so the two are pinned separately.
      expect(defaultNoteSizeCeilingBytes, 131072);
    });

    test('a new engram records the creating build\'s capability', () {
      final created = EngramMetadata.create(id: sampleId, displayName: 'X');
      expect(created.recordedNoteSizeCeilingBytes, noteSizeCapabilityBytes);
      expect(created.toJson()['noteSizeCeilingBytes'], noteSizeCapabilityBytes);
      expect(EngramMetadata.decode(created.encode()), created);
    });

    test('a recorded ceiling below the capability is enforced as recorded', () {
      final json = legacy.toJson()..['noteSizeCeilingBytes'] = 64 * 1024;
      final parsed = EngramMetadata.fromJson(json);
      expect(parsed.noteSizeCeilingBytes, 65536);
      expect(parsed.recordedNoteSizeCeilingBytes, 65536);
      expect(parsed.toJson()['noteSizeCeilingBytes'], 65536);
    });

    test('a ceiling above the capability is refused, naming the fix', () {
      // The engram was raised by a newer build. This build cannot hold a note
      // the engram allows, so it must not open it and treat such notes
      // differently from its peers — the same refusal as a newer schema.
      final json = legacy.toJson()
        ..['noteSizeCeilingBytes'] = noteSizeCapabilityBytes + 1;
      expect(
        () => EngramMetadata.fromJson(json),
        throwsA(
          isA<EngramMetadataException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('${noteSizeCapabilityBytes + 1} bytes'),
              contains('update BrainFrame'),
            ),
          ),
        ),
      );
    });

    test('exactly the capability is allowed', () {
      final json = legacy.toJson()
        ..['noteSizeCeilingBytes'] = noteSizeCapabilityBytes;
      expect(
        EngramMetadata.fromJson(json).noteSizeCeilingBytes,
        noteSizeCapabilityBytes,
      );
    });

    test('a malformed ceiling is refused', () {
      for (final bad in [0, -1, '131072', 1.5, true]) {
        final json = legacy.toJson()..['noteSizeCeilingBytes'] = bad;
        expect(
          () => EngramMetadata.fromJson(json),
          throwsA(isA<EngramMetadataException>()),
          reason: '$bad',
        );
      }
    });

    test('a rename keeps the ceiling exactly as it was, recorded or not', () {
      expect(
        legacy.withDisplayName('Renamed').recordedNoteSizeCeilingBytes,
        isNull,
      );
      final recorded = legacy.withNoteSizeCeilingBytes(65536);
      expect(
        recorded.withDisplayName('Renamed').recordedNoteSizeCeilingBytes,
        65536,
      );
    });

    test('withNoteSizeCeilingBytes records the value, within bounds', () {
      final changed = legacy.withNoteSizeCeilingBytes(65536);
      expect(changed.noteSizeCeilingBytes, 65536);
      expect(changed.id, legacy.id);
      expect(changed.displayName, legacy.displayName);
      expect(changed.schemaVersion, legacy.schemaVersion);
      expect(EngramMetadata.decode(changed.encode()), changed);

      expect(() => legacy.withNoteSizeCeilingBytes(0), throwsArgumentError);
      expect(
        () => legacy.withNoteSizeCeilingBytes(noteSizeCapabilityBytes + 1),
        throwsArgumentError,
        reason: 'never raised past what the raising device can open',
      );
    });

    test('the ceiling takes part in equality', () {
      expect(legacy.withNoteSizeCeilingBytes(65536), isNot(legacy));
      expect(
        legacy.withNoteSizeCeilingBytes(65536),
        legacy.withNoteSizeCeilingBytes(65536),
      );
      expect(
        legacy.withNoteSizeCeilingBytes(65536).hashCode,
        legacy.withNoteSizeCeilingBytes(65536).hashCode,
      );
    });
  });
}
