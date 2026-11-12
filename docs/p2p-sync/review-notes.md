# Sync threat model: review notes

The running list of review findings for the [sync threat
model](01-threat-model.md) and the [protocol document](06-brainframe-protocol.md),
kept apart from both so each holds only its own content. It is a working
document, not part of the [sequence](README.md), and is meant to keep the work
on track until the threat model is accepted.

Every entry belongs to one document: its heading says which. Line numbers are
written as `01:123` or `06:123` and are as of 2026-11-12; the quoted text finds
each spot when they drift. An entry is removed once it is addressed.

## Reference: trust models and methods

Two separate lists, kept here for filling in the tables. They answer different
questions: the models say who is trusted and how much, and the methods are the
tools applied to each model.

**Trust models** (who is trusted, and how much). The doc combines these; the
names are the standard ones, not terms it has defined.

- **Trusted endpoint.** Reading and writing peers on a keeper's own hardware.
  Anyone with the keeper's account is out of scope; attacks on BrainFrame
  itself, such as privilege escalation, are in scope. See the first bullet of
  [Who is out of scope?](01-threat-model.md#who-is-out-of-scope).
- **Untrusted server.** Blind peers and the service, at two strengths:
  - *Honest-but-curious* (or semi-honest): follows the protocol, but tries to
    learn what it can. "What about metadata on blind peers?" is written
    against this.
  - *Malicious*: also deletes, delays, or withholds. "What about history
    attacks against blind peers?" is written against this.

  The design goal for this model is usually called end-to-end encryption, or
  "zero-knowledge" storage.
- **Insider, or Byzantine.** A legitimate member that behaves arbitrarily: a
  stolen device, a compromised writing peer, a hostile keeper. Most of
  *Settled in review* is about this model, along with most of what moved to
  the [protocol document](06-brainframe-protocol.md).
- **Network attacker** (arguably a fourth, and still thin in the doc). Described
  in RFC 3552's terms. "What about metadata on a local network?" belongs here.

**Methods** (the tools, listed in the README's "How the threat model is
built").

- **The Four Questions** give the document its structure: *What are we working
  on? What can go wrong? What are we going to do about it? Did we do a good
  enough job?* This document answers the first two.
- **STRIDE** is the checklist for security threats: Spoofing, Tampering,
  Repudiation, Information disclosure, Denial of service, Elevation of
  privilege.
- **LINDDUN** is the checklist for privacy threats: Linking, Identifying,
  Non-repudiation, Detecting, Data disclosure, Unawareness, Non-compliance.
- **RFC 3552's attacker terms** describe what each adversary can do: passive or
  active, on-path or off-path.

**How they meet in the tables.** The models supply the rows of the Adversaries
table. Running STRIDE and LINDDUN against each adversary supplies the Threats
table: for example, the service against Information disclosure and Linking, or
a stolen writing peer against Tampering and Elevation of privilege.

## Threat model (01)

Entries here concern [01-threat-model.md](01-threat-model.md): what can go
wrong, and what must hold. No contradictions were found in the sweep of
2026-11-07.

### Overlapping open questions

- [ ] **E4. Three questions cover forced snapshots.** "How to validate
  snapshots?", "How to deal with a malicious actor forcing snapshots…", and part
  of "A blind peer outside snapshotting keeps history longer". A forged snapshot
  is already refused. What remains is one question: how long history is kept
  before a legitimate snapshot makes a stolen peer's vandalism permanent.

### Before acceptance

- [ ] **F26. Empty sections.** Scope, Data-flow diagram, Assets, Threats, and
  Security goals are still empty, and later documents check against them.
- [ ] **F32. A goal for each section that moved.** Fourteen sections now point
  to the protocol document. Each should leave a one-line security goal (`G`)
  in 01, stated as a property documents 3 and 5 can check a protocol against.
  Examples, one per area:

  | Moved section | Example goal |
  | --- | --- |
  | Read Only Membership: record fields | Every record names its signer, and peers reject unsigned ones |
  | Edit histories: removal records | A removed peer's edits outside its removal set are never applied |
  | Edits must form a DAG | Edits are signed and bound to the edits they build on |
  | Removed peers: edit ID rules | A reused edit ID with new content is never applied |
  | Snapshots require special handling | No history is discarded until every member agrees on the snapshot |
  | Bootstrapping an ensemble | An ensemble has exactly one origin, which a joiner can verify |
  | Joining an ensemble | A peer joins only by invitation, confirmed by both keepers |
  | Decryption keys, Key rotation | A removed peer cannot read anything written after rotation |
  | Long Term Detached Peers | A detached peer cannot grow history unnoticed |
  | File synchronization tools, Backup restoration | Keepers are warned when another tool writes to the engram |
  | Removed peers: quarantine | A removed peer's edits reach the ensemble only through a keeper |

### Housekeeping

- [ ] **F5. Scoping decisions without reasons.** Who shares an engram, Is there
  a server, Is there a service, and Where does sync reach state no reason.
- [ ] **F6.** `01:137`: "in that history" should add "until the next
  snapshot".
- [ ] **F13.** `01:803`: "This specific attack area must be mitigated" could
  link to the two blind-peer metadata and history questions.
- [ ] **F14.** `01:314`: "any writing peer can remove any other peer" is now
  "any writing UI peer".
- [ ] **F15. "Read only" wording.** `01:654` heading, `01:657`, and `01:665` say
  "read only"; the glossary term is **reading peer**, and blind is its own kind.
- [ ] **F17.** `01:349`: "Blind peers are susceptible to attacks that other
  peers are not": only two are unique to them. The question has no closing
  condition.
- [ ] **F30.** `01:630`: heading "Membership listings" could match the
  glossary's **membership list**.

## Protocol design (06)

Entries here concern [06-brainframe-protocol.md](06-brainframe-protocol.md):
how BrainFrame defends, in the material moved from the threat model.

### Decisions still to make

- [ ] **N61. Conflict records are used but not defined.** Add them to the record
  types (`06:53`), and say who may raise one and whether blind peers carry them.
- [ ] **N62. Promoting a blind peer.** "Changing membership type" (`06:405`)
  covers downgrades only. A blind peer made reading or writing needs the keys.
- [ ] **N65. crdt_lf drops a peer's clock on partial pruning.** Importing a
  snapshot older than local history under-reports that peer's version
  (`dag/graph.dart:133`). Never import an older snapshot; report it upstream.
- [ ] **N67. What a blind peer stores** (carried over from N63). Still
  undocumented: which encrypted items a blind peer keeps (whole files, edits
  since the last snapshot, a snapshot for joiners) and when it drops each.
- [ ] **N68. The agreement record needs defining.** "Snapshots require special
  handling" (`06:381`) adds snapshot hash and agreement records. Add both to
  the record types (`06:53`), and say who proposes a snapshot and which version
  it covers, so every peer builds the same one. Also state that a received
  snapshot is never imported as is: members build their own, and a joiner
  checks one against the agreement records first.
- [ ] **N69. Conflict records stay local, but three places send them out.**
  `06:144` ("transmitted to the ensemble"), `06:167` ("distributed to the
  ensemble as a"), and `06:212` ("it must generate a conflict record") predate
  the rule in "Conflict records and agreement records" (`06:127`). Each needs
  another record type, or a reword.
- [ ] **N70. Only writing UI peers can resolve a conflict.** A blind peer sees
  only ciphertext, so it can't judge content; a local-only record found by a
  blind, headless or reading peer is never resolved. Conflict records need a
  rethink.

### Housekeeping

- [ ] **F11.** `06:200`: "making this edits" ("these").
- [ ] **F12.** `06:261`: "link back to the previous edit" should be "to each
  edit it builds on".
- [ ] **F25. Glossary gaps.** The README glossary lacks conflict record,
  quarantine, bootstrapping record, invitation, fingerprint, and symmetric key,
  all used in the protocol document.
- [ ] **F27.** `06:538`: "must not accept an invitation from the peer" should be
  "an invitation acceptance from".
- [ ] **F31. "Read only" wording.** `06:38` heading, `06:117`, `06:429`, and
  `06:461` say "read only"; the glossary term is **reading peer**.
- [ ] **F33. Sort the moved material further.** Everything moved to 06 for now,
  but some of it is not wire protocol. Key generation, storage, and rotation
  could become a key-management document shared with encryption (#66, #69).
  Detached-peer reminders, file-sync and backup warnings, and quarantine
  handling describe BrainFrame's behaviour, and fit the [sync
  design](07-sync-design.md).
