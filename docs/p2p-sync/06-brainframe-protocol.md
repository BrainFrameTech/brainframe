# BrainFrame sync protocol

- **Status:** placeholder — not started
- **Part of:** the [P2P sync sequence](README.md), document 6 of 7

## What this document will answer

Exactly what BrainFrame sends between devices. That is the protocol the fit
analysis chose, with every change the analysis called for, written precisely
enough that someone could implement it without reading BrainFrame's code. It
covers the message formats, pairing and key exchange, and what each party can
see. It shows how each security goal in the
[threat model](01-threat-model.md) is met.

## What it needs first

An accepted fit analysis that recommends a protocol.

## What it hands on

The specification that the [sync design](07-sync-design.md) implements.

## Material moved from the threat model

Moved verbatim from the [threat model](01-threat-model.md), section by
section; only link targets and list indentation were changed.

### File synchronization tools

BrainFrame will attempt to detect file synchronization happening in this
fashion, and provide the warnings. It will not disable it, since it is also
possible to use this technique for providing a backup outside the ensemble. But
making the keeper aware of the pitfalls when using it to keep the ensemble in
sync is important. As such, when the keeper turns on sync, a warning will appear
stating that only one sync method should be used, and automatic file sync tools
should be turned off for this engram.

### Read Only Membership

A peer is designated as reading, writing, or blind when it joins the ensemble by
the keeper admitting the peer to the ensemble. These details are part of the
joining process, and any record that does not include the necessary parts is
incomplete and rejected by the ensemble. The necessary parts of the record:

- A hybrid logical clock entry, consisting of the peer ID of the admitting peer,
  a UTC based timestamp for the record, and a counter. This is identical to the
  CRDT hybrid logical clock
- The peer ID of the joining member
- The permission level of the joining peer (reading, writing, or blind)
- The public key of the joining peer
- The peer ID of the peer used to approve the join
- The approving peer's signature over the contents of the joining record
- The type of the record: a join, a removal, permission change, bootstrapping,
  invitation, invitation acceptance, invitation withdrawal, symmetric key
  message
- The prior membership record for the peer used to approve the join
  - This is used to create a DAG and enforce history.
  - The prior record could be the record of its own joining to the ensemble
  - The first record presents a circular loop, since there is no parent record.
    As a result, the first record will be a designated bootstrapping record for
    the ensemble. If a peer tries to join an ensemble and has its own
    bootstrapping record for that ensemble already, the peer will be rejected.

### Edit histories and other records

Edit histories, when encrypted, *must* include the UUID of the key that was used
to encrypt the record. Without it, it will be impossible for receiving peers to
determine which key to use to decrypt the record.

Note that the public key of a peer must remain with that peer's membership
records, both admission and removal. It is required to validate incoming records
from that peer.

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

### Conflict records and agreement records

Conflict records exist *only* on the peer that found the conflict, and are never
passed along to the ensemble. Their exact fields are not fully defined, but will
include at least the following:

- the peer ID of the remote peer
- the peer ID of the current peer
- the type of record (membership, edit, etc)
- the contents from the remote peer, expressed as json
- the contents from the current peer, expressed as json

### Removed peers

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

- At time of rejoining, the existing peer ID will be allowed back into the
  ensemble, and the peer will normally rejoin as if it was brand new, while
  still using the same peerID that it used before removal (under some
  circumstances, reuse of the peer ID may not be possible, such as a
  reformat). Edit history is then possible to bring in from the rejoining
  peer, minimizing data loss/new document scenarios where possible.
  Permissions (reading, writing, or blind) have to be re-established at the
  time of joining, and the current keys have to be given to the rejoining
  peer. Finally, a rejoining peer must present its edit history to a keeper on
  a UI peer with writing permission. This process occurs outside of the normal
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

### What a decryption key is and where it is stored

A decryption key is a symmetric encryption key. It is used to handle both
encryption and decryption operations. The cipher used for this must be at least
as good as AES256. The key itself will be a randomly generated key, never
directly exposed to any keeper.

