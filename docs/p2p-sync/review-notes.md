# Sync threat model: review notes

The running list of review findings for the [sync threat
model](01-threat-model.md), kept apart from it so the document itself holds only
its content. It is a working document, not part of the [sequence](README.md),
and is meant to keep the threat model on track until it is accepted.

Line numbers, written as `:123`, refer to `01-threat-model.md` as of the date
noted in each part; the quoted text finds each spot when they drift. An entry is
removed once it is addressed.

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
  *Settled in review* is about this model.
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

## Contradictions

None found in the sweep of 2026-11-07.

## Decisions still to make

- [ ] **N61. Conflict records are used but not defined.** Add them to the record
  types (`:683`), and say who may raise one and whether blind peers carry them.
- [ ] **N62. Promoting a blind peer.** "Changing membership type" (`:1167`)
  covers downgrades only. A blind peer made reading or writing needs the keys.
- [ ] **N65. crdt_lf drops a peer's clock on partial pruning.** Importing a
  snapshot older than local history under-reports that peer's version
  (`dag/graph.dart:133`). Never import an older snapshot; report it upstream.
- [ ] **N67. What a blind peer stores** (carried over from N63). Still
  undocumented: which encrypted items a blind peer keeps (whole files, edits
  since the last snapshot, a snapshot for joiners) and when it drops each.
- [ ] **N68. The agreement record needs defining.** "Snapshots require special
  handling" adds snapshot hash and agreement records. Add both to the record
  types (`:683`), and say who proposes a snapshot and which version it covers,
  so every peer builds the same one. Also state that a received snapshot is
  never imported as is: members build their own, and a joiner checks one
  against the agreement records first.
- [ ] **N69. Conflict records stay local, but three places send them out.**
  `:842` ("transmitted to the ensemble"), `:865` ("distributed to the ensemble
  as a conflict record"), and `:914` ("generate a conflict record to the
  ensemble") predate the new rule. Each needs another record type, or a reword.

## Overlapping open questions

- [ ] **E4. Three questions cover forced snapshots.** "How to validate
  snapshots?", "How to deal with a malicious actor forcing snapshots…", and part
  of "A blind peer outside snapshotting keeps history longer". A forged snapshot
  is already refused. What remains is one question: how long history is kept
  before a legitimate snapshot makes a stolen peer's vandalism permanent.

## Before acceptance

- [ ] **F26. Empty sections.** Scope, Data-flow diagram, Assets, Threats, and
  Security goals are still empty, and later documents check against them.

## Housekeeping

Line numbers are as of 2026-11-07; the quoted text finds each spot.

- [ ] **F5. Scoping decisions without reasons.** Who shares an engram, Is there
  a server, Is there a service, and Where does sync reach state no reason.
- [ ] **F6.** `:143`: "in that history" should add "until the next
  snapshot".
- [ ] **F11.** `:890`: "making this edits" ("these"). `:636`: heading
  "Membership listings" could match the glossary's **membership list**.
- [ ] **F12.** `:954`: "link back to the previous edit" should be "to each edit
  it builds on".
- [ ] **F13.** `:1000`: "This specific attack area must be mitigated" could
  link to the two blind-peer metadata and history questions.
- [ ] **F14.** `:320`: "any writing peer can remove any other peer" is now "any
  writing UI peer".
- [ ] **F15. "Read only" wording.** `:660` heading, `:662`, `:694`, and `:781`
  say "read only"; the glossary term is **reading peer**, and blind is its own
  kind.
- [ ] **F17.** `:355`: "Blind peers are susceptible to attacks that other peers
  are not": only two are unique to them. The question has no closing condition.
- [ ] **F25. Glossary gaps.** The README glossary lacks conflict record,
  quarantine, bootstrapping record, invitation, fingerprint, and symmetric key.
- [ ] **F27.** `:1306`: "must not accept an invitation from the peer" should be
  "an invitation acceptance from".

## Proposal: move the mitigations out

Agreed: much of *Settled in review* now says *how* to defend, not *what* must
hold. The README gives this document the first two of the Four Questions, and
documents 3 to 6 the last two, so the mechanisms belong later. Each section
that moves should leave behind a one-line security goal (`G`) here, stated as a
property that documents 3 and 5 can check a protocol against.

| Section here | Moves to | Leaves behind (example goal) |
| --- | --- | --- |
| Read Only Membership: record fields | 6 | Every record names its signer, and peers reject unsigned ones |
| Edit histories: removal and document removal records | 6 | A removed peer's edits outside its removal set are never applied |
| Edits must form a DAG | 6 | Edits are signed and bound to the edits they build on |
| Duplicate edit IDs, pre-snapshot edits (under Removed peers) | 6 | A reused edit ID with new content is never applied |
| Snapshots require special handling | 6 | No history is discarded until every member agrees on the snapshot |
| Bootstrapping an ensemble: record fields | 6 | An ensemble has exactly one origin, which a joiner can verify |
| Joining an ensemble: invitation records | 6 | A peer joins only by invitation, confirmed by both keepers |
| What a decryption key is, Key rotation process | new: key management | A removed peer cannot read anything written after rotation |
| Long Term Detached Peers (thresholds, reminders) | 7 | A detached peer cannot grow history unnoticed |
| File synchronization tools, Backup restoration | 7 | Keepers are warned when another tool writes to the engram |
| Quarantine and conflict-record handling (under Removed peers) | 7 | A removed peer's edits reach the ensemble only through a keeper |

**A new document for key management.** The README already treats keys as one
problem shared by sync and encryption (#66, #69). Key generation, storage,
distribution, and rotation would serve both, so they fit a document of their
own rather than document 6 alone.

**What stays here:** what BrainFrame is and why it is worth protecting, the
scoping decisions, the tables (assets, adversaries, assumptions, threats,
goals, non-goals), the open questions that ask *whether* a property must hold,
and *Clocks cannot be trusted*, *A fake ensemble is a fork*, and the ownership
notes, since each is a decision about scope rather than a mechanism.

**When.** Moving now would scatter text across placeholders before the goals
exist. Writing the goals first, then moving each section as its goal lands,
keeps nothing from being lost in between.
