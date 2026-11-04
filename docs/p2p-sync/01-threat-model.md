# Sync threat model

- **Status:** draft
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

Something unique about BrainFrame: The data the keeper maintains should be
usable in 50 years. All the files should still be visible, and readable. The
internal data (the sqlite databases, the metadata, the CRDT layers) may or may
not be usable within years, but the keeper's data should still be perfectly
usable. This means limiting support to file formats that will survive for that
long. Without any other information, the supported formats are chosen based on
how long they have already survived. If podcasts and video formats stabilize,
then BrainFrame will likely need to support them in future as well.

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
properly synced to multiple peers.

The application will provide peer to peer synchronization over the local
network, while also providing the ability for a headless peer to live outside
the local network. This functionality is the basis for keeping one engram in
sync across all of the peers in the ensemble.

The collection of files that are maintained and visible inside of BrainFrame are
called an engram. The primary file type is Markdown, and editing support for
this file type is provided inside of BrainFrame itself. In addition, BrainFrame
will provide highlighting and annotation support for the common graphics types,
as well as PDFs and ePUBs. All of these file types will have full viewer,
highlight, and annotation support, while only Markdown will have full edit
support.

BrainFrame also maintains a private folder inside the engram, named
`.brainframe`. This folder holds the data about the peers in this ensemble, as
well as engram level metadata. As it is part of the engram, it will travel with
the engram wherever the rest of the files go.

Finally, there is a database that lives outside of the engram that contains the
information for the conflict-free replicated data types that enable the merge
across peers to be automatic.

### What sync does

Sync keeps one engram the same on every peer that holds it. An edit made on one
peer reaches the others, and edits made on two peers at the same time are merged
rather than one overwriting the other.

BrainFrame does not have sync yet. Today, a person who wants an engram on two
devices puts the folder in a file-sync tool of their own (iCloud Drive,
Dropbox, Syncthing, git), and BrainFrame notices the files that change. Sync
built into BrainFrame replaces that tool for the people who want it, and it
exchanges the edit history, which a file-sync tool cannot do.

To do that, sync has to move between peers:

- the **notes** themselves, as CRDT operations;
- the **documents** a person reads, as files;
- their **markup**: highlights, annotations, and handwriting;
- the **structure** of the engram: which notes exist, their paths, and what
  links to what;
- the **identity map**: the id of each note, and the name of each peer.
- the **public key**: the public key of each peer in the engram

### Why it is worth protecting

A second brain is a record of how one person thinks. That makes it worth more to
an attacker, and its loss worse for its keeper, than most collections of files:

- **It is personal by design.** People write in it what they write nowhere
  else: journals, health, money, relationships, half-formed ideas, work they
  have not shown anyone. The point of the app is that it is all in one place.
- **The whole says more than any part.** The links between notes, the tags,
  and the folder names map what a person cares about and how the parts of
  their life connect. Someone who reads none of the notes, but sees only
  their titles and links, still learns a great deal.
- **It remembers what was deleted.** The edit history is kept so that edits can
  be merged. Text a person deleted, because they regretted writing it, is still
  in that history, and sync carries the history to every peer.
- **What someone reads, and what they mark, is revealing too.** The
  documents in an engram, and the passages highlighted in them, say what a
  person is studying, worried about, or planning.
- **Its keeper relies on it as memory.** A note that was silently changed is
  worse than one that was lost, because the person trusts it and acts on it.
- **Sync spreads mistakes.** Without sync, a corrupted or deleted note is
  lost on one peer. With sync, it can be lost on every peer at once,
  including the one that would have been the backup. Sync therefore has to
  protect against damage as well as against reading.

### Scoping decisions

These have to be settled first. Every later section depends on the answers.

#### Who shares an engram?

An engram starts its existence on a single machine for a single keeper. Over its
lifetime, it is expected to grow to be shared on multiple devices owned by a
single keeper. The ultimate expansion is for the keeper to allow other people
(and their devices) to join the engram as keepers and peers. The initial scope
is small, but the ultimate scope is to allow the keeper to share with others.
BrainFrame does not guarantee the ability to remove the engrams from devices,
only to stop sharing new edits with specific peers.

