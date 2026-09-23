# The e-ink embedder

- **Status:** proposed (2026-09-22) — this document *is* the proposal; it
  becomes accepted when the PR introducing it merges
- **Author:** Claude
- **Date:** 2026-09-22
- **Companion to:** [note-size-ceiling.md](note-size-ceiling.md), whose
  smallest-machine budget (512 MB Pi Zero 2 W) this reuses, and
  [../appimage.md](../appimage.md), which packages the flutter-pi build this
  document reclassifies

## TL;DR

**flutter-pi is not the e-ink embedder, and it cannot become one.** It requires
a DRM/KMS output backed by a GPU, and it presents by page-flipping on vblank.
An SPI e-paper panel offers neither. The mismatch is not a missing feature —
it is the contract.

The e-ink target needs **its own embedder, built on the Flutter Embedder API's
software renderer**: the engine hands over a rasterized pixel buffer per frame,
and that code decides when to push it to the panel and with which waveform.
That decision point is the entire e-ink architecture, and it is the one thing
flutter-pi does not expose.

**flutter-pi stays.** It is reclassified from "the e-ink path" to what it has
actually been all along: the **low-resource rehearsal** — a no-desktop Pi build
that proves out the AOT engine, the memory ceiling, input, storage and
packaging on the real hardware. Every part of that work transfers. What gets
replaced is the presentation backend, which nobody here wrote.

## What flutter-pi actually requires

Upstream states it plainly: flutter-pi needs "support for kernel-modesetting
(KMS) and the direct rendering infrastructure (DRI)", and it "requires that no
other process, like a X11- or wayland-server, is using the video output". In
practice that means:

- a DRM device (`/dev/dri/cardN`) with a **GPU** behind it — buffers are
  allocated through GBM and rendered through EGL/GLES, or Vulkan with
  `--vulkan`;
- a **KMS output** in front of it — a connected connector it can modeset and
  page-flip onto.

There is **no fbdev backend and no software-rendering fallback**. The
`--dummy-display` flag exists for running headless in CI; it does not hand the
rendered pixels back, so it is not a bridge to a panel.

The requirement is therefore narrower than "a video device". It is
specifically *a GPU-backed DRM device with a KMS output*. That precision is
what creates the one exception below.

## Which e-ink — the exception, and the real case

### HDMI e-paper works today

Waveshare's IT8951-based HDMI e-paper panels (6", 7.8", 10.3") present to the
Pi as an ordinary HDMI monitor. flutter-pi drives them **unmodified, today**.
Refresh mode (A2 vs GC16) is chosen on the panel's own buttons or USB control
interface, not by the app.

This is a legitimate way to see BrainFrame on e-ink early, and it is worth
doing. It is not the product: it needs a full-size Pi with HDMI, the panel's
driver board, and it leaves refresh policy outside the app entirely.

### SPI e-paper — the actual target — does not

The intended device is a Pi Zero 2 W with a Waveshare SPI e-paper HAT. The
Zero 2 W has no DSI connector, so the panel is on SPI or nothing. An SPI panel
has **no DRM device at all** — it is driven from userspace over SPI, one
command and one framebuffer transfer at a time. flutter-pi has nothing to bind
to.

A DRM device can be *manufactured* for such a panel — `julbouln/tinydrm_it8951`
does exactly that for IT8951 kits, tested on a Pi Zero W, and mainline's
`mipi-dbi-spi` overlay generalizes the pattern for SPI displays. It does not
help:

- tinydrm-class drivers are **dumb-buffer, CPU-only cards**. No GBM, no GLES,
  no EGL — precisely what flutter-pi will not render into.
- Bridging the Pi's `vc4` render node to a separate non-GPU scanout card means
  PRIME-importing GPU-tiled buffers into a driver that wants linear CPU
  memory, for a panel that cannot page-flip.
- It would buy a working pixel path and still leave the refresh policy
  unreachable — see below.

Running the engine's rasterizer on the GPU only to drag every frame back
across that boundary is strictly worse than rasterizing on the CPU in the
first place, which is what the chosen design does.

## The deeper mismatch

Even with the pixels plumbed, flutter-pi's presentation path is *page-flip on
vblank*, and it clocks the engine's vsync off the display's refresh rate.

The architecture in [`CLAUDE.md`](../../CLAUDE.md) is the opposite: render at
full speed, push to the panel **only on deliberate user actions** (page turn,
pen lift, file open), choosing full (~2–4 s) or partial (~0.3 s) refresh per
push, with a periodic full clear to stop ghosting accumulating across partials.

That policy lives in the **present step**. The embedder owns the present step.
flutter-pi's is a page-flip and offers no hook to replace it. Right embedder,
wrong contract — and no patch short of rewriting its compositor changes that.

## Decisions

### Decision 1 — the e-ink panel gets a purpose-built embedder

BrainFrame will ship a small embedder of its own for the e-ink device, built
directly on the Flutter Embedder API. Working name **flutter-eink**; whether
it lives in this repo or beside it is deferred until it exists.

### Decision 2 — it uses the software renderer, not GL

