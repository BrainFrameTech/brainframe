# Device names, and what a scan card says

- **Status:** accepted (2026-09-30) — agreed in conversation and reviewed
  before any code; the choices made in review are under *Settled in review*.
  Not yet built: *What this asks of the implementation* is the plan
- **Author:** Claude
- **Date:** 2026-09-30
- **Companion to:** [note-identity-and-crdt.md](note-identity-and-crdt.md),
  whose Decision 9 identity map this adds a table to, and
  [filesystem-watcher.md](filesystem-watcher.md), whose Decision 10 cards
  this fills in

## TL;DR

Housekeeping's Recent scans says *that* something happened — "1 retired" —
and nothing about what, where, why, or which devices were involved. This
document adds two things:

1. **Every device has a name, per engram.** It is this engram's name for the
   device if one is set, else the device's default name, else what the
   platform offers (a hostname; a phone's own name) — set in Settings ›
   Engram, the way theme has a default and a per-engram override.
   It is published to the other devices through each device's identity-map
   file, so a card can say "jdoe's Pixel" instead of `5c1e09a2…`.
2. **Every card has details, behind a "Details" toggle.** The paths
   involved, the devices involved where they can be known, a plain sentence
   saying why for anything unusual, what it cost, moves as from → to, exact
   times, and how many changes a folded card holds. The facts are captured
   when the event is recorded, not looked up when the card is shown.

A change found on disk is attributed to this device as the one that **took
it in** — never as the one it was **made on**, which this device cannot know.

## Why now

Take two devices sharing an engram folder through a file-sync tool. A new
note is created on one; the sync tool copies it to the other, whose watcher
sees it before the first device's identity-map row has arrived, and so mints
an identity of its own. When the row arrives, the map holds two live
identities for one path, and Decision 9's second rule elects one — the
lowest ULID, so the earliest mint. The later device retires its own.

That is the design working as intended, and the card it leaves reads
"1 retired". Everything needed to explain it is already on the device:

- the scan history knows which path's identity was retired, and when;
- the two identity-map files know which device minted each identity, and
  when — say 11:54:22 on the other device and 11:54:33 here, eleven seconds
  later;
- the op-log knows what the losing identity held — typically one change,
  its seed, so nothing was lost.

Today all of that has to be read out of three SQLite files by hand. The app
shows none of it, so the user cannot tell an expected election from a fault.

## Decisions

### Decision 1 — a device has a name, per engram

**Per engram, not per device.** The same machine may present as "work
laptop" to one engram and something else to another, and that is wanted:
the name is how the *other devices of that engram* recognize it, and those
devices are different people's, or different contexts', from one engram to
the next. It also means the name is chosen where the engram is, which suits
the e-ink device, where nothing else would set it.

**A device-wide default, and a per-engram override — the theme's model.**
The name an engram's other devices see is the first of:

1. **this engram's name for the device**, if one is set — the override;
2. **the device's default name**, if one is set — one name for every engram
   that has no override, such as "jdoe's brainframe e-ink" for a device whose
   hostname is only `brainframe`;
3. **the platform's name** for the device (the table below).

An engram with no override follows the default: change the default, and
every such engram presents the new name. That is how theme already works —
a device default, and a per-engram override that wins when set — and the
two settings sit together the same way. Both are trimmed and at most 64
characters, and clearing either one falls back to the next in the list.

**Set in Settings › Engram**, under a "This device" heading: "Default name
(every engram)" and "Name in this engram", the second offering "use the
default" as its unset state, as the theme's "This engram" offers "Default".

**The platform's name** — the last fallback:

| Platform | Source | Example |
| --- | --- | --- |
| Linux, Raspberry Pi | `Platform.localHostname` | `jdoe-desktop` |
| macOS | `Platform.localHostname`, with a trailing `.local` removed | `jdoes-MacBook-Pro` |
| Windows | `Platform.localHostname` | `JDOE-PC` |
| Android | `Settings.Global.DEVICE_NAME` (API 25+, no permission), else `Build.MODEL`, over a small platform channel | `jdoe's Pixel` |
| iOS | `UIDevice.current.model` | `iPhone` |

**iOS cannot supply the user's own name for the device.** Since iOS 16,
`UIDevice.name` returns the generic model unless the app holds an
entitlement Apple grants case by case. The model is the honest default
there, and the setting is how an iPhone gets a real name.

**The name is visible to everyone who has the folder.** It is written into
`.brainframe/shared/`, which travels wherever the engram is synced, shared, or
published. A hostname can carry a person's name. The default is what the
platform already uses on the network; the setting is one tap away, and its
help text says where the name goes.

### Decision 2 — where the name lives, and how others see it

**Not in `.brainframe/settings.json`.** That file is inside the engram
folder and is synced with it; a name stored there would arrive on every
other device, which would take it as its own.

**The per-engram override is kept in the engram's local `metadata.db`** (a
`bf_meta` key, `device_name`), which never leaves the machine — beside the
peer ID it names. This is where it differs from the theme: a theme override
is meant to travel with the folder, and lives in the engram tier, in
`.brainframe/settings.json`; a device's name for an engram must not, for the
reason above.

