# Sync design

- **Status:** placeholder — not started
- **Part of:** the [P2P sync sequence](README.md), document 7 of 7

## What this document will answer

How the [BrainFrame protocol](06-brainframe-protocol.md) is built inside
`lib/`. It covers how sync connects to the local op-log from
[note-identity-and-crdt.md](../design/note-identity-and-crdt.md), how it stays
within the memory limits of the low-resource targets, and the order it is
built in. It takes the same form as the documents in
[`docs/design/`](../design/).

## What it needs first

An accepted [BrainFrame protocol](06-brainframe-protocol.md).

## What it hands on

The plan the implementation follows, for #67 and, alongside it, #66.
