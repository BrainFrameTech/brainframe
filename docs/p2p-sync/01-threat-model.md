# Sync threat model

- **Status:** draft — what BrainFrame does and why it is worth protecting
  are written; nothing is decided yet
- **Author:** Michael J. Pedersen, assisted by Claude
- **Date:** 2026-10-19
- **Part of:** the [P2P sync sequence](README.md), document 1 of 7

## How to read this document

This document answers the first two of the Four Questions: *what are we
working on*, and *what can go wrong*. It ends with a list of security goals
(`G`). The later documents check a protocol against those goals and against
the threats (`T`) one ID at a time. The ID scheme and the terms used here are
in the [README](README.md).

## What we are working on

### What BrainFrame Solves

People ingest information (by reading things, listening to podcasts, watching
videos, etc), they make notes about the things they read, and then those notes
get lost or forgotten. BrainFrame provides the missing piece: It provides
persistent, durable links to the source of the information as part of the notes
themselves. This allows people to retain not just their knowledge, but also
where they learned it, thus helping them find the connections they've lost over
time.

Something unique about BrainFrame: The data the user maintains should be usable
in 50 years. All the files should still be visible, and readable. The internal
data (the sqlite databases, the metadata, the CRDT layers) may or may not be
usable within years, but the user's data should still be perfectly usable. This
means limiting support to file formats that will survive for that long. Without
any other information, the supported formats are chosen based on how long they
have already survived. If podcasts and video formats stabilize, then BrainFrame
will likely need to support them in future as well.

### What BrainFrame Is

BrainFrame is a second brain and an e-reader in one application. While it can't
provide a single media consumption experience (videos and podcasts are decidedly
out of scope at this time), it does provide a way to manage textual information.
This allows a single collection of files to include Markdown, PDFs, and ePUBs as
well as common graphical formats such as GIF, JPG, and PNG.

It is fully cross-platform, running on Windows, Linux, and macOS for the desktop
experience. For the mobile experience, it runs on Android, iOS, and iPadOS. The
Raspberry Pi is fully supported, running both with and without the Raspberry Pi
desktop. At time of writing, the code runs on a Raspberry Pi 4B with the desktop
environment, as well as on a Raspberry Pi 3B without the desktop environment and
capped at 512MB of RAM (to simulate using it on the Raspberry Pi Zero 2W). In
addition, a new hardware platform is intended for use with this, built from the
Raspberry Pi Zero 2W and an e-Ink display.

On platforms that can support it, pen and handwriting support will be provided.
This is likely to be restricted to Android tablets, iPads, and the e-Ink based
platform. These annotations will also need to be part of the CRDT layer, and
properly synced to multiple devices.

The application will provide peer to peer synchronization over the local
network, while also providing the ability for a headless peer to live outside
the local network. This functionality is the basis for keeping one engram in
sync across all of the devices participating in the engram.

The collection of files that are maintained and visible inside of BrainFrame are
called an engram. The primary file type is Markdown, and editing support for
this file type is provided inside of BrainFrame itself. In addition, BrainFrame
will provide highlighting and annotation support for the common graphics types,
as well as PDFs and ePUBs. All of these file types will have full viewer,
highlight, and annotation support, while only Markdown will have full edit
support.

BrainFrame also maintains a private folder inside the engram, named
`.brainframe`. This folder holds the data about the peers participating in this
engram, as well as engram level metadata. As it is part of the engram, it will
travel with the engram wherever the rest of the files go.

Finally, there is a database that lives outside of the engram that contains the
information for the conflict-free replicated data types that enable the merge
across devices to be automatic.

### What sync does

Sync keeps one engram the same on every device that holds it. An edit made on
one device reaches the others, and edits made on two devices at the same time
are merged rather than one overwriting the other.

BrainFrame does not have sync yet. Today, a person who wants an engram on two
devices puts the folder in a file-sync tool of their own (iCloud Drive,
Dropbox, Syncthing, git), and BrainFrame notices the files that change. Sync
built into BrainFrame replaces that tool for the people who want it, and it
exchanges the edit history, which a file-sync tool cannot do.