Each key consists of two components: a UUID to identify the key, and 256 bits
(32 bytes) of random data, and stored in the third data location, beside the
local edit history for the engram.

It is not encrypted when stored, because doing so simply creates an infinite
loop of "to get this key, we have to decrypt it using this other key, which must
also be encrypted, so we use yet another key to decrypt that key, etc). This
does open an attack vector, but it is one we have already been forced to accept
as NG2.

The key is distributed to other peers by encrypting a message to them using
their public key. These messages are distributed as part of the membership
record list, and therefore may only be generated by writing UI peers.

### Key rotation process

Whenever the encryption keys need to be rotated, this method is to be followed.

- The writing UI peer has determined that a key rotation is needed for one of
  the following reasons:
  - Removal of a peer
  - Changing a peer to a blind peer
  - Manually initiated, for instance in the case of a suspected compromise
    (which is *usually* accompanied by a peer removal)
  - After an invitation is withdrawn
  - A scheduled rotation will *not* be offered by BrainFrame. It was considered
    and rejected as adding complexity unnecessarily when most of the data that
    is managed by a BrainFrame instance is stored unencrypted.
- The writing UI peer generates a new symmetric key and stores it. Note that the
  old key is *not* deleted, allowing the writing UI peer to decrypt messages
  from the ensemble that use the old key.
- The writing UI peer generates a new membership message for each reading and
  writing peer it knows about that is a current member (never a blind peer or a
  removed peer), sending the new message to the ensemble as a membership record
  with the new symmetric key encrypted exclusively to that peer.
- Each peer, on receiving the new key, stores the new symmetric key beside the
  old key. This ensures that each peer continues to be able to decrypt older
  messages.

It is possible for two peers to issue key rotation records while detached from
each other, producing a conflict. To resolve this, we take a page from CRDTs,
and use a last writer wins methodology. Whichever key occurs later in the
membership list DAG will be treated as the canonical decryption key by the
ensemble. Note that this does *not* mean discarding the losing key: that key
still needs to be kept so that records can be decrypted that were encrypted
using that key.

In the event that two key rotations appear at the same level in the membership
list DAG, we again take from the CRDT methodology, and use the hybrid logical
clock attached to the record, sort it lexicographically, and use the last writer
wins still. Once the decision is made, a new key rotation occurs. This new
rotation must be issued by the peer that won the decision. The new key rotation
will follow this same process. This mitigates the effect of a detached peer
giving the current symmetric key to a removed peer that the detached peer did
not know about yet.

In the event that the winning peer is unable to issue the new key (for instance,
if it was stolen), any writing UI peer *can* initiate a key rotation process.
Any writing UI peer will notify the keeper if this situation is detected and
unresolved for 7 days after the peer received the conflicting key. At this
point, the key rotation process becomes a normal key rotation process, initiated
by a keeper.

