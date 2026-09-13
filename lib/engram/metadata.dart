/// The parsed contents of an engram's `.brainframe/engram.json`.
///
/// This is the on-disk identity of a filesystem engram: a schema version, the
/// stable [id], a [displayName], a creation timestamp, and — since the note
/// size ceiling design — the size limit every device enforces for its text
/// notes. Parsing is strict: a malformed or future-versioned file, or one
/// whose ceiling this build cannot honour, raises [EngramMetadataException]
/// rather than silently producing a half-valid engram.
library;

import 'dart:convert';

import 'crdt/catalog.dart';
import 'id.dart';

/// The ceiling an engram has when its `engram.json` records none: 128 KiB.
///
/// Every engram created before the field existed has this ceiling, because
/// it is the number that was implicitly true of them — and a literal, not
/// [noteSizeCapabilityBytes], because the capability may rise with a later
/// build while what those engrams enforce must not move underneath them. It
/// is written into a file only by an explicit change (the note size ceiling
/// design, Decision 7); opening an engram never adds it.
const int defaultNoteSizeCeilingBytes = 128 * 1024;

/// Thrown when `engram.json` cannot be parsed into a valid [EngramMetadata].
class EngramMetadataException implements Exception {
  const EngramMetadataException(this.message);

  final String message;

  @override
  String toString() => 'EngramMetadataException: $message';
}

/// Metadata for a single engram, serialized to and from `engram.json`.
class EngramMetadata {
  const EngramMetadata({
    required this.schemaVersion,
    required this.id,
    required this.displayName,
    required this.createdUtc,
    this.recordedNoteSizeCeilingBytes,
  });

  /// Builds metadata for a freshly created engram, stamping the current schema
  /// version, normalizing [createdUtc] (defaulting to now) to UTC, and
  /// recording this build's note size capability as the engram's ceiling —
  /// a new engram starts at the largest note the build that made it can
  /// hold, and says so in the file.
  factory EngramMetadata.create({
    required String id,
    required String displayName,
    DateTime? createdUtc,
  }) =>
      EngramMetadata(
        schemaVersion: currentSchemaVersion,
        id: id,
        displayName: displayName,
        createdUtc: (createdUtc ?? DateTime.now()).toUtc(),
        recordedNoteSizeCeilingBytes: noteSizeCapabilityBytes,
      );

  /// Parses [source], the raw text of an `engram.json` file.
  ///
  /// Throws [EngramMetadataException] if the text is not a JSON object or any
  /// field is missing, mistyped, or unsupported.
  factory EngramMetadata.decode(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (e) {
      throw EngramMetadataException('engram.json is not valid JSON: ${e.message}');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const EngramMetadataException('engram.json must be a JSON object');
    }
    return EngramMetadata.fromJson(decoded);
  }

  /// Builds metadata from an already-decoded JSON [json] map, validating every
  /// field. Throws [EngramMetadataException] on any problem.
  factory EngramMetadata.fromJson(Map<String, dynamic> json) {
    final version = json['schemaVersion'];
    if (version is! int) {
      throw const EngramMetadataException(
        'schemaVersion is required and must be an integer',
      );
    }
    if (version < 1 || version > currentSchemaVersion) {
      throw EngramMetadataException(
        'unsupported schemaVersion $version '
        '(this build understands 1..$currentSchemaVersion)',
      );
    }

    final id = json['id'];
    if (id is! String || !isCanonicalUlid(id)) {
      throw const EngramMetadataException('id must be a canonical ULID string');
    }

    final displayName = json['displayName'];
    if (displayName is! String || displayName.isEmpty) {
      throw const EngramMetadataException(
        'displayName is required and must be a non-empty string',
      );
    }

    final createdRaw = json['createdUtc'];
    if (createdRaw is! String) {
      throw const EngramMetadataException(
        'createdUtc is required and must be an ISO-8601 string',
      );
    }
    final DateTime createdUtc;
    try {
      createdUtc = DateTime.parse(createdRaw).toUtc();
    } on FormatException {
      throw EngramMetadataException(
        'createdUtc is not a valid ISO-8601 timestamp: $createdRaw',
      );
    }

    // Optional: absent means the default, and that absence is preserved so
    // encoding does not invent the field. Present, it must be a size this
    // build can honour — the ceiling is what every device enforces, and a
    // device that cannot hold a note the engram allows must not open the
    // engram and quietly treat such notes differently from its peers. The
    // refusal is the same kind as an unknown schemaVersion: the file is
    // from a newer build, and the fix is to update this one.
    final ceilingRaw = json[_noteSizeCeilingKey];
    if (ceilingRaw != null && (ceilingRaw is! int || ceilingRaw <= 0)) {
      throw const EngramMetadataException(
        '$_noteSizeCeilingKey must be a positive integer when present',
      );
    }
    final ceiling = ceilingRaw as int?;
    if (ceiling != null && ceiling > noteSizeCapabilityBytes) {
      throw EngramMetadataException(
        'this engram allows notes up to $ceiling bytes, more than this '
        'version of BrainFrame can open ($noteSizeCapabilityBytes); update '
        'BrainFrame on this device to open it',
      );
    }

    return EngramMetadata(
      schemaVersion: version,
      id: id,
      displayName: displayName,
      createdUtc: createdUtc,
      recordedNoteSizeCeilingBytes: ceiling,
    );
  }