To do that, sync has to move between devices:

- the **notes** themselves, as CRDT operations;
- the **documents** a person reads, as files;
- their **markup**: highlights, annotations, and handwriting;
- the **structure** of the engram: which notes exist, their paths, and what
  links to what;
- the **identity map**: the id of each note, and the name of each device.

### Why it is worth protecting

A second brain is a record of how one person thinks. That makes it worth
more to an attacker, and its loss worse for its owner, than most collections
of files:

- **It is personal by design.** People write in it what they write nowhere
  else: journals, health, money, relationships, half-formed ideas, work they
  have not shown anyone. The point of the app is that it is all in one place.
- **The whole says more than any part.** The links between notes, the tags,
  and the folder names map what a person cares about and how the parts of
  their life connect. Someone who reads none of the notes, but sees only
  their titles and links, still learns a great deal.
- **It remembers what was deleted.** The edit history is kept so that edits
  can be merged. Text a person deleted, because they regretted writing it,
  is still in that history, and sync carries the history to every device.
- **What someone reads, and what they mark, is revealing too.** The
  documents in an engram, and the passages highlighted in them, say what a
  person is studying, worried about, or planning.
- **Its owner relies on it as memory.** A note that was silently changed is
  worse than one that was lost, because the person trusts it and acts on it.
- **Sync spreads mistakes.** Without sync, a corrupted or deleted note is
  lost on one device. With sync, it can be lost on every device at once,
  including the one that would have been the backup. Sync therefore has to
  protect against damage as well as against reading.

### Scoping decisions

These have to be settled first. Every later section depends on the answers.

#### Who shares an engram?

An engram starts its existence on a single machine for a single user. Over its
lifetime, it is expected to grow to be shared on multiple devices owned by a
single user. The ultimate expansion is for the user to allow other users (and
their devices) to join the engram. The initial scope is small, but the ultimate
scope is to allow the user to share with others. BrainFrame does not guarantee
the ability to remove the engrams from devices, only to stop sharing new edits
with specific peers.

#### Is there a server?

Only in the loosest sense of the word. A server, even one on the open internet,
is simply another peer. Since it's on the internet, or on a local NAS, it will
be a headless peer, but it is not a server in the traditional sense of the word.

#### Is there a service that can handle multiple keepers' engrams?

Eventually, yes. This is as close to an actual server as BrainFrame will ever
provide. This is also likely to be a paid service when it happens.

#### Where does sync reach?

Sync will reach for local network first, and it will have the option of using a
hosted service on the open internet. When using something on the open internet,
it will need to have configuration options to ensure that BrainFrame can find
that peer.

#### What happens when a device is lost or stolen?

The device can be removed from the list of peers that participate in the engram.
This does not remove the copy of the engram from that device. It only prevents
getting new history onto the device. Removing existing history and notes would
create the risk of losing all of a user's notes, and that is an unacceptable
risk.

#### Who is out of scope?

- On reading and writing peers, we will not attempt to defend against attackers
  who have access to the keeper's own account (or administrator access) on the
  local machine. They already have full access to the unencrypted documents
  being managed in BrainFrame, defending further against these attacks would be
  pointless. Instead, we will focus on defending against attacks on BrainFrame
  itself. This means preventing BrainFrame from being used in an escalation of
  privilege attack, as well as preventing attacks from providing unauthorized
  access to BrainFrame protected data (or any other data on the machine that
  BrainFrame could access).
- On blind peers (including the service), the goal is to have minimal knowledge
  of the history and data being stored. Everything should be fully encrypted
  using encryption that stays encrypted, even in the face of well equipped
  attackers, for decades. Potential attackers can gain access by gaining access
  to the underlying infrastructure, and the defense must be robust enough to
  prevent those attackers from learning about the documents being stored on
  behalf of the user. Some data will still be exposed, including the membership
  list, number of devices, their peerIDs, potentially their IP addresses,
  arrival times and sizes of edits, and how they're ordered relative to each
  other and any snapshots. Where possible, we need to reduce the risk of data
  exposure.