This would seem to contradict [clocks can't be
trusted](01-threat-model.md#clocks-cannot-be-trusted), but this is another low-consequence
decision: One of the keys has to win, one has to be retired, and CRDTs with HLCs
have been using this for decades already. Add in that a keeper can initiate this
manually, and the usage of the local clock to notify the keeper about the
problem is a low-consequence operation, and, for this case, the use of a clock
is justified.

### Backup restoration

If the keeper chooses to have the restore rejoin the ensemble as a new peer,
then an additional offer should be made to remove the old peer ID from the
ensemble *if* the new peer is able to issue that removal (i.e.: the new peer is
a writing UI peer). If the offer is declined, then the keeper should be informed
that the removal should happen, or the edit history can never be cleaned up,
resulting in infinite growth of the storage for the engram on *every* peer.

### Long Term Detached Peers

The keeper must be informed that a detached peer is causing problems under any
of three conditions:

- A peer has been detached for more than 30 days. At this point, the peer should
  be brought online, or removed from the ensemble. The 30 days is an arbitrary
  time limit, and can be adjusted up or down as data eventually reveals.
- A peer has been detached and the local edit history of a given document is
  consuming more than 16 megabytes of storage space in the local engram. At this
  point, it could easily be affecting the smallest peers and making it hard for
  them to render a note. The 16 megabytes is an arbitrary number and can be
  adjusted as experiments show.
- A peer has been detached and the local edit history across the engram is
  consuming more than 1 gigabyte of storage space. This could now be causing all
  peers in the engram issues with keeping data longer than it should. The 1
  gigabyte is an arbitrary number and can be adjusted as experiments show.

With those constraints in place, the keeper can perform the maintenance that
prevents a given peer (or even the whole ensemble) from becoming unusable. If
the keeper chooses *not* to do anything, this will be accepted, but with
reminders occurring every time a document is opened (for the 16 megabyte
trigger), or the engram is opened (for the 1 gigabyte trigger or the 30 days
trigger).

This does use a clock to register how long it has been since a peer was last
seen, but no decisions are made by the program based on this clock. This is
strictly informational for the keeper, and is therefore a safe clock to use.

### Snapshots require special handling

Every peer must follow these rules when handling snapshots:

- The peer must produce a consistent ordering for the elements of the snapshot
  (version vector, edit history, etc)
- The peer must produce a version of the snapshot that uses that ordering. This
  then becomes the canonical snapshot, as opposed to the snapshot produced by
  crdt_lf.
- The peer generates a hash from the canonical snapshot
- The peer signs that hash and distributes the hash to the ensemble
- Every peer (except blind peers) compares the incoming hash with its own
  canonical snapshot hash. When the local hash agrees, the peer publishes an
  agreement record.
- The blind peer(s) wait until all reading and writing peers have produced their
  agreement records. If every peer agrees, then the blind peer is able to prune
  history without issues.
- If any peer produces a *different* hash then a problem has occurred with that
  peer. Possibilities include missing edit history, compromised peer, or subtle
  hardware failure (among many others). The keepers need to be notified so they
  can make a decision about the problematic peer.
- If any peer does not publish an agreement record, it is considered a detached
  peer, and the rules for handling a detached peer are followed.

### Changing membership type for a peer

This operation is similar to a remove and a join, and may even be implemented
that way. Simply put, the end result of this process is that a writing UI peer
appends a record to the membership list that states the new role for the peer.

When changing a peer from writing to reading (or blind), a set of records must
be created that matches the same type of data used for removing a peer. Doing so
determines what edits will still be accepted by the ensemble. If a peer is being
converted to a blind peer, then a key rotation must happen.

### Bootstrapping an ensemble

The bootstrapping record for an engram (and, therefore, the ensemble), is both
incredibly important, and is also a membership record, consisting of the
following fields:

- Peer ID
- Public key of the peer ID
- The permission level of the peer (for bootstrapping, this will *always* be
  writing)
- The type of the record (always bootstrapping for this step)
- The signature of this peer over the contents of this record

The other fields that are listed in [read only
membership](#read-only-membership) will all be null. A special consequence of
this is that the bootstrapping record is, essentially, the origin of the
ensemble, making this record into the identity of the ensemble.

When an ensemble is being started, the bootstrapping peer is responsible for
creating the first symmetric key for the ensemble and then distributing it as
described in [key rotation](#key-rotation-process).

Once a given peer joins the ensemble, it must reject any new bootstrapping
records at the time of receiving them. Once the record type identifies it as a
bootstrap, it is rejected, and any records that build from that new bootstrap
record are also rejected as invalid. If a peer wishes to establish a new
bootstrap record, it must delete the `.brainframe` folder for the engram, and
create a new ensemble.

Because of the special nature of the bootstrapping record, a conflict can arise
during implementation:

- A peer ID exists per engram, and no peer ID exists until an engram has been
  defined.
- A bootstrapping record *may* be created right away on the peer, before it has
  joined an ensemble.
- Following the rules above, the joining peer would always reject the
  bootstrapping record from the admitting peer.
- The exception:
  - If a joining peer has only itself in the membership list for the ensemble,
    it should discard its own bootstrapping record and accept the admitting
    peer's bootstrapping record. This action must be accepted by the keeper, and
    not performed automatically. The alternative allows an attacker to send
    bootstrapping records to any peer not currently in an ensemble, and take
    over the ensemble from there, potentially even leaving the joining peer as a
    read only member of its own engrams.
    - All existing notes and documents will maintain their current status.
      - After receiving the state of the engram from the new ensemble, the
        engram adoption process will occur. BrainFrame will scan over the
        contents of the engram, comparing the desired state of the engram with
        the current state from incoming edit history. The joining peer will make
        safe edits where it can.
      - Any conflicts (notes or documents that would be overwritten by the new
        ensemble, unreconcilable notes or documents) become conflict records
        that the joining peer's keeper must decide what happens.
  - If a joining peer already lists multiple peers, the keeper of the joining
    peer must be informed that they are about to change the ensemble for the
    engram. Consequences of this choice:
    - All other peers currently part of this engram will be removed.
      - The old ensemble will still be intact, but will now have a detached peer
        that they must remove.
      - Only the local copy of the engram gets affected, as it must forget about
        the old ensemble.
    - All outstanding edits from those peers will be invalidated.
    - All existing notes and documents will maintain their current status.
      - After receiving the state of the engram from the new ensemble, the
        engram adoption process will occur. BrainFrame will scan over the
        contents of the engram, comparing the desired state of the engram with
        the current state from incoming edit history. The joining peer will make
        safe edits where it can.
      - Any conflicts (notes or documents that would be overwritten by the new
        ensemble, unreconcilable notes or documents) become conflict records
        that the joining peer's keeper must decide what happens.
  - The keeper must decide if this is acceptable and make an informed choice.

### Joining an ensemble, even for peers separated by hundreds of miles

Peers sometimes *must* use the open internet to communicate, even for joining an
ensemble. The following process works with both remote and local peers.

When joining an ensemble, the admitting keeper extends an invitation (note:
never the opposite; a joining keeper never requests an invitation via BrainFrame
itself) which propagates to the peers.

This occurs in the form of an invitation record on the membership list.

- The admitting keeper and the joining keeper have to exchange some information
  before the technical process begins.
  - Public key fingerprints
  - Peer IDs
  - Ensemble ID
  - Where to connect: This can be a direct local connection, or a blind peer (or
    the service), determined by the keepers at the time of the exchange.
  - Note that this exchange can be condensed into a single QR code exchange from
    each side.
- The invitation includes the ID and fingerprint of the joining peer and the
  admitting peer, as well as the full public key and signature of the admitting
  peer.
- The joining keeper accepts the invitation, which propagates an invitation
  acceptance record. The acceptance record includes the ID and full public key
  of the joining peer and the ID and fingerprint of admitting peer, as well as
  the signature of the joining peer. This record is *only* accepted when the
  peer ID and key fingerprint and signature match an existing invitation record.
- Once the invitation has been accepted, the membership list record is created
  that tells the ensemble the peer is allowed and with what permissions.
- The decryption keys are then distributed to the joining peer, *unless* the
  joining peer is a blind peer.

Using these two record types provides the necessary signatures to the ensemble
to prove the following:

- The joining peer has been invited, and its identifying characteristics are
  known by the admitter: The public key fingerprint and peer ID are established.
- The joining peer has confirmed the characteristics about the ensemble: the ID
  of the ensemble, the public key and fingerprints of the admitting peer are
  known by the joining peer.
- The admitting peer has confirmed acceptance and assigned permissions.

In the event of a failure (joiner does not accept, machine failure before
acceptance, etc), the admitting keeper can issue an invitation withdrawal
record. It will include all of the information from the actual invitation
record, but the record type will indicate a withdrawal. Any peer which has a
withdrawal record must not accept an invitation from the peer identified by the
withdrawal record.

An attack vector does exist: A peer which becomes detached after an invitation
is issued but before it is withdrawn could incorrectly admit the peer identified
by the withdrawal record. All peers in the ensemble have to guard against this,
and reject any edit records from a withdrawn peer, similar to rejecting any edit
records from a removed peer. The mechanism will be the same, but the list of
edits that will be accepted from the peer that had its invitation withdrawn will
simply be empty.