**The device-wide default is a device-tier setting** (`shared_preferences`),
like the default theme: one machine, one value, never in any engram.

**What is published is the resolved name** — override, else default, else
platform — so another device never needs to know which of the three it
was. It is resolved when the engram opens and again when either setting
changes. A changed default reaches an engram without an override the next
time that engram is open; an engram not opened in a while still presents the
name it last published, which is correct for what it last did.

**It is published in this device's identity-map file**, in a new table:

```sql
CREATE TABLE IF NOT EXISTS bf_peer (
  peer     TEXT PRIMARY KEY,
  name     TEXT NOT NULL,
  platform TEXT NOT NULL,   -- linux, macos, windows, android, ios
  hlc      TEXT NOT NULL    -- when the name was last set
);
```

- **One row, about the file's own writer.** A device writes only its own map
  file, so no two devices ever write the same row, and no merge rule is
  needed. A reader takes from each file only the row whose `peer` is that
  file's own; anything else is ignored.
- **Older builds are unaffected.** They read `bf_identity_map` and nothing
  else, so the new table is invisible to them. Their devices simply have no
  name, and are shown by a short form of their peer ID: "device `5c1e09a2`".
- **A rename is published on the map writer's next write**, which a rename
  asks for, debounced like any other change to the map.

**Names are resolved when a card is shown, not stored with the event.** The
event records peer IDs (Decision 4); the card looks each one up. A device
renamed later is shown by its new name on old cards too, which is the point
of naming it: the name is for recognizing the device now. This device is
always shown as its name followed by "(this device)".

**The ledger names them too.** "2 devices have written to this engram,
including this one" gains the names: "… — jdoe-desktop (this device) and
jdoe's Pixel." Past five names, the rest are "and *N* more", as a card's
paths are.

### Decision 3 — a change found on disk was taken in here, not made here

A note's file can change on disk because of an editor on this machine, or
because a sync tool brought another device's save. From inside BrainFrame the
two are the same event: a file changed. The operations that fold it into the
history carry this device's peer ID (the note-identity design's Decision 6),
and this device is the one that noticed — so the change **is** this peer's,
and the card says so. It does not say the change was *made* here.

> Updated from disk · taken in by jdoe-desktop (this device)

never "edited on jdoe-desktop". With a phone and a desktop sharing a folder
through a sync tool, an edit typed on the phone is saved by BrainFrame
there, copied over by the sync tool, and taken in by the desktop's watcher;
"edited on this device" would be false on the desktop's card.

