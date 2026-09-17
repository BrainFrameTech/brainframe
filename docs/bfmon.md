# bfmon — the store monitor

`bin/bfmon.dart` is a read-only window onto BrainFrame's device-local stores:
what the catalog says about each note, what each scan did, and every
operation in the op-log shown as the text it inserted or deleted. It exists
because two BrainFrame windows over one folder look exactly like an editor
with a file watcher — the CRDT layer's work is invisible from the windows,
and this is the third window that narrates it.

It is developer tooling, not part of the app: plain Dart, no Flutter, and it
never writes. Every database is opened read-only, so it is safe to point at
the stores of instances that are running.

## Running it

From the repo root:

```bash
dart run bin/bfmon.dart watch /tmp/deviceA /tmp/deviceB
dart run bin/bfmon.dart notes /tmp/deviceA
dart run bin/bfmon.dart log   /tmp/deviceA index.md
```

A store argument is any of: a `metadata.db`; the directory holding one; or an
app-data home — the `XDG_DATA_HOME` an instance was launched with — under
which `<app id>/engrams/<engram ULID>/metadata.db` is found. If a home holds
several engrams, pass `--engram <ulid>`. Stores are labelled `A`, `B`, `C`…
in the order given, and a peer ID that belongs to one of them is shown as its
label wherever it appears — as the author of a change, or the seeder of a
note.

For a standalone build (the Pi, or a machine without the SDK):

```bash
dart build cli -t bin/bfmon.dart -o build/bfmon
build/bfmon/bundle/bin/bfmon watch …
```

`dart compile exe` does not work here: `sqlite3` builds and bundles SQLite
through a build hook, and only `dart build` runs hooks. The bundle carries
`libsqlite3.so` beside the binary, so nothing has to be installed.

## `watch`

Polls every 250 ms (`--interval`) and prints one line per event, oldest
first, stamped with the time and the store's label:

```text
22:33:56.032  A  index.md  minted 01M2PK…5ZE7  live  seed A
22:33:56.033  A  index.md  +change A@22:33:55.788  +"from A\n" @seed
22:33:56.033  ·  map  peer A appeared  1 rows
22:33:57.032  B  scan #1 (manual): adopted index.md
22:33:57.032  B  index.md  adopted 01M2PK…5ZE7  historyPending  seed A
22:33:58.032  B  index.md  observed ba0d16bd53fb
22:33:59.032  A  scan #1 (manual): reconciled index.md
22:33:59.032  A  index.md  materialized ba0d16bd53fb
22:33:59.033  A  index.md  +change A@22:33:58.793  +"from B\n" @L2
```

What the lines mean:

- **scan #n (trigger): …** — a recorded scan and what it did, from
  `bf_scan_event`, grouped by kind. A clean scan has no row; it shows as
  `scan: clean` from its timestamp in `bf_meta`.
- **path  minted / adopted / recorded ulid  state  seed X** — a catalog row
  appeared. *Minted* means this device seeded the note; *adopted* means it
  took the ULID from another device's identity map and holds no history for
  it (`historyPending`).
- **path  state → state** — a row changed state: a history-pending note
  promoted, a note tombstoned, a note found over the ceiling.
- **old → new  moved** — a row changed path.
- **path  materialized hash** — this device wrote the file from its
  document; **observed hash** — a history-pending note's file changed
  underneath, and this device noted what it now holds (it cannot reconcile
  it). Both sides showing one hash is convergence, seen.
- **path  +change P@time  delta** — one operation landed in the op-log,
  authored by peer `P` at the HLC's wall time, replayed and described as the
  text it inserted (`+"…"`) or deleted (`-"…"`) and the line it starts on.
  `@seed` is the first insertion of a whole note. A change whose
  dependencies have not arrived is reported as *not applied*.
- **·  map  …** — the engram's shared identity map, `.brainframe/shared/`:
  a peer's file appearing, a claim, a rename, a deletion.

How it works: SQLite has no cross-process change notification, so each tick
reads `PRAGMA data_version` per store — which moves only when another
connection committed — and re-queries only stores that moved, diffing a
handful of small tables against the last snapshot. The app's journal mode is
`delete`, so a read that lands mid-commit waits briefly (`busy_timeout`)
rather than failing. What is already in a store when `watch` starts is
history and is not printed; `log` is for that.

## `log`

One note's op-log, replayed change by change in HLC order — a valid causal
order, since a change's dependencies always carry earlier clocks — with the
same delta phrasing as `watch`, then the value the log adds up to. A
history-pending note says so instead: it has no log on this device, by
design, until one arrives over sync.

## `notes`

The catalog as a table: state, change count, seed, ULID, path — the quickest
way to see which notes this device holds a history for and which it merely
knows the identity of.

## Reading a two-device session

With two instances over one folder (manual test plan F36), the story
`watch` tells is the one the design calls *identity is shared, history is
not*: a note minted on A is adopted on B with A's ULID and zero changes; an
edit made on B reaches A's op-log as a change *authored by A* — the diff the
scan computed, attributed to the device that ingested it — and B's row only
ever records the hash it observed. A note carrying history on both devices
needs operations to travel, which is #67's transport; a `deliver` command
that moves them by hand is the planned next step of this tool.