The embedder configures `FlutterSoftwareRendererConfig`. Its
`surface_present_callback` receives a rasterized pixel buffer and its
dimensions, once per frame. No DRM, no KMS, no GBM, no EGL, no GPU.

This is not a compromise made under protest. The panel is slower than the CPU
by an order of magnitude (see Cost), the colour depth is 1-bit or 16-grey, and
a software buffer is already in exactly the form an SPI transfer wants.

Prior art, and a starting point: `flutter_fbdev` is this same shape for
`/dev/fb0` — **about 300 lines of C** — written for ARM handhelds that cannot
run flutter-pi for the identical reason. Swapping its framebuffer `memcpy` for
an SPI transfer plus a waveform command is the bulk of the work.

### Decision 3 — the present callback is where refresh policy lives

Each present is: diff against the previously pushed frame → derive a damage
rectangle → decide *whether to push at all*, and if so with which waveform →
transfer over SPI. Frames the engine produces that no deliberate action asked
for are simply not pushed; the panel keeps showing the last committed frame
while the widget tree moves on without it.

Ghosting is managed here too: partial refreshes are counted, and a full
refresh is forced after a bounded run of them. This is a hardware requirement
of e-paper, not a tuning knob — an unbounded run of partial updates degrades
the panel's image in ways a later refresh does not fully repair.

### Decision 4 — frames are clocked by the app, not by a display

With `FlutterEngineOnVsync` and custom task runners, the embedder decides when
the engine is asked for a frame. There is no display refresh rate to inherit
and none is invented. The deliberate-action model from `CLAUDE.md` becomes
literal rather than aspirational.

### Decision 5 — flutter-pi is retained as the low-resource rehearsal

It keeps earning its place, on merit that has nothing to do with e-ink:

- the AOT arm64 engine and the no-desktop asset bundle layout;
- the 448 MB memory envelope and the note-size ceiling that falls out of it;
- input through libinput straight from evdev, including the text-field
  corruption patch this repo carries;
- the sqlite path, `BRAINFRAME_ARGS`, AppImage packaging, the systemd unit.

All of it is above the presentation layer and transfers unchanged. Proving the
app runs at all on 512 MB of Pi is most of the port; only the bottom few
hundred lines are embedder-specific.

What changes is the documentation, not the code: flutter-pi is no longer
described as the e-ink path anywhere, so nobody optimizes the wrong bottom
layer.

### Decision 6 — HDMI e-paper is a demo, not a target

Driving an IT8951 HDMI panel with the existing flutter-pi build is endorsed as
an early way to *see* the app on e-paper. It gets no packaging, no test-plan
column and no design accommodation of its own, because its refresh policy is
in the panel's firmware where BrainFrame cannot reach it.

## Cost

Sizing against the largest plausible panel, the 10.3" at 1872×1404:

- One frame buffer is ~10.5 MB at 32 bpp. Two or three fit comfortably inside
  the 448 MB envelope already established on the Pi.
- The panel is a 1-bit or 16-grey device, so the pushed payload after packing
  is a fraction of that again.
- Skia software rasterization of a text page on four Cortex-A53 cores lands in
  the low hundreds of milliseconds. Against a 300 ms partial or a 2–4 s full
  refresh, it is not the bottleneck and will not become one.

The smallest-machine reasoning in [note-size-ceiling.md](note-size-ceiling.md)
is unaffected: the constraint there is CRDT memory per character, which is
independent of how frames reach the panel.

## Risks and what to verify when the work starts

- **Software-renderer longevity.** The embedder API's software path is a
  legacy-leaning route in an Impeller world. It works today and
  `flutter_fbdev` depends on it, but confirm its status in the engine before
  committing rather than assuming it survived. If it is withdrawn, the
  fallback is an offscreen GL/Impeller surface read back per frame — more
  code, same architecture, and it still needs a GPU.
- **Panel controller choice is unmade.** IT8951 (with its own framebuffer and
  waveform handling) versus a bare SSD16xx-class controller changes how much
  of Decision 3 the embedder implements versus delegates. Pick the panel
  before writing the driver half.
- **Touch and pen input** are outside everything above. flutter-pi's libinput
  path is reusable in principle; a digitizer on SPI/I²C is not, and handwriting
  markup will want a latency story the present policy must not block.
- **No screen reader on the panel**, per
  [.claude/rules/accessibility.md](../../.claude/rules/accessibility.md) —
  Semantics annotations continue to target the companion desktop and mobile
  builds. This design does not change that.

## References

- flutter-pi — <https://github.com/ardera/flutter-pi>
- `flutter_fbdev`, a ~300-line software-rendering fbdev embedder —
  <https://pub.dev/packages/flutter_fbdev>
- `tinydrm_it8951`, a DRM driver for Waveshare IT8951 SPI kits —
  <https://github.com/julbouln/tinydrm_it8951>
- Flutter embedded support — <https://docs.flutter.dev/embedded>
- `embedder.h`, the Embedder API surface including
  `FlutterSoftwareRendererConfig` —
  <https://github.com/flutter/engine/blob/main/shell/platform/embedder/embedder.h>