  /// A copy of this metadata carrying [displayName] instead, leaving the
  /// machine-owned fields ([id], [createdUtc], [schemaVersion]) untouched.
  ///
  /// This is the only field a user edits, so renaming an engram goes through
  /// here rather than rebuilding metadata from scratch — an existing marker
  /// keeps the schema version it was written with rather than being silently
  /// upgraded. Throws [ArgumentError] on a blank name, which the parser would
  /// reject on the way back in.
  EngramMetadata withDisplayName(String displayName) {
    final trimmed = displayName.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(
        displayName,
        'displayName',
        'must not be blank',
      );
    }
    return EngramMetadata(
      schemaVersion: schemaVersion,
      id: id,
      displayName: trimmed,
      createdUtc: createdUtc,
      recordedNoteSizeCeilingBytes: recordedNoteSizeCeilingBytes,
    );
  }

  /// A copy of this metadata recording [bytes] as the note size ceiling.
  ///
  /// The one way the value changes, for the Housekeeping job that does so
  /// deliberately (the note size ceiling design, Decision 7; plan step 23).
  /// Never called on open. Throws [ArgumentError] if [bytes] is not positive
  /// or exceeds this build's capability — an engram is never asked to allow
  /// what the device raising it cannot itself open.
  EngramMetadata withNoteSizeCeilingBytes(int bytes) {
    if (bytes <= 0 || bytes > noteSizeCapabilityBytes) {
      throw ArgumentError.value(
        bytes,
        'bytes',
        'must be between 1 and $noteSizeCapabilityBytes',
      );
    }
    return EngramMetadata(
      schemaVersion: schemaVersion,
      id: id,
      displayName: displayName,
      createdUtc: createdUtc,
      recordedNoteSizeCeilingBytes: bytes,
    );
  }

  /// The schema version this build writes and is the newest it can read.
  static const int currentSchemaVersion = 1;

  static const String _noteSizeCeilingKey = 'noteSizeCeilingBytes';

  final int schemaVersion;
  final String id;
  final String displayName;
  final DateTime createdUtc;

  /// The ceiling as written in the file, or null when the file has none.
  ///
  /// Kept distinct from [noteSizeCeilingBytes] so that encoding a file that
  /// never had the field does not add it: a rename, which rewrites the file,
  /// must not be the moment an old engram starts stating a limit.
  final int? recordedNoteSizeCeilingBytes;

  /// The largest text note this engram allows, in bytes on disk — what every
  /// device opening it enforces. [defaultNoteSizeCeilingBytes] when the file
  /// records none.
  int get noteSizeCeilingBytes =>
      recordedNoteSizeCeilingBytes ?? defaultNoteSizeCeilingBytes;

  /// The JSON object form, with [createdUtc] rendered as a UTC ISO-8601 string
  /// and the ceiling present only when it was recorded.
  Map<String, dynamic> toJson() => {
        'schemaVersion': schemaVersion,
        'id': id,
        'displayName': displayName,
        'createdUtc': createdUtc.toUtc().toIso8601String(),
        if (recordedNoteSizeCeilingBytes != null)
          _noteSizeCeilingKey: recordedNoteSizeCeilingBytes,
      };

  /// Serializes to the pretty-printed, newline-terminated text written to
  /// `engram.json`. `decode(encode())` round-trips.
  String encode() => '${const JsonEncoder.withIndent('  ').convert(toJson())}\n';

  @override
  bool operator ==(Object other) =>
      other is EngramMetadata &&
      other.schemaVersion == schemaVersion &&
      other.id == id &&
      other.displayName == displayName &&
      other.createdUtc == createdUtc &&
      other.recordedNoteSizeCeilingBytes == recordedNoteSizeCeilingBytes;

  @override
  int get hashCode => Object.hash(
        schemaVersion,
        id,
        displayName,
        createdUtc,
        recordedNoteSizeCeilingBytes,
      );

  @override
  String toString() =>
      'EngramMetadata(schemaVersion: $schemaVersion, id: $id, '
      'displayName: $displayName, createdUtc: ${createdUtc.toIso8601String()}, '
      'noteSizeCeilingBytes: $noteSizeCeilingBytes'
      '${recordedNoteSizeCeilingBytes == null ? ' (default)' : ''})';
}
