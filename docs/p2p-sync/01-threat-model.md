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

### Should some actions require a person to be physically present?

For example: pairing a new device, removing one, or changing who can read an
engram, authorized by a tap on a hardware key rather than by anything a
compromised device could do alone. An OpenPGP smart card (such as a YubiKey) is
one way to do it; FIDO2 is another, with wider support on phones. This is a
mechanism, so it is chosen in [document 6](06-brainframe-protocol.md). Here the
question is only whether the threat model asks for the property, and for which
actions.

### A blind peer that can't read the data can't validate it either

This means that an attacker can submit something that creates problematic
history, to the point of potentially preventing successful startup of
BrainFrame. This must be guarded against somehow. The mechanism to do so is
unknown, but must be defined. See the question "How to define a harmful edit?"
below.

### A blind peer outside snapshotting keeps history longer

If the blind peer can't validate the data, then a safe mechanism must be
provided to allow the blind peer to discard edit history after new snapshots get
made. This mechanism is not yet defined, but must be.

### How to define a harmful edit?

An edit is harmful under a number of different circumstances, with the most
obvious one being the case where a future restart will actually be prevented due
to the system running out of memory or taking too long to consume the edit and
produce a meaningful result. Further research is needed to define the harmful
edit cases, and then provide the actual defense against them. Note that the same
definition of harmful edit must be applied to *all* peers, whether they are
running on a server with multiple terabyts of RAM or a single Raspberry Pi Zero
2W with 512MB of RAM. If the rules are allowed to differ based on the specs of
the machine running the rules, then divergent CRDT trees become possible, and
that is an unacceptable state.

### How to validate snapshots?

The blind peer, with no knowledge of the data, provides an attack vector that
has not been considered: If a device is stolen, then the attacker can force a
new snapshot of an empty document, effectively destroying the document. Other
variations include ransomware scenarios, as well as simply global search and
replace across the engram. How do we prevent these bad actor edits from
infecting the entire engram?

### How to protect against stolen devices taking over?

We need to have a mechanism to prevent a stolen device from taking over an
ensemble. Right now, as stated, any writing peer can remove any other device. We
should provide options to the user to manage this, including the idea of
requiring something like a YubiKey or a passkey or a Fido2 key. Additionally,
removal and rejoining needs to be protected somehow.

### How to deal with a malicious actor forcing snapshots across the ensemble?

A malicious actor, stealing a peer device, can take over and do a number of
things to destroy the ensemble. The most obvious is to empty out every note,
force a snapshot, and propagate that snapshot. Other malicious edits would
involve encrypting the data, and pushing that encrypted data out as a snapshot.
The dominant factor here is that a snapshot is destructive of history, and a
malicious actor could easily force that snapshot and propagation. Need to
determine a method for dealing with those actions.

### How to define useful file size limits, record size limits, etc?

Harmful edits are just one avenue of attack. An engram under attack can be asked
to receive very large files (multiple gigabytes), that only some machines could
actually open successfully, while the e-Ink device that is being planned might
never be able to open them under any circumstances. A single PDF that is
deliberately malformed and consumes several gigabytes of storage might only be
possible to open on a high end desktop, or not at all. And an attacker could
simply have the goal of rendering the engram useless.

Fortunately, recovery from the worst part of such an attack is usually
relatively easy (delete the `.brainframe` folder, delete the offending files if
they got written, re-adopt the folder using the application, have the other
peers join the new ensemble). However, that recovery should be a last resort,
not a standard "Oops, that sucks" response.

Relevancy is increased in the event of an already trusted peer being
compromised: a UI peer with writing permission could be compromised and generate
conflict records that could overwhelm devices with malicious edits.

Limits on total quantity of records need to be implemented. A compromised device
could generate millions of small edits that could bring down the ensemble. A
single document, for example, could insert the letter `a` 10,000 times (each in
their own edit), and then delete each of them, and repeat that process
100,000,000 times before trying to synchronize with the ensemble. This would
likely bring down even the most powerful desktops running BrainFrame.

Transmission of files as a whole must also be guarded. For example, on Linux, a
symbolic link to /dev/zero would result in a file that has unlimited size. Files
will need to be strictly regular files (no sockets, no symbolic links, no pipes,
etc), with their maximum size small enough to be usable on the eInk device, and
streamed rather than received whole. The maximum size must work for *all*
platforms, from the e-Ink device all the way up to the desktop, so the maximum
size is actually a constant across all peers.