#### Is there a server?

Only in the loosest sense of the word. A server, even one on the open internet,
is simply another peer. Since it's on the internet, or on a local NAS, it will
be a headless peer, but it is not a server in the traditional sense of the word.

#### Is there a service that can handle multiple keepers' engrams?

Eventually, yes. This is as close to an actual server as BrainFrame will ever
provide. This is also likely to be a paid service when it happens.

Notes about the service:

Ownership of an engram in the service is defined by an account identifier, such
as a GMail account or billing information. Any actions to be taken by an
administrator of the service must confirm ownership of that engram before
proceeding.

Ownership of an engram *outside* of the service is not a recognizable concept.
Every keeper effectively owns the copy of the engram stored on their devices. No
keeper is allowed to reach into another keeper's devices and remove the engram
from the other keeper.

#### Where does sync reach?

Sync will reach for local network first, and it will have the option of using a
hosted service on the open internet. When using something on the open internet,
it will need to have configuration options to ensure that BrainFrame can find
that peer.

#### What happens when a device is lost or stolen?

The peer can be removed from the membership list of the ensemble. This does not
remove the copy of the engram from that device. It only prevents getting new
history onto the peer. Removing existing history and notes would create the risk
of losing all of a keeper's notes, and that is an unacceptable risk.

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
  behalf of the keeper(s). Some data will still be exposed, including the
  membership list, number of peers, their peerIDs, potentially their IP
  addresses, arrival times and sizes of edits, and how they're ordered relative
  to each other and any snapshots. Where possible, we need to reduce the risk of
  data exposure.
- Explicitly in scope: Using a stolen device to manipulate an engram before the
  proper keeper can remove the peer on the stolen device from that engram. This
  has a race condition, and the race exists *unless* membership changes are
  gated:
  - Attacker steals a device
  - Before the keeper of the device realizes the theft has occurred, the
    attacker removes all other peers from the engram.
  - When this happens, the proper keeper is locked out of the engram. On a
    self-hosted headless peer (regardless of type: reading, writing, or blind),
    the keeper can delete the peer's data from disk and create a new headless
    peer and engram set.
    - On a self-hosted blind peer, the plaintext of the keeper's files was never
      present, so deleting and recreating loses nothing from the keeper's peers.
    - On the service, tools must exist to allow administrators to delete an
      entire engram so the account owner can recreate it.
    - Additional side effect: Service administrators/operators are now an attack
      vector, and could cause an engram keeper to be forced to recreate their
      engram on the service. The attack models must account for this.

### Scope

What this threat model covers, and what it leaves to other documents.

### Data-flow diagram

A Mermaid diagram of the peers, any server, the data stores, and the
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

For example: pairing a new peer, removing one, or changing who can read an
engram, authorized by a tap on a hardware key rather than by anything a
compromised peer could do alone. An OpenPGP smart card (such as a YubiKey) is
one way to do it; FIDO2 is another, with wider support on phones. This is a
mechanism, so it is chosen in [document 6](06-brainframe-protocol.md). Here the
question is only whether the threat model asks for the property, and for which
actions.

We need to have a mechanism to prevent a stolen peer from taking over an
ensemble. Right now, as stated, any writing peer can remove any other peer. We
should provide options to the keeper to manage this, including the idea of
requiring something like a YubiKey or a passkey or a Fido2 key. Additionally,
removal and rejoining needs to be protected somehow.

### A blind peer outside snapshotting keeps history longer

If the blind peer can't validate the data, then a safe mechanism must be
provided to allow the blind peer to discard edit history after new snapshots get
made. This mechanism is not yet defined, but must be.

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

### Attacks on a blind peer

