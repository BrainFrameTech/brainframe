# BrainFrame

## Project Overview

BrainFrame is an open-source, cross-platform Second Brain / E-Reader app
combining:

- **Obsidian-style knowledge management** — markdown notes, graph view,
  backlinks, tagging
- **Supernote-style document reading & annotation** — PDF, EPUB,
  handwriting markup

## Platforms

| Platform | Notes |
| --- | --- |
| Windows, Mac, Linux | Standard Flutter desktop targets |
| Android, iOS | Standard Flutter mobile targets |
| Raspberry Pi (no desktop) | via flutter-pi; the low-resource rehearsal for the e-ink device |
| Raspberry Pi + e-ink | Waveshare SPI panel, via an embedder of our own — **not** flutter-pi |

## Tech Stack

- **Language:** Dart
- **Framework:** Flutter
- **Pi embedder:** flutter-pi (runs on Pi 3/4/5 and Zero 2 W, no X11 or
  desktop environment needed) — this is the no-desktop *rehearsal* target, not
  the e-ink one
- **E-ink embedder:** a purpose-built software-rendering embedder, still to be
  written — see [docs/design/eink-embedder.md](docs/design/eink-embedder.md)
- **Version control:** GitHub (github.com/pedersen/brainframe)

## E-Ink Architecture

Flutter renders normally at full speed. Frames are only pushed to the e-ink
panel on deliberate user actions (page turn, pen lift). This is a hardware
constraint, not a Flutter limitation — the same model used by Supernote and
reMarkable.

- Full refresh: ~2–4 seconds
- Partial refresh: ~0.3 seconds

UI interactions on e-ink must be designed around this — avoid animations,
hover states, or anything assuming continuous rendering.

**This is why flutter-pi is not the e-ink embedder.** Deciding *when* to push
a frame, and with which waveform, happens in the embedder's present step.
flutter-pi's present step is a page-flip on vblank onto a GPU-backed DRM/KMS
output, which an SPI e-paper panel does not have and cannot be given usefully.
The panel gets an embedder of our own, built on the Flutter Embedder API's
software renderer; flutter-pi stays as the low-resource rehearsal. The
reasoning, the rejected alternatives, and what transfers between the two are
in [docs/design/eink-embedder.md](docs/design/eink-embedder.md).

## Project Context

- Open-source, solo-maintained; community contributions welcome.
- **A core goal is for every line in the repo to be written by Claude** — a
  deliberate experiment in AI-authored software. Human input is mainly
  direction, review, and decisions rather than hand-written code, with Claude
  Code as the primary development tool.
- Learning to collaborate well with Claude is itself a goal here; picking up
  Flutter and Dart happens along the way but isn't the main focus.

## Manual test plan

`docs/manual-test-plan.md` is the human-run counterpart to the automated
tests — a platform × feature matrix of concrete steps for the UI and
interaction bugs `flutter test` can't see. It must not rot.

- **Same-change rule:** whenever you add, change, or remove a user-facing
  widget or interaction, update `docs/manual-test-plan.md` in the **same**
  change (same PR). A user-facing UI change with no test-plan edit is
  incomplete.
- **Flag it in the summary:** in the PR/change summary, list which test cases
  you **added**, **changed**, or **invalidated**, by their IDs (e.g. "F10,
  D5"). If a change moves a feature across the shipped ↔ frontier line, say so
  (promote it out of "Not yet testable", or retire its cases).
- **Frontier discipline:** never write pass/fail steps for a feature that isn't
  in `lib/` yet — put it in "Not yet testable" with the reason. When it ships,
  promote it.
- **Reasons are load-bearing:** an "N/A — reason" cell is a claim about the
  platform. If a change makes a feature apply where it previously didn't (or
  vice-versa), fix the cell and its reason.
- **A CI nudge, not a gate:** `.github/workflows/test-plan-nudge.yml` posts a
  self-clearing sticky comment when a PR changes UI code without touching the
  plan. It never blocks a merge — it is a reminder to apply the same-change
  rule.