- Explicitly In Scope: Using a stolen device to manipulate an engram before the
  proper owner can remove the stolen device from that engram. This has a race
  condition, and the race exists *unless* membership changes are gated:
  - Attacker steals a device
  - Before the owner of the device realizes the theft has occurred, the attacker
    removes all other devices from the engram.
  - When this happens, the proper owner is locked out of the engram. On a
    self-hosted headless peer (regardless of type: reading, writing, or blind),
    the owner can delete the peer's data from disk and create a new headless
    peer and engram set.
    - On a self-hosted blind peer, the plaintext of the keeper's files was never
      present, so deleting and recreating loses nothing from the keeper's
      devices.
    - On the service, tools must exist to allow administrators to delete an
      entire engram so the correct owner can recreate it.
    - Additional side effect: Service administrators/operators are now an attack
      vector, and could cause an engram owner to be forced to recreate their
      engram on the service. The attack models must account for this.

### Scope

What this threat model covers, and what it leaves to other documents.

### Data-flow diagram

A Mermaid diagram of the devices, any server, the data stores, and the
connections between them, with trust boundaries drawn as subgraphs.

### Assets

| ID | Asset | Why it matters |
| --- | --- | --- |

## What can go wrong

### Adversaries

| ID | Adversary | Can | Cannot |
| --- | --- | --- | --- |

### Assumptions

| ID | Assumption | If it is false |
| --- | --- | --- |

### Threats

A summary table, then one subsection per threat with the details.

| ID | STRIDE / LINDDUN | Asset | Adversary | Summary |
| --- | --- | --- | --- | --- |

## What must hold

### Security goals

| ID | Goal | Defends against |
| --- | --- | --- |

### Non-goals

| ID | Non-goal | Why not |
| --- | --- | --- |

## Open questions

Questions raised during review that are not settled yet.

- **Should some actions require a person to be physically present?** For
  example: pairing a new device, removing one, or changing who can read an
  engram, authorized by a tap on a hardware key rather than by anything a
  compromised device could do alone. An OpenPGP smart card (such as a
  YubiKey) is one way to do it; FIDO2 is another, with wider support on
  phones. This is a mechanism, so it is chosen in
  [document 6](06-brainframe-protocol.md). Here the question is only whether
  the threat model asks for the property, and for which actions.
- **A blind peer that can't read the data can't validate it either** This means
  that an attacker can submit something that creates problematic history, to the
  point of potentially preventing successful startup of BrainFrame. This must be
  guarded against somehow. The mechanism to do so is unknown, but must be
  defined. See the question "How to define a harmful edit?" below.
- **A blind peer outside snapshotting can keep history much longer than an**
  **otherwise active peer** If the blind peer can't validate the data, then a
  safe mechanism must be provided to allow the blind peer to discard edit
  history after new snapshots get made. This mechanism is not yet defined, but
  must be.
- **How to define a harmful edit?**: An edit is harmful under a number of
  different circumstances, with the most obvious one being the case where a
  future restart will actually be prevented due to the system running out of
  memory or taking too long to consume the edit and produce a meaningful result.
  Further research is needed to define the harmful edit cases, and then provide
  the actual defense against them. Note that the same definition of harmful edit
  must be applied to *all* peers, whether they are running on a server with
  multiple terabyts of RAM or a single Raspberry Pi Zero 2W with 512MB of RAM.
  If the rules are allowed to differ based on the specs of the machine running
  the rules, then divergent CRDT trees become possible, and that is an
  unacceptable state.
- **How to validate snapshots?** The blind peer, with no knowledge of the data,
  provides an attack vector that has not been considered: If a device is stolen,
  then the attacker can force a new snapshot of an empty document, effectively
  destroying the document. Other variations include ransomware scenarios, as
  well as simply global search and replace across the engram. How do we prevent
  these bad actor edits from infecting the entire engram?
- **How to protect against stolen devices taking over?** We need to have a
  mechanism to prevent a stolen device from taking over an ensemble. Right now,
  as stated, any writing peer can remove any other device. We should provide
  options to the user to manage this, including the idea of requiring something
  like a YubiKey or a passkey or a Fido2 key.
