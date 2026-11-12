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

To accomplish the goals, sync has to move between peers:

- the **notes** themselves, as CRDT operations;
- the **documents** a person reads, as files;
- their **markup**: highlights, annotations, and handwriting;
- the **structure** of the engram: which notes exist, their paths, and what
  links to what;
- the **identity map**: the id of each note, and the name of each peer.
- the **public key**: the public key of each peer in the engram

#### File synchronization tools

Keepers will need to choose one mechanism or another, not both. If BrainFrame
can detect that a second sync method is in use, it must warn the keeper of the
potential problems, including the following:

- A lost or stolen device must be disabled in multiple places: the file sync
  service *and* BrainFrame.
  - The file sync service will provide a new copy of the file, BrainFrame will
    see the edits and treat them as local edits, and the edits will duplicate
    across the ensemble.
  - A removed peer can edit the document, and the file sync service will copy
    the results to another peer. That peer then will add and sign the edits and
    distribute them to the ensemble.
- The file sync service will carry the contents of the `.brainframe` folder in
  whole, potentially leaving artifacts like a sqlite journal file in place to
  create conflicts on other peers.

The protocol details for this section are in the [protocol document](06-brainframe-protocol.md#file-synchronization-tools).

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
| ADV1 | Remote Account Attackers | Can take over accounts (such as GMail); request the service to delete the engram | Decrypt data held on blind peer or the service |
| ADV2 | BrainFrame Service Account Attackers | Social engineer service administrators | Decrypt data held on the service |
| ADV3 | Service Administrators | Can delete any data | Decrypt data held on the service |
| ADV4 | Thief with a stolen device | Read what's on it, act as that writing peer until removed | Forge other peers' signatures; read anything after key rotation |
| ADV5 | Compromised writing peer | Make valid but malicious edits; submit membership records | Sign as other peers; escape removal |
| ADV6 | Hostile keeper | Remove other keepers; fork the engram | Delete anyone's local copy |
| ADV7 | Removed peer | Read what it already holds; sign with its old key | Get new keys; get edits outside the removal accepted |
| ADV8 | Compromised blind peer (host access) | See metadata; withhold, delay, or delete records | Read contents; forge records |
| ADV9 | Network attacker, on-path | See traffic and discovery broadcasts; drop or delay packets | Read encrypted content; forge signed records |
| ADV10 | Network attacker, off-path | Connect to peers ; flood them ; answer discovery as a fake peer | Get past signature checks |
| ADV11 | Lower-privileged app on the same device | Try to use BrainFrame to escalate privileges | Read the keeper's files (if the OS is sound) |

### Assumptions

| ID | Assumption | If it is false |
| --- | --- | --- |
| AS1 | The OS of a keeper's device is not compromised | Attacker has full access to all keys, and can do anything inside the engram/ensemble |

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
| NG1 | Do not protect against file-sync tools | Keepers may use this as a backup mechanism |
| NG2 | Do not protect the whole device and OS from attacks | This is impractical, and likely to conflict with keeper desires for how they manage their security |

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

- account identifiers, such as an email address
- membership list
- peer count
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

Additional (related) question: Can we separate billing information on the
service somehow? While unlikely, we should explore this. We have to limit the
amount of data and bandwidth a given customer stores, and bill them
appropriately. The costs for storing and transmitting 50M per month are
noticeably different from storing and transmitting 50T per month. Somehow, we
have to track the individual customer usage, and (ideally) not expose that
information if an attacker gets access to the data. Again, we need to minimize
the connections and the exposed metadata as much as possible, and this paragraph
is about trying to make sure we do so.

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

### What about metadata on a local network?

In ["Where does sync reach?"](#where-does-sync-reach),the use of the local
network as the first location for syncing is brought up.

This invites an information discovery attack: the local network will typically
use mDNS or a broadcast. Any listeners on the same network will find, at barest
minimum, a service that listens. Depending on the local network broadcast
method, this can then include that this is BrainFrame, the version of
BrainFrame, the peer ID, and even the device name.

We need to have the mechanisms known and mitigated as much as possible.

This question can be closed when the complete list of metadata that must be made
visible is known, along with the justifications for why that metadata must be
broadcast, and how it gets broadcast.

#### What about attacks after the broadcast?

A stable entity being announced (such as an engram ID, or a peer ID) allows an
attacker to track this device across networks. If any such information is
included in the broadcast, it must be strongly justified.

Anybody on that network can answer, claiming to be a peer. The public key
signatures and membership lists will deny access, but that still will use up
compute resources that should go to a legitimate peer.

This question can be closed when either mitigations have been defined, *or* when
the risks have been accepted as un-mitigatable (with stated reasons why they
can't be mitigated).

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

Blind peers can also use this mechanism to protect themselves. Using it, they
can reject writes from read-only peers as well as reject any connections (and
any edits from those connections) from non-peers. One exception to the rejection
exists: When an invitation exists for a current non-peer, that connection is
allowed to propagate an invitation acceptance record.

The protocol details for this section are in the [protocol document](06-brainframe-protocol.md#read-only-membership).

### A blind peer can validate membership

A blind peer can validate that incoming connections and edits are from valid
writing peers. See [membership listing](#membership-listings) and [read-only
membership](#read-only-membership).

What remains is how to have a blind peer reject a harmful action from a
malicious current peer, such as over-sized edits, flooding the ensemble, etc.
That is an [open question](#attacks-on-a-blind-peer).

### Edit histories and other records

All records that are coming into a given peer are validated against membership
listings. This includes edit histories, membership updates, file data, and
anything else that can possibly travel between peers. If an edit or membership
change or a snapshot was not generated by a writing peer that was considered a
writing peer at the time of the record generation, then it must be rejected and
never stored on the receiving peer. It is not stored, and not examined beyond
that check. Other records are accepted from any current member. The only
exception to this is an invitation acceptance record, which comes from a current
non-peer. As long as the acceptance is attached to a current (valid) invitation
record, the acceptance record is allowed to propagate. The two boundaries for a
given peer are when it joined the ensemble, and when it left the ensemble.

Edits from before the join are identical to the edits under [Removed
peers](#removed-peers) discussion of what happens to edits while a peer is not a
member of the ensemble, including raising conflict records.

Edits while it is already a member are considered valid.

The protocol details for this section are in the [protocol document](06-brainframe-protocol.md#edit-histories-and-other-records).

### Conflict records and agreement records

This section has moved to the [protocol document](06-brainframe-protocol.md#conflict-records-and-agreement-records).

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
  - The keeper will have to decide how to handle this scenario, on a
    file-by-file basis. Either new documents have to be made, or local edit
    history is lost. From a user experience perspective, this is less than
    ideal. However, it is still better than having indefinite edit history
    growth.
  - A removed peer must not be able to exploit this loophole: By communicating
    with a detached peer that has not yet received the updated membership list,
    a removed peer can submit edits to the ensemble. To prevent this, the
    following rules are followed:
    - The rules have moved to the [protocol document](06-brainframe-protocol.md#removed-peers).

The protocol details for this section are in the [protocol document](06-brainframe-protocol.md#removed-peers).

### Edits must form a DAG

This section has moved to the [protocol document](06-brainframe-protocol.md#edits-must-form-a-dag).

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

### What a decryption key is and where it is stored

This section has moved to the [protocol document](06-brainframe-protocol.md#what-a-decryption-key-is-and-where-it-is-stored).

### Key rotation process

This section has moved to the [protocol document](06-brainframe-protocol.md#key-rotation-process).

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

### Backup restoration

From the keeper's perspective, the only files that matter are the notes and
documents the keeper is maintaining. The `.brainframe` folder does not matter to
them. When a backup is performed, the `.brainframe` folder gets included
normally, and a restore of that folder will also include the `.brainframe`
folder. Depending on the scope of the restore, it could also include the third
data location, which includes the global edit history.

This introduces all of the same risks as in [file
synchronization](#file-synchronization-tools). If BrainFrame is able to detect
that such a file restore has occurred, it should warn the keeper, and offer to
rejoin the ensemble as a new peer.

The protocol details for this section are in the [protocol document](06-brainframe-protocol.md#backup-restoration).

### Long Term Detached Peers

When a peer is detached for a long time, it prevents other peers from performing
snapshots. This consumes resources, both in storage and in RAM usage when
rendering a document from the current edit history. This cost is unbounded
without constraints.

The protocol details for this section are in the [protocol document](06-brainframe-protocol.md#long-term-detached-peers).

### Snapshots require special handling

A snapshot covers the internal state of a given document, and is an integral
part of producing the output document. Especially in the case of a blind peer,
the system is vulnerable to a malicious actor. The malicious actor would be able
to submit a falsified snapshot that empties out a document without the handling
described below.

The protocol details for this section are in the [protocol document](06-brainframe-protocol.md#snapshots-require-special-handling).

### A fake ensemble is a fork

A compromised writing peer can create a fake membership list, with fake
signatures, and present those to a peer trying to join an ensemble. The joining
peer will be able to be tricked by this because a single peer controls the
joining, and making a joining peer talk to multiple peers just to join an
ensemble will result in the sync feature being unused, which means it will
protect nothing.

This scenario is, simply put, a fork. The admitting peer has created a new
ensemble that will simply not bring the new peer into the actual ensemble. The
attacker who has compromised the admitting peer will gain nothing more than the
ability to work with the joining peer just like any other peer in any other
ensemble.

Furthermore, the joining peer will quickly learn that it is not able to
communicate with the actual ensemble, just as the members of the actual ensemble
are unable to communicate with that joining peer. Edits will simply not be
transmitted, causing all involved keepers to figure out that something is wrong.

With all of this in mind, we accept this risk as a real attack, but with no
practical value.

### Changing membership type for a peer

No peer may change its own role, and only a writing UI peer may change the role
of another peer.

The protocol details for this section are in the [protocol document](06-brainframe-protocol.md#changing-membership-type-for-a-peer).

### Bootstrapping an ensemble

The primary problem for this bootstrapping record is verification: A joining
peer must be able to verify that this root record actually represents the
ensemble the joining peer is attempting to join. Using solutions like [Bitcoin
Improvement Proposal
39](https://github.com/bitcoin/bips/blob/master/bip-0039.mediawiki) (BIP-39)
will provide a mechanism, usable by humans, to communicate the fingerprint of
the bootstrapping record. Note that this fingerprint must always be at least 128
bits, though longer is acceptable. If BIP-39 is used, then that would mean 12
words.

The same mechanism can be used to provide the same security to the admitting
keeper that the peer joining is the intended joining peer.

The protocol details for this section are in the [protocol document](06-brainframe-protocol.md#bootstrapping-an-ensemble).

### Joining an ensemble, even for peers separated by hundreds of miles

This section has moved to the [protocol document](06-brainframe-protocol.md#joining-an-ensemble-even-for-peers-separated-by-hundreds-of-miles).