- Related [open question](#how-to-define-a-harmful-edit)
- Related [open
  question](#how-to-define-useful-file-size-limits-record-size-limits-etc)

Blind peers are susceptible to attacks that other peers are not, and the
consequences of those attacks can be more harmful to the ensemble. Possible
attacks include:

- Sending in extremely large individual edits
- Sending in millions of small edits
- Undecryptable garbage - an edit that provides everything *except* a valid
  payload
- Forced divergence - sending a blind peer one edit, while sending other peers a
  different edit with the same ID
- DDOS variant - opening connections and never completing signature
  verification, burning CPU cycles before letting the peer close the connection
- Eclipse - causing the blind peer to become a detached peer, and coercing
  communication only with the malicious actor
- Replay - re-sending an existing record (especially a membership record), and
  causing the blind peer to accept it and add it to the ensemble.
- Cross-ensemble replay - taking a record for one ensemble and submitting it to
  another ensemble.
- Noisy neighbor - One engram exhausts bandwith or storage on a shared system
- Free hosting - A keeper uses the encrypted storage to host illegal data (such
  as CSAM), which carries legal implications

### How to define a harmful edit?

Related [open
question](#how-to-define-useful-file-size-limits-record-size-limits-etc).

Also related: [attacks on blind peers](#attacks-on-a-blind-peer).

An edit is harmful under a number of different circumstances, with the most
obvious one being the case where a future restart will actually be prevented due
to the system running out of memory or taking too long to consume the edit and
produce a meaningful result. Further research is needed to define the harmful
edit cases, and then provide the actual defense against them. Note that the same
definition of harmful edit must be applied to *all* peers, whether they are
running on a server with multiple terabytes of RAM or a single Raspberry Pi Zero
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

### How to deal with a malicious actor forcing snapshots across the ensemble?

A malicious actor, stealing a peer, can take over and do a number of things to
destroy the ensemble. The most obvious is to empty out every note, force a
snapshot, and propagate that snapshot. Other malicious edits would involve
encrypting the data, and pushing that encrypted data out as a snapshot. The
dominant factor here is that a snapshot is destructive of history, and a
malicious actor could easily force that snapshot and propagation. Need to
determine a method for dealing with those actions.

### How to define useful file size limits, record size limits, etc?

Related [open question](#how-to-define-a-harmful-edit).

Also related: [attacks on blind peers](#attacks-on-a-blind-peer).

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
conflict records that could overwhelm peers with malicious edits.

Limits on total quantity of records need to be implemented. A compromised peer
could generate millions of small edits that could bring down the ensemble. A
single document, for example, could insert the letter `a` 10,000 times (each in
their own edit), and then delete each of them, and repeat that process
100,000,000 times before trying to synchronize with the ensemble. This would
likely bring down even the most powerful desktops running BrainFrame.

Transmission of files as a whole must also be guarded. For example, on Linux, a
symbolic link to /dev/zero would result in a file that has unlimited size. Files
will need to be strictly regular files (no sockets, no symbolic links, no pipes,
etc), with their maximum size small enough to be usable on the e-Ink device, and
streamed rather than received whole. The maximum size must work for *all*
platforms, from the e-Ink device all the way up to the desktop, so the maximum
size is actually a constant across all peers.

We need to define useful limits that won't prevent people from storing the files
that they want to store in the engram, but also will not overwhelm the smallest
devices and only be usable on the most powerful desktops.

### What about metadata on blind peers?

With key management being in scope, and blind peers being a requirement, the
exposed metadata on a blind peer (especially as it relates to the service)
leaves attack surface, specifically the area of traffic analysis.

Related to the history, we need to list the metadata that is needed for blind
peers to function. A partial list of all metadata includes the following:

- membership list
- peer count
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

### What about conflicting bootstrapping records?

An ensemble needs a bootstrapping record for the first peer in an ensemble. If
multiple peers claim to bootstrap the ensemble, then the last one(s) to join the
ensemble are rejected, and must drop their bootstrapping record to join the
ensemble.

The question here is how to establish that bootstrapping record properly, so
that only one peer in the ensemble can actually claim it.

This question can be closed once the mechanism for guaranteeing the
bootstrapping record will only exist once per ensemble has been defined.

## Settled in review

Decisions made in review, with the reasoning, so they are not argued again.

### Clocks cannot be trusted

No device's clock may be used to form the basis of a trust decision. Attackers
can manipulate their local clock, or submit edits where the hybrid logical clock
references timestamps that were not actually accurate. Most Raspberry Pi devices
do not have a hardware clock, and can become out of sync with internet clocks
easily. A desktop or laptop can get time from an untrusted source. Mobile
devices can have their time be manipulated by the keeper manually changing it,
or even just due to a misconfigured time server.

Clock times are not reliable, and cannot be used to determine an actual trust
relationship in any way. This has direct impacts on how to determine if a
removed peer has the ability to submit an edit to the ensemble, and is therefore
called out here.

For non-trust based choices, clocks are acceptable.

- CRDTs use Hybrid Logical Clocks. These are susceptible to attacks based on
  concurrent edits, but the risk here is that one peer will always win in a
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
membership updater, and never a possibly stolen peer or malicious actor.

Note: A compromised writing peer can still submit a membership record. This is a
[known gap](#should-some-actions-require-a-person-to-be-physically-present).

Membership listings must be verified as coming from writing peers that were
present in the ensemble at the time of the membership listing or update.

Membership listings are the exception to the snapshot rules. They must be kept
indefinitely, as they determine what edits are valid, when they are valid, and
which peers are allowed to make the edits. As such, it is important to keep the
membership records as small as possible, while still keeping them complete. This
is the one record we cannot afford to lose from BrainFrame's internal data.
Because we cannot keep thousands (or more) edit IDs forever without consuming
unreasonable amounts of storage space, we should store the public keys and
associated peer IDs in a separate table.

### Read Only Membership

The membership list, coupled with key distribution and signatures, covers the
scenarios for read only members, whether UI, headless, or blind.

A given peer publishes a public key to the ensemble, and everything it does is
signed before it gets sent to another peer. Any unsigned items are rejected
during the synchronization process, protecting the receiving peer (and, in turn,
protecting the ensemble).

A peer is designated as read or write when it joins the ensemble by the keeper
admitting the peer to the ensemble. These details are part of the joining
process, and any record that does not include the necessary parts is incomplete
and rejected by the ensemble. The necessary parts of the record:

- The peer ID of the joining member
- The permission level of the joining peer
- The peer ID of the peer used to approve the join
- The prior membership record for the peer used to approve the join
  - This is used to create a DAG and enforce history.
  - The prior record could be the record of its own joining to the ensemble
  - The first record presents a circular loop, since there is no parent record.
    As a result, the first record will be a designated bootstrapping record for
    the ensemble. If a peer tries to join an ensemble and has its own
    bootstrapping record for that ensemble already, the peer will be rejected.
  - A new attack vector (and [open
    question](#what-about-conflicting-bootstrapping-records)) comes from this.

Blind peers can also use this mechanism to protect themselves. Using it, they
can reject writes from read-only peers as well as reject any connections (and
any edits from those connections) from non-peers.

### A blind peer can validate membership

A blind peer can validate that incoming connections and edits are from valid
writing peers. See [membership listing](#membership-listings) and [read-only
membership](#read-only-membership).

What remains is how to have a blind peer reject a harmful actions from a
malicious currnt peer, such as over-sized edits, flooding the ensemble, etc.
That is an [open question](#attacks-on-a-blind-peer).

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

Note that the public key of a peer must remain with that peer's membership
records, both admission and removal. It is required to validate incoming records
from that peer.

Edits from before the join are identical to the edits under [Removed
peers](#removed-peers) discussion of what happens to edits while a peer is not a
member of the ensemble, including raising conflict records.

Edits while it is already a member are considered valid.

Edits from the point of removal are not valid without an existing keeper's
approval, and that keeper must be operating a writing peer. The scenario for
these edits is as follows:

- The removed peer's membership removal record is captured by the peer
  performing the removal.
- The edit history (and the content hashes of those edits) of the removed peer
  is captured as a set of edit ids.
- The set of edit IDs and content hashes is *not* signed by the removed peer.
  - When multiple peers issue a peer removal concurrently, the list of edit IDs
    and content hashes that they generate may be disjoint. Under such
    circumstances, their list of edit IDs and content hashes is to be brought
    together as a union, and any edit ID + content hash pair in *either* set is
    considered valid.
    - Exception: If a duplicate ID arrives with a *different* hash, then all
      edits with that ID are quarantined until a keeper can resolve which one is
      valid.
- The removal record gets a unique ID and the full set of edit IDs and content
  hashes, and generates a set of document removal records for the ensemble,
  with each record having the following entries:
  - The document ID
  - The set of edit IDs and content hashes attached to that document ID
  - The peer ID of the removed peer
  - The peer ID of the removing peer
  - The unique ID of the membership removal record
  - A signature from the removing peer that signs the contents of the whole
    record.
- The removal record also gets a signed set of the hashes of the document
  removal records. The links run one way by ID and the other by hash, since two
  records cannot each contain the other's hash.
- That set of edit IDs is distributed to the ensemble, along with the membership
  removal record.
- All members of the ensemble reject new incoming connections from the removed
  peer from the moment their membership list is updated, preventing new edits
  from coming into the ensemble at all.
- Any edits received from the removed peer that are not in the set of edit IDs
  (including the content hashes for those edit IDs) are handled differently
  depending on the peer type:
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
- After a new snapshot has been generated for a given document, the set of edit
  IDs + content hashes from before that snapshot can be dropped. Those edit IDs
  are now rejected by the earlier rules causing such edits to be rejected as
  invalid, since they have no valid place in the DAG.

### Removed peers

The keeper must be able to tell BrainFrame that a peer is removed from the
ensemble (lost, stolen, reformatted, whatever the reason), so that it will stop
tracking the peer, and therefore allow snapshots to occur without the peer. This
removed peer status must be able to travel to the rest of the ensemble as well,
so that other peers (including other keepers) will stop tracking when that
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
    the rejoining peer to lose some of the rendered content when new edits
    or snapshots come to the rejoining peer. The data loss possibility is real
    and material to the keeper of the peer that is rejoining the ensemble.
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
    complete list of rejected edit IDs has been received by that peer. The list
    can be empty, indicating the rejoining peer did not make any known malicious
    edits, but the list must be present on the rejoining record. Any edit IDs
    rejected by this mechanism are permanently retired, and *no* peer is allowed
    to apply them, ever. Doing this prevents a malicious actor from gaining a
    device, producing malicious edits, and then rejoining an ensemble (thereby
    corrupting or even destroying data across the ensemble).
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
    - Each edit must include a hash of its content, with the hash being part of
      the content that is verified by the signature on the edit. A removed peer
      submitting an edit record to the ensemble that is a duplicate id but with
      a different hash gets the record rejected outright: the record is never
      stored, and never forwarded to the ensemble. Otherwise, the normal
      duplicate edit rule applies from above.
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

The rendered notes are not kept encrypted at rest on the keeper's device. The
files will be kept as plain, unencrypted data outside of the `.brainframe`
folder. This is the desired state of the system, and allows us to hit our goal
of making the data usable for the next 50 years. Encryption is only in place
where it is needed to protect the keeper's privacy. For example, a service (as
defined in the [README](README.md#glossary)) keeps every engram's content and
edit history encrypted.

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
harmful edit". To clarify it:

- Any reading or writing peer that will render the output of the edit history
  must reject pathological edits.
- Any blind peer that is unable to read the contents of the edit history must
  not drop edits for being unreadable until a peer provides a new snapshot
  that allows it to discard edit history. It cannot provide defense for the
  other peers.

## Open Issues Identified by Claude

Places are named by section and quoted text rather than line number, so the
references survive edits. Remove an item once it is addressed.

### Reference: trust models and methods

Two separate lists, kept here for filling in the tables. They answer different
questions: the models say who is trusted and how much, and the methods are the
tools applied to each model.

**Trust models** (who is trusted, and how much). The doc combines these; the
names are the standard ones, not terms it has defined.

- **Trusted endpoint.** Reading and writing peers on a keeper's own hardware.
  Anyone with the keeper's account is out of scope; attacks on BrainFrame
  itself, such as privilege escalation, are in scope. See the first bullet of
  [Who is out of scope?](#who-is-out-of-scope).
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
  in RFC 3552's terms. N25, local-network discovery, belongs here.

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

### Contradictions

### Decisions still to make

- [ ] **N23. Device count and peer count are separate leaks.** The list in
  "What about metadata on blind peers?" changed "device count" to "peer
  count". Within one ensemble a blind peer sees peers, but a service hosting
  several engrams for the same keeper can also tell which peers sit on the
  same *device*, from shared IP addresses and timing, and so link that
  keeper's engrams together (linkability, in LINDDUN terms). Keep both items
  in the list.
- [ ] **N24. A file-sync tool running alongside BrainFrame sync bypasses
  every membership rule.** "What sync does" says built-in sync "replaces that
  tool for the people who want it", but nothing says the two may not run at
  once. If a keeper leaves the engram in Dropbox, iCloud Drive, or Syncthing
  *and* turns on BrainFrame sync, the file-sync tool becomes a second channel
  that no membership list, signature, or removal governs:
  - **It launders a removed peer's edits.** A stolen laptop that is still
    signed in to Dropbox writes changed files into the shared folder. On each
    honest device, BrainFrame sees a file change on disk, treats it as a local
    edit, and signs it as that device's own. The removed peer's edit is now a
    valid edit from a current member, past every rule in "Edit histories and
    other records".
  - **It duplicates edits.** One change, delivered both by BrainFrame sync and
    by the file-sync tool, can be turned into CRDT operations twice, once on
    each device that sees the file change.
  - **It carries `.brainframe/`.** The membership list and device names travel
    to wherever the file-sync tool copies the folder ("What BrainFrame Is":
    "it will travel with the engram wherever the rest of the files go").

  Decide whether BrainFrame detects a file-sync tool and refuses to turn sync
  on, warns and lets the keeper accept the risk, or treats file changes it did
  not see being made as untrusted.
- [ ] **N25. Local-network discovery is a metadata leak with no question.**
  [Where does sync reach?](#where-does-sync-reach) says sync works "for local
  network first". Finding peers on a local network usually means announcing
  them (mDNS or a broadcast), and anyone on the same café or hotel Wi-Fi then
  sees that a BrainFrame peer is present, and possibly its device name (the
  identity map already publishes device names) and peerID. That is
  identifiability and detectability in LINDDUN terms. "What about metadata on
  blind peers?" covers only what a blind peer sees, so nothing covers what the
  network sees. Add it there, or as its own question.
- [ ] **N26. Nothing bounds history growth while a member is detached.** By
  the README's *Detached peer* entry, "no snapshots are possible" until a
  detached peer reconnects or is removed. A phone left in a drawer for six
  months therefore stops every peer from discarding history for six months.
  On the smallest device, about 448 MB for the whole app, that history can
  outgrow what the device can hold. A member that deliberately never reaches
  the snapshot point has the same effect on every peer, blind ones included.
  Decide whether a long-detached member is
  flagged to a keeper for removal after some period, whether history is
  bounded some other way, or whether the growth is accepted as residual risk.
- [ ] **N27. How does a new peer trust what it receives when it joins?** A
  new peer starts from a snapshot and a membership list handed to it by the
  peer that admits it. It cannot check the history before that snapshot, and
  it has no earlier membership list to check signatures against. So a
  compromised admitting peer could give it a false snapshot or a false list.
  This is trust on first use, usually settled at pairing (a code or QR
  compared by a person, as with Signal's safety numbers). State what a new
  peer must verify at join, and what it must take on trust. "Read Only
  Membership" now answers part of this: a new peer can walk the membership
  chain back to the bootstrapping record, so what is left to trust is that
  record (see E8).
- [ ] **N28. Changing a peer's kind is not covered.** "Membership listings"
  covers adding and removing a peer, but not changing what kind a member is:
  promoting a reading peer to writing, or demoting a writing peer to reading.
  The first is as sensitive as adding a writer; the second is like a removal
  of writing rights, and under "Edit histories and other records" it needs the
  same two bounds (edits signed as a writer are valid only up to the
  downgrade, by the same signed set). State that kind changes follow the same
  rules as membership changes, and that a downgrade commits to the set of
  writing edits it accepts.
- [ ] **N29. The join record is missing what makes it checkable.** "Read Only
  Membership" lists "the necessary parts of the record", and chaining each
  record to its approver's prior record is a strong design: a peer can walk
  the chain back to the bootstrapping record. Three things are missing:
  - **The joining peer's public key.** Without it, nothing the new peer signs
    can ever be verified.
  - **The approving peer's signature over the record.** Naming the approver's
    peer ID proves nothing, since anyone can type an ID.
  - **The other membership records.** The chain covers joins. Removals, kind
    changes (N28), and rejoins have to be links in the same chain, or a peer
    walking it would see a removed peer as still a member.
- [ ] **N30. "The last one(s) to join" cannot decide a bootstrapping conflict.**
  "What about conflicting bootstrapping records?" says that with several
  bootstrapping records, "the last one(s) to join the ensemble are rejected".
  Deciding who was last needs a clock, or an order the peers do not share, and
  "Clocks cannot be trusted" rules out the first. Two peers cut off from each
  other would each see the other as last. One direction for the question: make
  the ensemble's identity the **hash of its bootstrapping record**, the way a
  git repository's history is anchored by its first commit. Two bootstrapping
  records are then two different ensembles by definition, and there is no
  conflict to resolve inside one. Joining means naming that hash, which pairing
  has to convey anyway. What remains is the fork case: two ensembles for the
  same folder, which is the outcome "Removed peers" already accepts.
- [ ] **N32. The service account links a real identity to an engram.** [Who is
  out of scope?](#who-is-out-of-scope) now defines ownership on the service by
  "an account identifier, such as a GMail account or billing information". Two
  consequences to record:
  - **It is metadata, and the most identifying item yet.** The next bullet sets
    the goal of "minimal knowledge" for blind peers, and "What about metadata
    on blind peers?" does not list account details. A service that knows whose
    account holds an engram can tie every other item on that list (timing,
    sizes, IP addresses) to a named person. Add it to the list, with the
    mitigation question: how little identity can the service hold, and can
    billing be separated from the engrams it pays for?
  - **The account is now an attack path.** Whoever takes over that account, or
    talks support into believing they own it, can have the engram deleted from
    the service. The keepers' local copies survive, so the harm is limited,
    but it belongs in the Adversaries table with the service operator.

### Overlapping open questions

Brought up to date on 2026-11-04, after E1, E2, E3, and E5 were closed.

- [ ] **E4. Three questions cover forced snapshots, and settled rules answer
  part of each.** "How to validate snapshots?", "How to deal with a malicious
  actor forcing snapshots across the ensemble?", and part of "A blind peer
  outside snapshotting keeps history longer" (the stolen writing peer sending a
  blind peer an empty snapshot) all describe a peer forcing destruction through
  a snapshot. The doc has since settled:
  - snapshots must come from a peer that was a writing peer at the time
    ("Edit histories and other records");
  - everything a peer sends is signed, and unsigned items are rejected ("Read
    Only Membership");
  - a snapshot is a point "as seen across the ensemble" (README *Snapshot*),
    so every member must have reached it;
  - a removed peer can never cause a snapshot after its removal ("Removed
    peers").

  So a *forged* snapshot is already refused, and "How to validate snapshots?"
  still opens by saying "the attacker can force a new snapshot", which is no
  longer the whole picture. What remains is narrower, and worth one merged
  question: a stolen peer that is still a writing member makes ordinary
  vandalising edits (emptying or encrypting notes), the ensemble then agrees a
  legitimate snapshot, and the vandalism becomes permanent before any keeper
  notices and reverts it. That is a question of how long history is kept before
  a snapshot may discard it, so a keeper has time to catch damage. Merge the
  first two into one question on that, and leave "A blind peer outside
  snapshotting keeps history longer" to cover only what a blind peer must see
  to purge safely.
- [ ] **E8. Bootstrapping and joining are one trust question.** "What about
  conflicting bootstrapping records?" asks how an ensemble's first record is
  established. N27 asks what a new peer must verify when it joins, and N30 asks
  how a conflict between first records is decided. All three end at the same
  place: the membership chain in "Read Only Membership" can be walked back to
  the bootstrapping record, so a new peer's only leap of faith is that record.
  Fold N27 and N30 into the bootstrapping question, so one answer covers what
  anchors an ensemble and how a new peer learns it.

### Housekeeping

Brought up to date on 2026-11-04. Line numbers are as of that date, and the
quoted text is the reliable way to find each spot.

- [ ] **F5. Scoping decisions still give answers without reasons.** [Who
  shares an engram?](#who-shares-an-engram), [Is there a
  server?](#is-there-a-server), [Is there a service that can handle multiple
  keepers' engrams?](#is-there-a-service-that-can-handle-multiple-keepers-engrams),
  and [Where does sync reach?](#where-does-sync-reach) each state a decision
  but not why; *Settled in review* promises the reasoning so decisions are not
  argued again. Much of it now exists elsewhere in the doc and only needs a
  sentence each. For example, "Is there a server?" follows from the blind
  peer and "Who is out of scope?" (a server that is just another peer, and
  cannot read, is what makes the service safe to offer).
- [ ] **F6. One sentence still says deleted text stays forever.** `:116`, "It
  remembers what was deleted": "Text a person deleted… is still in that
  history". Since the README's *Edit history* entry, history runs only back to
  the last snapshot, so deleted text stays until the next snapshot discards
  it. ("What sync does", "exchanges the edit history", at `:91` is accurate
  as it is; the earlier version of this entry listed it too.)
- [ ] **F11. Two wording points left.** `:759`, under "Removed peers": "It
  only prevents making this edits" ("these edits"). And the heading at `:554`
  is "Membership listings", while the glossary's term is **membership list**;
  "Membership list" would match. ("Membership updater" is fixed.)
- [ ] **F12. "Edits must form a DAG" says "the previous edit" again.** `:817`:
  "a signed and hashed link back to the previous edit in the DAG". An edit in
  a DAG can build on several edits at once, and an earlier version of this
  sentence said "the parent edits". "To each edit it builds on" is the exact
  form.
- [ ] **F13. "Key management" ends on an attack with no pointer.** `:863`:
  "This specific attack area must be mitigated". The open questions "What
  about metadata on blind peers?" and "What about history attacks against
  blind peers?" now cover it; linking to them says where the mitigation is
  being worked out.
- [ ] **F14. The merged physical-presence question has one stale phrase.** Its
  second paragraph (`:268`) says "any writing peer can remove any other peer".
  "Membership listings" and "Removed peers" limit that to a writing *UI* peer.
  The real gap is narrower: a compromised writing peer can still submit a
  membership record, because a receiver cannot tell a UI peer from a headless
  one.
- [ ] **F15. "Read Only Membership" wording** (`:569`).
  - The heading and text say "read only" and "read or write". The glossary's
    terms are **reading peer** and **writing peer**.
  - "Read only members, whether UI, headless, or blind": a blind peer is its
    own kind, since it cannot read at all. The membership list records
    reading, writing, or blind, so the section's rule covers all three.
  - Lint: the bullet starting "As a result, the first record" is one 220-column
    line (MD013) and will block a commit.
- [ ] **F17. "Attacks on a blind peer" needs two touches.** `:303` opens "Blind
  peers are susceptible to attacks that other peers are not", but only two on
  its list are unique to them: undecryptable garbage and forced divergence,
  which follow from being unable to read. The others hit any peer and are worse
  on a blind one, because it is always on and reachable or shared. "Blind peers
  are more exposed to these attacks, and two are unique to them" is exact. It
  also has no closing condition, which the other recent questions do: for
  example, closed once each listed attack has a defence, or is accepted as
  residual risk.
- [ ] **F18.** Two typos in "A blind peer can validate membership" (`:607–608`):
  "a harmful actions" and "currnt".
- [ ] **F22. The two links cannot both be hashes.** The document edit records
  carry "a link to the membership removal record", and the removal record gets
  "a signed set of links to the document removal records". If both are hashes,
  each record's hash depends on the other, and neither can be computed. N36
  suggested a hash in both directions; that was wrong. One direction has to be
  an identifier: give the removal a unique ID first, have each document record
  name that ID, and have the removal record list the document records' hashes.
  The text also calls them both "document edit records" and "document removal
  records"; one name is enough.