- **What about reading members?** We need enforcement mechanisms. A blind peer
  can't enforce reading membership, and will carry forged edits. This is also
  part of the data validation problem described above.

## Settled in review

Decisions made in review, with the reasoning, so they are not argued again.

- **Removed Peers**: The keeper must be able to tell BrainFrame that a peer is
  removed from the ensemble (lost, stolen, reformatted, whatever the reason), so
  that it will stop tracking the peer, and therefore allow snapshots to occur
  without the peer. This removed peer status must be able to travel to other
  participants in the engram as well, so that other devices (or even users) will
  stop tracking when that notification arrives. Some consequences of this
  decision:
  - Any writing peer can declare another peer removed. Reading peers are not
    given this same permission.
  - On peer removal and rejoining:
    - A peer may get removed from the ensemble (lost/stolen device, dispute
      between keepers, etc).
    - A peer may join again after having been removed from participating in
      the ensemble.
    - The local edit history on the rejoining peer can experience data loss at
      this stage. The data loss possibility is not merely cosmetic: CRDT
      operations can be rejected by the ensemble, and those rejections can cause
      the rejoining device to lose some of the rendered content when new edits
      or snapshots come to the rejoining peer. The data loss possibility is real
      and material to the keeper of the device that is rejoining the ensemble.
    - The keeper will have to decide how to handle this scenario, on a
      file-by-file basis. Either new documents have to be made, or local edit
      history is lost. From a user experience perspective, this is less than
      ideal. However, it is still better than having indefinite edit history
      growth.
    - At time of rejoining, the existing peer ID will be allowed back into the
      ensemble, and the peer will rejoin as if it was brand new, while still
      using the same peerID that it used before removal. Edit history is then
      possible to bring in from the rejoining peer, minimizing data loss/new
      document scenarios where possible. Permissions (reading vs writing) have
      to be re-established at the time of joining, and the current keys have to
      be given to the rejoining peer.
  - The rendered notes are not kept encrypted at rest on keepers's device. The
    files will be kept as plain, unencrypted data outside of the `.brainframe`
    folder. This is the desired state of the system, and allows us to hit our
    goal of making the data usable for the next 50 years. Encryption is only in
    place where it is needed to protect the user's privacy. For example, a
    service (as defined in the [README](README.md#glossary)) keeps every
    engram's content and edit history encrypted.
    - Data inside of the `.brainframe` folder will not be encrypted, *except* in
      the case of a blind peer. A blind peer, as defined in the
      [README](README.md#glossary), is expected to keep as much data as possible
      encrypted in the `.brainframe` folder. The membership list can't be kept
      encrypted and still validate membership in the ensemble. For other data
      that can't be kept encrypted, see this [Scoping
      Decision](#who-is-out-of-scope).
    - The third location for data contains this peer's copy of the global edit
      history for the engram across the ensemble back to the last snapshot, and
      this location is not part of either the keeper's data *or* part of the
      `.brainframe` folder. On reading and writing peers, encrypting this data
      does not make sense. An attacker who has access to the keeper's account
      also has the ability to access the decryption keys, resulting in a trivial
      attack to get that edit history. On blind peers, the data for this
      location will be encrypted, preventing an attacker from gaining anything
      more than the encrypted copy.
  - The most painful consequence of this decision: Key management is now
    confirmed to be in scope. When a peer gets removed, every remaining reading
    or writing peer must now get a new key for receiving the data and decrypting
    it; blind peers never receive a decryption key. This also means that, once a
    peer is removed, it is not able to get the new key *nor* is it able to
    receive new data from the engram. An attacker who gains OS level access to a
    blind peer (or the service) will be unable to read the data, but will still
    be able to review (and possibly modify) the metadata. This specific attack
    area must be mitigated.
- **Peers must defend against pathological edit history** Any individual peer
  must have a way to reject edits that are harmful to peers that are in the
  ensemble. See the open questions for this one: "How to define a harmful edit".
  This rule is almost absolute. To clarify it:
  - Any reading peer that will render the output of the edit history must reject
    pathological edits.
  - Any blind peer that is unable to read the contents of the edit history must
    not drop edits for being unreadable until a peer provides a new snapshot
    that allows it to discard edit history. It cannot provide defense for the
    other peers.

## Open Issues Identified by Claude

Places are named by section and quoted text rather than line number, so the
references survive edits. Remove an item once it is addressed.

### Contradictions

- [ ] **A12. Rejoining can lose notes before the keeper chooses.** The rejoin
  bullet under "Removed Peers" says rejected operations "can cause the
  rejoining device to lose some of the rendered content when new edits or
  snapshots come to the rejoining peer", and the next bullet says "the keeper
  will have to decide… on a file-by-file basis". If incoming snapshots can
  change the rejoining peer's files before that decision, BrainFrame removes a
  keeper's notes without asking, which [What happens when a device is lost or
  stolen?](#what-happens-when-a-device-is-lost-or-stolen) calls "an
  unacceptable risk". State the order: the keeper's per-file choice happens
  before anything incoming overwrites a local file.
- [ ] **A13. Writing peers also render.** The settled rule "Peers must defend
  against pathological edit history" says "Any reading peer that will render
  the output of the edit history must reject pathological edits". By the
  glossary, a writing peer is not a reading peer, so as written the rule does
  not cover writing peers. "Any reading or writing peer" closes it.

### Decisions still to make

- [ ] **N5. Who authorizes a rejoin?** The rejoin bullet under "Removed Peers"
  now answers two parts of this: the peer keeps its old peerID, and it gets the
  current keys only at rejoin. What is left: "the existing peer ID will be
  allowed back" does not say by whom. A removed peer that rejoins is, from the
  ensemble's side, indistinguishable from a stolen one being handed back. State
  that rejoining needs the same authorization as adding a new peer, and widen
  the open question "How to protect against stolen devices taking over?" to
  cover adding and rejoining, not only removal.
- [ ] **N6. Edits brought back by a rejoining peer are untrusted.** The rejoin
  bullet says "Edit history is then possible to bring in from the rejoining
  peer". A peer is removed most often because it was lost or stolen, so
  whatever it wrote while away may be the thief's. Its signatures do not help:
  they were made with a key that was valid until removal, and its own clock can
  claim any edit came before then. Decide whether edits from a rejoining peer
  are merged automatically, shown to the keeper first, or kept apart as new
  documents (the existing file-by-file choice).
- [ ] **N7. Reusing a peerID must never reuse an operation ID.** The rejoin
  bullet keeps the old peerID. CRDT operations are identified by peerID plus a
  counter. If a rejoining peer restarts from a snapshot with its counter reset,
  its new operations can carry the same IDs as ones it made before removal, and
  peers holding both will diverge. State that a returning peer's operation IDs
  always continue past every one it used before.
- [ ] **N8. Can one keeper remove another keeper's peers?** "Removed Peers"
  lists "dispute between keepers" as a reason, and says "Any writing peer can
  declare another peer removed". In a shared engram, that lets either keeper
  cut the other out entirely, key rotation included. Decide whether that is
  intended, or whether a keeper may only remove their own peers and removing
  another keeper is a separate, gated action.
- [ ] **N9. Peers that miss a removal.** The key-rotation bullet under "Removed
  Peers" says every remaining reading or writing peer "must now get a new key".
  A peer that is offline when the removal happens learns of it, and gets the
  new key, only later. Until then it may keep syncing with the removed peer.
  Decide what the goal promises: that a removed peer receives nothing new
  "after every remaining member has learned of the removal", or something
  stronger, such as peers refusing to sync until they have heard from the
  ensemble recently.

### Glossary (README)

- [ ] **C1. Read-only needs signatures, not just keys.** A reading peer holds
  the decryption key, so if writing is gated only by the key, a reader can forge
  edits. If edits carry a writing peer's signature, every peer can check it,
  blind peers included, without decrypting anything. That changes the open
  questions "A blind peer that can't read the data can't validate it either"
  and "What about reading members?". The threat model states the property, for
  example "an edit not signed by a current writing peer is rejected by every
  peer"; document 6 picks the mechanism.
- [ ] **C2.** *Blind peer*: "Since this is otherwise a full peer" contradicts
  "cannot read". "An otherwise ordinary member" fits.
- [ ] **C4.** *Engram*: "a folder somewhere in the user's file system" is not
  true on a blind peer, and "user" should be "keeper".
- [ ] **C5.** *Snapshot* ("as seen across all peers for the engram") and *Edit
  history* ("since the last snapshot across all peers"): "all peers" should be
  "the ensemble".

### Terminology sweep

- [ ] **D1. user / owner → keeper.** Still in: "What BrainFrame Solves" ("the
  data the user maintains", "the user's data"); [Who shares an
  engram?](#who-shares-an-engram) throughout; [What happens when a device is
  lost or stolen?](#what-happens-when-a-device-is-lost-or-stolen) ("a user's
  notes"); [Who is out of scope?](#who-is-out-of-scope) ("on behalf of the
  user", and "owner" throughout the stolen-device race); the open question on
  stolen devices ("options to the user"); and "Removed Peers" ("or even
  users", "the user's privacy").
- [ ] **D2. device → peer** wherever a copy of the engram is meant; keep
  "device" for hardware. Mainly "What BrainFrame Is", "What sync does", [What
  happens when a device is lost or
  stolen?](#what-happens-when-a-device-is-lost-or-stolen), the stolen-device
  race under [Who is out of scope?](#who-is-out-of-scope), the open questions
  on hardware keys and stolen devices, and "Removed Peers" ("other devices").
- [ ] **D4. participants → members, and the membership list.** "Removed Peers"
  says "travel to other participants in the engram"; [What happens when a
  device is lost or stolen?](#what-happens-when-a-device-is-lost-or-stolen)
  says "the list of peers that participate in the engram", which is the
  **membership list**.

### Overlapping open questions

- [ ] **E1.** "Should some actions require a person to be physically present?"
  and "How to protect against stolen devices taking over?" ask the same thing.
  Merge them, or have one point to the other. N5 adds rejoining to what they
  cover.
- [ ] **E2.** "A blind peer outside snapshotting can keep history much longer"
  is mostly answered by the settled rule for blind peers. What is left belongs
  with "How to validate snapshots?".
- [ ] **E3.** "A blind peer that can't read the data can't validate it either"
  and "What about reading members?" overlap. After C1, little of the second is
  left. The second also still says "read-only membership" in its body.

### Housekeeping

- [ ] **F1.** The status line still says "nothing is decided yet".
- [ ] **F2.** "This rule is almost absolute": name the exception or drop
  "almost".
- [ ] **F3.** The open-question titles "A blind peer that can't read the data…"
  and "A blind peer outside snapshotting…" have no closing punctuation, and the
  second splits its bold across two spans.
- [ ] **F4.** Typos: "terabyts", "keepers's", and "Explicitly In Scope" (should
  be "in scope").
- [ ] **F5.** The scoping decisions [Who shares an
  engram?](#who-shares-an-engram), [Is there a server?](#is-there-a-server),
  [Is there a service that can handle multiple keepers'
  engrams?](#is-there-a-service-that-can-handle-multiple-keepers-engrams), and
  [Where does sync reach?](#where-does-sync-reach) give answers but no
  reasoning; *Settled in review* promises the why.
- [ ] **F6.** "What sync does" ("exchanges the edit history") and the "It
  remembers what was deleted" bullet still say history is kept indefinitely.
  The glossary's *Edit history* entry gives the fix: deleted text stays until
  the next snapshot.
- [ ] **F8.** Under "On peer ejection and rejoining", the first two bullets
  ("If peers get ejected…" and "A peer may be found again…") say the same
  thing. Merging them would also be the place to say *what* is lost: edits the
  returning peer made that the ensemble never received. Its plain files stay,
  as [What happens when a device is lost or
  stolen?](#what-happens-when-a-device-is-lost-or-stolen) promises; "local edit
  history" could be read as more than that.