We need to define useful limits that won't prevent people from storing the files
that they want to store in the engram, but also will not overwhelm the smallest
devices and only be usable on the most powerful desktops.

### What about reading members?

We need enforcement mechanisms. A blind peer can't enforce reading membership,
and will carry forged edits. This is also part of the data validation problem
described above.

### What about purging history on blind peers?

An attacker must not be able to read the encrypted snapshots. It also must not
be able to read the contents of individual edits (which are also encrypted).

In order for the blind peer to be able to tell what data it can purge, it *must*
be able to read enough data to determine that an edit belongs to a specific
document, and that a new snapshot for that document has arrived, allowing it to
remove the edit history from before that snapshot. A consequence of this is that
the ensemble must carry enough information about the snapshot to prove that
every peer has actually moved to this point in the edit history. Without those
guarantees, a malicious actor using a stolen writing peer could submit a
snapshot to a blind peer that claims the current state of a document is empty,
and all other peers would accept that edit as being valid even if they have
outstanding edits against a document.

This question is about the balance: How do we provide enough data for a blind
peer to safely delete no longer relevant history without giving an attacker the
ability to destroy the ensemble?

### What about metadata on blind peers?

With key management being in scope, and blind peers being a requirement, the
exposed metadata on a blind peer (especially as it relates to the service)
leaves attack surface, specifically the area of traffic analysis.

Related to the history, we need to list the metadata that is needed for blind
peers to function. A partial list of all metadata includes the following:

- membership list
- device count
- peerIDs
- document IDs
- links between edits and snapshots
- the timing of edits
- timing of arrivals of edits
- last seen edit ids from a given peer
- sizes of edits
- IP addresses of peers

This is only a partial list. When this question is resolved, the full list of
metadata must be known, and the list of what metadata is required for a
blind peer to function must also be known. Once the full list is known, we must
limit the usability of the metadata for an attacker. Potential mitigations
include:

- Padding edit sizes to always be a fixed size, and grouping edits into buckets
  with each at a fixed size to allow large edits.
- Batching or delaying distribution of edits to prevent arrival times revealing
  more than required
- Not exposing IP addresses to the blind peer for instance via relaying

Closing out this question requires knowing the full list of metadata, the full
list of metadata required for the blind peer, and mitigation strategies to
reduce the risks of exposure from a blind peer. It also requires having the list
of residual risk, including definitions of the risk and why this risk must
remain.

### What about history attacks against blind peers?

A blind peer can't modify existing data, since the edit history must all be
signed to prevent that attack. However, an attacker could otherwise attack the
history: deleting edits, delaying edits, or refusing to pass them along. Peers
in an ensemble with a blind peer need to have extra checks to verify that the
blind peer is behaving correctly. The strongest of these checks will be
communicating with more peers than the blind peer. Ideally, peers should not
rely on a single peer in the ensemble.

This check might not be sufficient, or it might not be feasible. For instance, a
single peer kept behind a VPN may have only the blind peer accessible. Even with
that case, this question must answer how a given peer can trust that the peers
it is communicating with are actively giving it *all* of the updates it is
supposed to receive on the cadence it is supposed to receive them. Once that
mechanism is determined, this question can be closed.

The worst case: An attacker could cause a blind peer to delay (or entirely
withhold) the removal record for a peer. The result would be a peer that does
not know about the removal of another peer, causing the removed peer to still be
able to participate in the ensemble.

A *possible* mitigation would be to use the edit IDs for the membership list.
Using a pure CRDT implementation would likely preclude this, as the edit ID
becomes the peerid+HLC+counter. It also would not provide protection when the
membership updates infrequently. For example, if a peer is removed, and no other
membership changes occur for months, then the removed peer could remain part of
the ensemble due to detached peers. The idea makes for a good starting point
though, and should be explored.

### What about wildly skewed clocks?

