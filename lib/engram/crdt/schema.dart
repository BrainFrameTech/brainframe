/// The naming rule every BrainFrame-owned SQLite table follows.
///
/// **Every table BrainFrame creates is prefixed `bf_`.** No exceptions, in any
/// database, now or later.
///
/// SQLite has no schemas or namespaces — one file is one flat table
/// namespace — and BrainFrame's databases are deliberately shared. The op-log
/// lives in the same file as our own tables (that is the point of
/// `CRDTSqlite.fromDatabase`: one connection, one transaction boundary), and
/// `crdt_lf_sqlite` claims the names **`changes`** and **`snapshots`**. Those
/// are exactly the names an unprefixed BrainFrame schema would reach for.
///
/// The collision would not be a clean failure, either. The library's DDL is
/// `CREATE TABLE IF NOT EXISTS` and runs on every open, so a table of ours
/// that already occupied one of those names would silently *not* be created by
/// it, and the op-log would then read and write our columns. A prefix makes
/// that structurally impossible rather than merely unlikely.
///
/// Two further reasons it stays a blanket rule rather than a case-by-case one:
///
/// - **The upstream namespace is not ours to predict.** `crdt_lf_sqlite` may
///   add tables in any release, with names chosen without reference to us.
///   Auditing our schema against theirs on every upgrade is work; a prefix is
///   not.
/// - **It makes `sqlite_master` self-describing.** `select name from
///   sqlite_master where type='table'` separates ours from the library's at a
///   glance, which matters because recovery from a corrupt store starts with a
///   plain SQLite browser and no application code.
///
/// Pinned by
/// [metadata_db_io_test.dart](../../../test/engram/crdt/metadata_db_io_test.dart),
/// which asserts that every table in an open store is either the library's or
/// `bf_`-prefixed — so a future unprefixed table fails there rather than in a
/// user's engram.
library;

/// The prefix on every table BrainFrame creates.
const String brainframeTablePrefix = 'bf_';

/// Tables created by `crdt_lf_sqlite`, which BrainFrame does not name and must
/// not collide with.
///
/// Listed so the convention can be *tested* rather than merely stated: any
/// table that is neither one of these nor `bf_`-prefixed is a violation.
const Set<String> crdtTableNames = {'changes', 'snapshots'};

/// Whether [tableName] respects the naming rule — either a table BrainFrame
/// named, or one of the library's.
bool isPermittedTableName(String tableName) =>
    tableName.startsWith(brainframeTablePrefix) ||
    crdtTableNames.contains(tableName);