This holds for every change found on disk — updated, created, moved, deleted
— until sync (#67) carries real authorship, at which point an edit that
arrives *through BrainFrame* can name its author. Only identity events name
another device today, because only they carry one (Decision 4).

### Decision 4 — the facts are captured when the event is recorded

A card read next month must say what was true when it happened. The identity
map does not hold still — rows are renamed, deleted, re-elected, and devices
come and go — so the facts a card needs are recorded with the event, in a new
column on the device-local scan history:

```sql
ALTER TABLE bf_scan_event ADD COLUMN detail TEXT;  -- JSON object, or null
```

Added on open when missing, as the scan tables themselves are, so an existing
database gains it with no schema-version change. Old rows have none.

What each kind records:

| Kind | `detail` holds | Why |
| --- | --- | --- |
| updated (reconciled) | — | the path is the fact; attribution is this device's |
| created | — | minted here, from the file |
| adopted | the peer that minted the identity, and when | "adopted the identity jdoe's Pixel made at 11:54:22" |
| moved | how it matched: `identical` (same content hash) or `similar` (sketch), with the similarity when it was a sketch | an identical move and a rename-with-edit are different news |
| deleted (tombstoned) | — | the lost-history pairing is already said |
| retired | the winning ULID, the winner's peer and mint time, the loser's mint time, and how many changes the loser held | the whole story from *Why now*, in one line |
| converted elsewhere | the converting peer (the count already rides in `error`) | who made the note a plain file |
| oversized, awaiting a decision | the file's size, and the ceiling it was over | the user is asked to act on it |
| converted | how many changes were dropped | what consenting cost |
| reconstructed | — (the kept path is in `new_path`) | |
| failed | — (the error is in `error`) | |

The event's existing columns — `path`, `new_path`, `ulid`, `error` — are
unchanged and keep their meaning; `detail` adds to them. The count a
converted-elsewhere event keeps in `error` stays there, so old rows read
the same.

**Bounded.** A detail is a few fields per event, tens of bytes. No kind
records a list.

### Decision 5 — the card's Details

**Closed by default**, behind a "Details" toggle below the summary. The card
as it is today stays the card; the details are there when wanted. It opens
without animation when the platform asks for reduced motion, and always on
e-ink. The toggle exposes `Semantics` with its expanded state, and its label
names the card's time.

**Inside, grouped by kind in the summary's order:**

- **The paths.** Up to five per kind, then "and *N* more". Each path a note
  can be opened at — updated, created, adopted, moved (its new path), and
  the ceiling's kinds as today — has an Open button; a deleted note, or a
  retired identity's, has none.
- **Moves as from → to**, with "identical" or "similar (*N*%)".
- **A sentence saying why**, for each kind that is not self-explanatory:
  retired, adopted, converted elsewhere, oversized, awaiting a decision, and
  a lost history. For the case in *Why now*:

  > `notes/plans.md` — jdoe's Pixel made this note's identity
  > first (11:54:22, 11 seconds earlier), so this device's was retired.
  > Nothing was lost: it held only its first snapshot, and the file is
  > unchanged.

- **What it cost**, where something was: changes held by a retired identity,
  dropped by a conversion, or unreachable after one elsewhere; "nothing was
  lost" when the count is the seed alone.
- **The devices involved** (Decision 2's names): "taken in by …" for changes
  found on disk (Decision 3), and the other device by name for identity
  events.
- **Exact times**, to the second, where the header shows minutes: when the
  scan ran, or for a folded card, its first and last change and how many
  changes it holds — "13 changes, 5:16:18 PM–5:24:39 PM".

**Old records show what they have**: their paths, without the `detail`-born
facts.

All of these are taken on trial. They are built together and pruned after
they have been seen on real cards, if they prove cluttered.

## What this asks of the implementation

1. **The device name** (Decisions 1–2) — the platform defaults, the Android
   and iOS channels, the device-tier default, the per-engram `device_name`
   key, the resolution order between them, the `bf_peer` table written with
   the map and read with it, and both fields in Settings › Engram. Tests:
   the platform name per platform (by injection), the resolution order, a
   changed default reaching an engram without an override and not one with,
   a rename reaching the map file, a reader ignoring a row about another
   peer, a file with no `bf_peer` table.
2. **The event detail** (Decision 4) — the column, added on open; each kind
   recording its fields at the point the scan or reconcile already knows
   them. Tests: each kind's detail round-trips; an old row reads as before.
3. **The card's Details** (Decision 5) — the toggle, the sections, the
   sentences, the names resolved at display, the ledger's device list.
   Tests: each kind's lines, the five-path cap, a folded card's count and
   span, an unnamed device's short ID, reduced motion, and `Semantics`.

Each lands as its own PR, in that order: the second and third need the
first's names, and the third needs the second's facts.

## The manual test plan

- **F21** gains the Details toggle — closed by default, every kind's lines,
  the five-path cap — and the ledger's device names.
- **F26** (Settings › Engram) gains the device name: the platform's name on
  each platform; a default name followed by an engram without an override
  and ignored by one with; a per-engram name; clearing each, which falls
  back a step; and the 64-character limit.
- **F36** (two BrainFrames over one folder) gains the names: each instance
  sees the other's by name, and a rename on one appears on the other after
  its next scan.
- A retirement case: two devices mint the same new note before either sees
  the other's map row — reproducible with two instances and `XDG_DATA_HOME`
  (F36), or two devices over a sync tool — and the retired card's Details
  tell the whole story with no database open.

## Settled in review

- **Per engram, not per device** (Decision 1) — the user's call: a device
  presenting differently to different engrams is a feature.
- **A device-wide default under the per-engram name** (Decision 1) — raised
  in review, for a device whose hostname says nothing, such as an e-ink
  reader called `brainframe`. It follows the theme's model: a device
  default, and a per-engram override that wins when set.
- **Settings › Engram** is where both are set, following from that.
- **Details closed by default**, about five paths before "and *N* more".
- **"Taken in by", not "made on"** (Decision 3) — a change on disk is this
  peer's, without claiming where it was typed.
- **Every field in Decision 5**, built together and pruned after use.
- **At most 64 characters** for a name — enough for any hostname and any
  phone's name, short enough to fit a card line.
- **Names resolved at display** (Decision 2): an old card shows a device's
  current name, since the name is for recognizing the device now. Showing
  the name as it was would need it stored with every event.
- **The ledger's device list** is capped like a card's paths: five names,
  then "and *N* more".
