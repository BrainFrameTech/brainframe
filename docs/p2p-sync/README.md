# P2P sync

This directory holds the design work for syncing an engram between peers
(**#67**), and the key management it shares with encryption (**#66**, spike
**#69**). The work is done as a sequence of documents. Each one starts only
after the one before it is accepted, because each one is checked against the
one before it.

## The sequence

| # | Document | Question it answers | Status |
| --- | --- | --- | --- |
| 1 | [Threat model](01-threat-model.md) | What are we protecting, from whom, and what must hold? | **next** — being drafted |
| 2 | [any-sync protocol](02-any-sync-protocol.md) | How does any-sync actually work? | placeholder |
| 3 | [any-sync fit](03-any-sync-fit.md) | Does any-sync meet the threat model's goals? | placeholder |
| 4 | [Syncthing protocol](04-syncthing-protocol.md) | How does Syncthing actually work? | placeholder — only if 3 says no |
| 5 | [Syncthing fit](05-syncthing-fit.md) | Does Syncthing meet the threat model's goals? | placeholder — only if 3 says no |
| 6 | [BrainFrame sync protocol](06-brainframe-protocol.md) | What exactly goes over the wire? | placeholder |
| 7 | [Sync design](07-sync-design.md) | How is it built inside BrainFrame? | placeholder |

Documents 2 and 4 are **descriptions**: what the protocol does, in its own
terms, without judging it. Documents 3 and 5 are **analyses**: they go through
the threat model's goals and threats one ID at a time and say whether each is
met, partly met, or not met, and why. Keeping the two apart stops a
description from quietly leaving out what the analysis would not like.

Document 6 is the protocol BrainFrame commits to — whichever was chosen, with
any changes the analysis called for, spelled out precisely enough to
implement from. Document 7 is the implementation design inside `lib/`, in the
same form as the documents in [`docs/design/`](../design/).

## How the threat model is built

The threat model uses four established methods, each for one job:

- **The Four Questions** (from the *Threat Modeling Manifesto*) give the
  structure: *What are we working on? What can go wrong? What are we going to
  do about it? Did we do a good enough job?* Document 1 answers the first two.
  Documents 3 to 6 answer the last two.
- **STRIDE** is the checklist for finding threats. Each element of the
  data-flow diagram is checked against all six categories (see the glossary).
- **LINDDUN**, used lightly, is a second pass for privacy threats, which
  STRIDE treats as a single category.
- **RFC 3552's attacker terms** (passive or active, on-path or off-path)
  describe what each adversary can do. any-sync's and Syncthing's own
  documents use the same terms, so the analyses compare like with like.

### Stable IDs

Everything the later documents need to point at gets an ID that never
changes. An entry that is no longer wanted is marked **retired**, and its ID
is never reused, so a reference in an older document never silently starts
meaning something else.

| Prefix | What it names | Example |
| --- | --- | --- |
| `A` | An asset: something worth protecting | `A1` note content |
| `ADV` | An adversary: someone who might attack an asset | `ADV2` active network attacker |
| `AS` | An assumption: something taken as true, not defended | `AS1` the OS of a keeper's own device is not compromised |
| `G` | A security goal: a property that must hold | `G3` a removed peer learns nothing new |
| `NG` | A non-goal: a property deliberately not promised | `NG1` hiding that sync is happening |
| `T` | A threat: one way an adversary could break a goal | `T7` replaying an old operation |

Goals are written as **properties that can be checked** against a protocol. "A
peer removed from the ensemble cannot read anything written after its removal"
can be checked. "Sync is secure" cannot.

## Where this starts from

Existing issues have already leaned one way on some of the questions the
threat model has to settle. They are starting points, not decisions; the
threat model confirms or overturns each one.

- **#67** plans a clean-room Dart reimplementation of the any-sync protocol,
  plus a Docker container on a NAS that hosts engrams for **more than one
  person**.
- **#67** leans towards a **NAS hub** for the first version: an always-on server
  that the devices trust, instead of true peer-to-peer. However, this specific
  lean should be revisited as the [revised
  decisions](01-threat-model.md#scoping-decisions) indicate a need to handle the
  full peer-to-peer sync immediately.
- **#66** and **#69** treat key management as one problem shared by
  encryption and sync: who can decrypt what.
- [note-identity-and-crdt.md](../design/note-identity-and-crdt.md) built the
  local half of sync: each note's CRDT op-log, kept on the device. Text deleted
  from a note stays in that history until the snapshot is updated and the
  history can be removed. That work is planned as part of **#118**.

## Glossary

Terms are added here as the documents start using them, so every document
uses them the same way.

### Threat modeling terms

- **Active attacker**: can read traffic. Can also change, drop, delay, replay,
  or inject traffic.
- **Adversary**: someone, or something, that might attack an asset. Each
  one is described by what it *can* and *cannot* do.
- **Asset**: something an attacker might want to read, change, or destroy.
- **Byzantine peer**: a peer that is part of the ensemble but behaves
  arbitrarily: buggy, compromised, or malicious. It is the hardest adversary for
  a CRDT, because the CRDT's convergence guarantee assumes every peer follows
  the rules.
- **Data-flow diagram (DFD)**: a diagram of the parts of the system, where
  data is stored, and how it moves between them, with the trust boundaries
  drawn in.
- **Forward secrecy**: stealing a key today does not unlock traffic recorded
  in the past.
- **LINDDUN**: seven kinds of privacy threat. **L**inking, **I**dentifying,
  **N**on-repudiation, **D**etecting, **D**ata disclosure, **U**nawareness,
  **N**on-compliance.
- **Off-path attacker**: cannot see the traffic, but can send packets of its
  own.
- **On-path attacker**: sits between the two ends of a connection and sees
  every packet, for example the Wi-Fi network you are on.
- **Passive attacker**: can read traffic but not change it.
- **Post-compromise security**: after a stolen key is replaced, the thief
  cannot read what is sent from then on.
- **Residual risk**: what is left of a threat after its mitigations, stated
  plainly instead of assumed away.
- **STRIDE**: six kinds of threat. **S**poofing (pretending to be someone
  else), **T**ampering (changing data), **R**epudiation (denying having done
  something), **I**nformation disclosure (reading what you shouldn't),
  **D**enial of service (stopping it working), **E**levation of privilege
  (gaining rights you shouldn't have).
- **Trust boundary**: a line in the data-flow diagram where data passes from
  something trusted to something less trusted, such as from the app to the
  network. Most threats sit on a trust boundary.

### BrainFrame terms

- **CRDT**: Conflict-free Replicated Data Type. A type of data built to allow
  automatic merging of potentially conflicting updates from multiple peers that
  may not be in constant communication with each other.
- **Edit history**: the history of edits made to a given document since the last
  snapshot across all peers. It consists of CRDT operations.
- **Engram**: a collection of files being maintained by BrainFrame. This will
  correspond with the top level of a folder somewhere in the user's file system.
- **Ensemble**: the name for the group of peers participating in one engram.
  All the peers that read or replicate this engram, together, make up one
  ensemble. Removed peers are not considered part of the ensemble.
- **Keeper**: a single human who accesses the ensemble using one or more peers.
- **Membership list**: the list of peers that are currently participating in an
  ensemble, along with what kind each member is: reading, writing, or blind.
- **Peer**: one copy of one engram, kept by a program that speaks the BrainFrame
  sync protocol, known to other peers by its own peerID. Every peer stores the
  edit history at least as far back as the most recent snapshot, and exchanges
  it with other peers. A peer is a copy, not a machine. A single machine with
  three engrams shows up as three unique peers. "Device" means the hardware
  running the BrainFrame application. Being a peer decides nothing about the
  types of operations it can perform: that is left to the definitions of the
  types of peers.
  - **Blind peer**: a peer that receives, stores, and passes on history it
    cannot read. It cannot check what it carries. Since this is otherwise a full
    peer, it can also cause problems with snapshots. Peers performing snapshots
    must take blind peers into account accordingly.
  - **Headless peer**: a peer with no user interface. It has no interface to the
    managed content; it is only run and managed as a background process. Whether
    it is reading, writing, or blind is a separate question.
  - **Member peer**: a peer currently on the ensemble's membership list. Only
    current members are sent the history. A member can be a reading peer, a
    writing peer, or a blind peer.
  - **Reading peer** or **writing peer**: a peer that holds the decryption keys,
    so it can check the history and turn the content back into plain files. A
    reading peer is unable to create edits to send back to the ensemble, while a
    writing peer can make new edits and send updates to the rest of the
    ensemble.
  - **Removed peer**: a peer that has been removed from membership in the
    ensemble. It keeps its copy and everything it has already received, but does
    not receive anything new.
- **Service**: a blind peer that offers hosting of multiple keepers' engrams.
- **Snapshot**: the complete state of a given document as of a given point in
  time as seen across all peers for the engram. Saved so that entries before
  this point in time can be safely discarded locally on the current peer.