The Hybrid Logical Clock is used for ordering edits, as discussed in [Clocks
cannot be trusted](#clocks-cannot-be-trusted). The crdt_lf sync package encodes
the counter portion of the HLC as a 16 bit integer.

Scenario: An attacker could set their local clock to the year 3000, and then
make a single edit in every file in the engram (adding a blank line at the end,
for example). Getting this edit distributed to the ensemble would then pull
every document's HLC to that timestamp, and rely on the counter portion of the
HLC to order edits. When the HLC is encoded by crdt_lf, it encodes the counter
as a 16 bit integer.

With only a 16 bit integer, the ensemble could easily generate repeating IDs,
resulting in documents that can no longer be rendered reliably.

Two options exist for handling this:

- Bound the drift. We could place a limit on how far off the edits are allowed
  to be. This could result in detached peers being unable to synchronize with
  the ensemble. Consider a Raspberry Pi that is unable to reach a time server
  quickly. Any incoming edits will look like they come from the future
  (potentially a far future), outside the drift boundary. If we go with this
  option, then incoming edits can't be applied, but do have to be accepted and
  stored until they can be confirmed. Quarantine might be the right answer for
  that.
- Don't use crdt_lf's synchronization, and instead encode the HLC ourselves.
  This could result in us being stuck on an older version of crdt_lf, but it
  does remove the detached peer/divergent document condition entirely.

Other options may exist, and should be explored before closing this question.

This question can be closed when a mechanism for handling this scenario has been
solidified and does *not* produce divergence amongst the ensemble.

## Settled in review

Decisions made in review, with the reasoning, so they are not argued again.

### Clocks cannot be trusted

No peer's clock may be used to form the basis of a trust decision. Attackers can
manipulate their local clock, or submit edits where the hybrid logical clock
references timestamps that were not actually accurate. Most Raspberry Pi devices
do not have a hardware clock, and can become out of sync with internet clocks
easily. A desktop or laptop can get time from an untrusted source. Mobile
devices can have their time be manipulated by the owner manually changing it, or
even just due to a misconfigured time server.

Clock times are not reliable, and cannot be used to determine an actual trust
relationship in any way. This has direct impacts on how to determine if a
removed peer has the ability to submit an edit to the ensemble, and is therefore
called out here.

For non-trust based choices, clocks are acceptable.

- CRDTs use Hybrid Logical Clocks. These are susceptible to attacks based on
  concurrent edits, but the risk here is that one device will always win in a
  truly conflicting edit. A consequence of this is that a wildly skewed peer
  (decades ahead, for example) drags all other peers forward, effectively
  forcing the entire ensemble to use the new time for the HLC until everything
  catches up. This will devolve into using the counter portion of the HLC until
  the ensemble catches up. The risk of dragging is accepted *except* for counter
  exhaustion, which is described in the [open
  question](#what-about-wildly-skewed-clocks).
- Last writer wins for non-markdown files (PDF, JPG, etc). The same risk is true
  as for CRDTs, and this is known and accepted.

### Membership listings

Any UI peer with writing permission is able to update the membership, either to
remove or add a peer. When it does so, it submits a membership record to the
ensemble recording it. *Only* the UI peer that actually performs the
admission/removal submits this record, never the peer being added or removed.
The intent is that a keeper with the correct permissions is always the
membership updater, and never a possibly stolen device or malicious actor.

Note: A compromised writing peer can still submit a membership record. This is a
[known gap](#should-some-actions-require-a-person-to-be-physically-present).

Membership listings must be verified as coming from writing peers that were
present in the ensemble at the time of the membership listing or update.

### Edit histories and other records

All records that are coming into a given peer are validated against membership
listings. This includes edit histories, membership updates, file data, and
anything else that can possibly travel between peers. If an edit or membership
change or a snapshot was not generated by a writing peer that was considered a
writing peer at the time of the record generation, then it must be rejected and
never stored on the receiving peer. It is not stored, and not examined beyond
that check. Other records are accepted from any current member. The two
boundaries for a given peer are when it joined the ensemble, and when it left
the ensemble.

Edits from before the join are identical to the edits under [Removed
peers](#removed-peers) discussion of what happens to edits while a peer is not a
member of the ensemble, including raising conflict records.

Edits while it is already a member are considered valid.

Edits from the point of removal are not valid without an existing keeper's
approval, and that keeper must be operating a writing peer. The scenario for
these edits is as follows:

- The removed peer's membership removal record is captured by the peer
  performing the removal.
- The edit history of the removed peer is captured as a set of edit ids.
- The set of edit IDs is signed by the peer which performed the removal, *not*
  by the removed peer.
  - When multiple peers issue a peer removal concurrently, the list of edit IDs
    that they generate may be disjoint. Under such circumstances, their list of
    edit IDs is to be brought together as a union, and any edit ID in *either*
    set is considered valid.
- That set of edit IDs is distributed to the ensemble, along with the membership
  removal record.
- All members of the ensemble reject new incoming connections from the removed
  peer from the moment their membership list is updated, preventing new edits
  from coming into the ensemble at all.
- Any edits received from the removed peer that are not in the set of edit IDs
  are handled differently depending on the peer type:
  - UI peer, with writing permission: quarantined locally, not propagated.
    Dependent edits are also quarantined, even when a different member made
    those dependent edits. They are presented to a keeper to accept or reject.
    If accepted, the edits (and any dependent edits) are re-prepared as coming
    from this peer, and then propagated to the network.
  - UI peer, read only: dropped entirely.
  - Headless peer or Blind peer: dropped entirely.
  - This provides an option to preserve the data, without providing a way to
    damage the ensemble. Only specific detached UI peers can be harmed, and that
    risk is preferable to the risk of losing valid data.

### Removed peers

The keeper must be able to tell BrainFrame that a peer is removed from the
ensemble (lost, stolen, reformatted, whatever the reason), so that it will stop
tracking the peer, and therefore allow snapshots to occur without the peer. This
removed peer status must be able to travel to other participants in the engram
as well, so that other devices (or even users) will stop tracking when that
notification arrives. Some consequences of this decision:

- A keeper may remove a peer from the ensemble using a UI peer with writing
  permission. This prevents the use of a headless peer to remove another peer.
- On peer removal and rejoining:
  - A peer may get removed from the ensemble (lost/stolen device, dispute
    between keepers, etc).
    - Side effect: One keeper can remove another keeper from the ensemble
      entirely, and deliberately. The primary data, from the keeper's
      perspective, is unencrypted and unmanaged by BrainFrame. Deleting the
      `.brainframe` folder and re-adopting it from inside of BrainFrame will
      create a new engram, and allows the creation of a new ensemble without the
      other keeper being able to participate in any way. The original ensemble
      will still be intact, and a new ensemble with the same content (but with
      different document and peer IDs) will now exist. Because any keeper can
      always fork in this way, protecting a keeper from removal would not
      prevent one keeper from excluding another. It would only change which one
      of them forks. It is therefore not worth the complexity.
  - A peer may join again after having been removed from participating in the
    ensemble. It will be permitted to rejoin the ensemble by any writing peer.
    As this will require a keeper and UI to permit the rejoin, a headless peer
    has no technical ability to permit the rejoin. Only a UI peer can permit
    the rejoin.
  - The local edit history on the rejoining peer can experience data loss at
    this stage. The data loss possibility is not merely cosmetic: CRDT
    operations can be rejected by the ensemble, and those rejections can cause
    the rejoining device to lose some of the rendered content when new edits
    or snapshots come to the rejoining peer. The data loss possibility is real
    and material to the keeper of the device that is rejoining the ensemble.
  - The protections against this are provided via the UI: when a peer rejoins,
    if a conflict would cause data loss, then the following will happen:
    - After the rejoining peer is readmitted to the ensemble, a conflict record
      is created and transmitted to the ensemble.
    - A UI peer with the writing permission (reading peers cannot do this)
      resolves the conflict, and transmits the result back to the engram as a
      new edit record that contains the resolution of the conflict. Until all
      members of the ensemble accept this new edit, a snapshot cannot be
      established.
    - A rejoining headless peer has no UI, and is therefore unable to manage
      the conflicts. Instead, it will create and propagate the conflict
      records, allowing a UI peer with the writing permission to handle
      resolution of the conflicts.
    - If multiple UI peers with the writing permission resolve the conflict
      differently, then this is an ordinary conflict at this point that CRDTs
      handle and propagate to the ensemble. BrainFrame is already using
      crdt_lf to manage CRDTs, and the FugueText mechanism to avoid
      interleaved edits. Once the edits converge from the ensemble, any keeper
      running a writing peer can then do any final cleanup that is required to
      resolve all of the conflicts.
    - Until the conflict records for the local document are resolved, the
      rejoining peer will keep its local copy of the document intact and
      refuse to overwrite it with any version of the edits that have come in.
    - If the file is *not* a markdown file (PDF, ePUB, JPG, GIF, PNG, etc),
      then the rules change, but only slightly. The rejoining peer has
      introduced an edit that *may* be a conflict. The whole file gets
      distributed to the ensemble as a conflict record, and a UI peer with
      writing permission decides whether to accept or reject the new file.
      Once that decision is recorded, the rejoining peer will be expected to
      honor it, and the file again returns to last writer wins across the
      ensemble.
  - The keeper will have to decide how to handle this scenario, on a
    file-by-file basis. Either new documents have to be made, or local edit
    history is lost. From a user experience perspective, this is less than
    ideal. However, it is still better than having indefinite edit history
    growth.
  - At time of rejoining, the existing peer ID will be allowed back into the
    ensemble, and the peer will normally rejoin as if it was brand new, while
    still using the same peerID that it used before removal (under some
    circumstances, reuse of the peer ID may not be possible, such as a
    reformat). Edit history is then possible to bring in from the rejoining
    peer, minimizing data loss/new document scenarios where possible.
    Permissions (reading vs writing) have to be re-established at the time of
    joining, and the current keys have to be given to the rejoining peer.
    Finally, a rejoining peer must present its edit history to a keeper on a UI
    peer with writing permission. This process occurs outside of the normal
    process, to prevent potentially invalid or malicious data making it out to
    the ensemble. That keeper then gets the option to either accept or revert
    the edit history *before* the rejoining peer returns to the ensemble. Doing
    this makes sure that a peer which is not being manipulated by a malicious
    actor will pass around clean edits to all the other peers.
  - If edits are actually rejected by the keeper performing the readmission,
    then the IDs of those edits must travel to other peers in the ensemble. No
    other peer in the ensemble is allowed to accept the new peer until a
    complete list of rejected edit IDs has been received by that peer. The
    list can be empty, indicating the rejoining peer did not make any known
    malicious edits, but the list must be present on the rejoining record. Any
    edit IDs rejected by this mechanism are permanently retired, and *no* peer
    is allowed to apply them, ever. Doing this prevents a malicious actor from
    gaining a device, producing malicious edits, and then rejoining an
    ensemble (thereby corrupting or even destroying data across the ensemble).
    - This does *not* prevent a malicious actor from waiting until gaining
      membership to the ensemble and *then* performing the malicious edits, and
      it cannot. It only prevents making this edits *before* rejoining the
      ensemble. The ultimate security gate here is always having a keeper verify
      the status of the peer before admitting it to the ensemble.
  - A stolen device cannot be allowed to pollute the ensemble. When a peer is
    removed, the keeper doing the removal will be presented with the
    un-snapshotted history from that peer in a human readable form. The keeper
    will have the option to revert those edits from the peer, and propagate
    those reversions to the ensemble.
  - When a peer rejoins an ensemble, any edit IDs it submits must never repeat
    previously used edit IDs. If the rejoining peer is unable to determine where
    it left off, it is required to join an ensemble with a new peer ID.
    - If a receiver receives a duplicate edit ID (but with different content),
      it must generate a conflict record to the ensemble (instead of trying to
      apply it). The conflict record should only be raised if no other conflict
      record can be found for it locally. If a conflict record for this edit ID
      has already been received, then do not make a duplicate of it. A peer that
      receives such a conflict record and can act on it (eg: a UI peer), must
      assist the keeper in taking actions to resolve the record.
    - It is possible, especially for a malicious actor, to create an edit
      operation that would appear to come before a snapshot, and submit that
      record to the ensemble *after* a snapshot is taken. If a peer receives
      such an edit operation, it must discard that edit operation entirely. It
      is unusable, as the DAG it is attempting to modify no longer exists. It
      cannot even be presented to a keeper in a meaningful way.
  - A removed peer must not be able to exploit this loophole: By communicating
    with a detached peer that has not yet received the updated membership list,
    a removed peer can submit edits to the ensemble. To prevent this, the
    following rules are followed:
    - When the detached peer receives the updated membership list, it checks
      edits that have not yet been committed to a snapshot. Any edits that come
      after the peer was removed are quarantined locally, as described under
      [edit histories](#edit-histories-and-other-records).
    - When edits are quarantined or deleted, any dependent edits will receive
      the same treatment. Deleted edits will see dependent edits deleted, while
      quarantined edits will see their dependent edits quarantined. These are
      considered invalid edits, as they rely on edits that come from a removed
      peer. If the edit is not a dependent edit, but just sits next to a removed
      edit, it needs to be re-anchored to the nearest surviving text. If that
      cannot be accomplished, then a conflict record needs to be raised to allow
      the keeper to fix the edit.
    - The above two rules are applied by every writing peer, just in case an
      edit somehow gets through to non-detached peers. Reading peers are unable
      to re-anchor, as that is a write of its own. Instead, they have to wait
      for a writing peer to address the dependent edits.
    - The local document on the detached peer is rebuilt from the adjusted edit
      history (where applicable, blind peers for instance will be unable to
      rebuild the document), and then any valid edits are passed along to the
      other peers.
    - The above is possible because a removed peer must never be able to cause a
      snapshot after its removal. As a result, the edit history from before the
      invalid edits is still present, and allows the document to be properly
      rebuilt.

### Edits must form a DAG

CRDTs already enforce this property, but the new requirements under the [edit
histories](#edit-histories-and-other-records) show the need for even stronger
guarantees: Each edit must be signed, and each edit's signature must have a
signed and hashed link back to the previous edit in the DAG. Doing this ensures
that we can reject (or raise conflict records for) edits received from removed
peers.

### What's encrypted?

The rendered notes are not kept encrypted at rest on keepers's device. The files
will be kept as plain, unencrypted data outside of the `.brainframe` folder.
This is the desired state of the system, and allows us to hit our goal of making
the data usable for the next 50 years. Encryption is only in place where it is
needed to protect the user's privacy. For example, a service (as defined in the
[README](README.md#glossary)) keeps every engram's content and edit history
encrypted.

Data inside of the `.brainframe` folder will not be encrypted, *except* in the
case of a blind peer. A blind peer, as defined in the
[README](README.md#glossary), is expected to keep as much data as possible
encrypted in the `.brainframe` folder. The membership list can't be kept
encrypted and still validate membership in the ensemble. For other data that
can't be kept encrypted, see this [Scoping Decision](#who-is-out-of-scope).

The third location for data contains this peer's copy of the global edit history
for the engram across the ensemble back to the last snapshot, and this location
is not part of either the keeper's data *or* part of the `.brainframe` folder.
On reading and writing peers, encrypting this data does not make sense. An
attacker who has access to the keeper's account also has the ability to access
the decryption keys, resulting in a trivial attack to get that edit history. On
blind peers, the data for this location will be encrypted, preventing an
attacker from gaining anything more than the encrypted copy.

### Key management

The most painful consequence of having peer removal: Key management is now
confirmed to be in scope. When a peer gets removed, every remaining reading or
writing peer must now get a new key for receiving the data and decrypting it;
blind peers never receive a decryption key. This also means that, once a peer is
removed, it is not able to get the new key *nor* is it able to receive new data
from the engram.

The loss of access is only true after every peer has performed key rotation once
a peer is removed from the ensemble. Until that time, it is possible for a
removed peer to synchronize with a peer that has not been informed of the peer
removal.

An attacker who gains OS level access to a blind peer (or the service) will be
unable to read the data, but will still be able to review (and possibly modify)
the metadata. This specific attack area must be mitigated.

### Peers must defend against pathological edit history

Any individual peer must have a way to reject edits that are harmful to peers
that are in the ensemble. See the open questions for this one: "How to define a
harmful edit". This rule is almost absolute. To clarify it:

- Any reading or writing peer that will render the output of the edit history
  must reject pathological edits.
- Any blind peer that is unable to read the contents of the edit history must
  not drop edits for being unreadable until a peer provides a new snapshot
  that allows it to discard edit history. It cannot provide defense for the
  other peers.

## Open Issues Identified by Claude

Places are named by section and quoted text rather than line number, so the
references survive edits. Remove an item once it is addressed.

### Contradictions

### Decisions still to make

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
- [ ] **E2.** "A blind peer outside snapshotting keeps history longer" is
  mostly answered by the settled rule for blind peers. What is left belongs
  with "How to validate snapshots?".
- [ ] **E3.** "A blind peer that can't read the data can't validate it either"
  and "What about reading members?" overlap. After C1, little of the second is
  left. The second also still says "read-only membership" in its body.
- [ ] **E4.** "How to validate snapshots?" and "How to deal with a malicious
  actor forcing snapshots across the ensemble?" describe the same attack: a
  stolen peer empties or encrypts notes and forces a snapshot. The newer one
  states the root cause better ("a snapshot is destructive of history"). Merge
  them into one question.

### Housekeeping

- [ ] **F1.** The status line still says "nothing is decided yet".
- [ ] **F2.** "This rule is almost absolute": name the exception or drop
  "almost".
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
- [ ] **F11.** Wording in *Settled in review*: "a keeper with the correct
  permissions is always the membership updated" (perhaps "is always the one
  who updates the membership"), and "It only prevents making this edits"
  ("these edits"). The heading "Membership Listings" could match the glossary
  term, **membership list**.
