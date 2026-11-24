# Development status

## Status at a glance

| Phase | Status | Scope |
| --- | --- | --- |
| 1 — Rendering foundation | In progress | Native shell, Metal device selection, still/video playback, layer compositing, fullscreen output, diagnostics |
| 2 — Projection mapping MVP | Planned | Multiple surfaces in one output, quad warp, polygon masks, editor, calibration patterns, church cross and ceiling workflow |
| 3 — Live production | Planned | Media library/clip launcher, scenes, transitions, cues, show persistence, autosave and recovery |
| 4 — Advanced inputs and effects | Planned | NDI, USB capture, Syphon, effects and audio |
| 5 — External control and expansion | Planned | MIDI/OSC, Stream Deck, control API, multiple projectors and edge blending |

The current milestone is deliberately narrower than the full brief. Phase 1 must be validated as a working native app before Phase 2 begins. The project is not yet suitable for the primary church acceptance workflow because it does not map or mask surfaces.

## Phase 1 exit checklist

- [x] Native SwiftUI/AppKit application target and macOS deployment target.
- [x] Prefer a discrete/high-performance Metal device and expose its name in the UI.
- [x] Import local still images and video files.
- [x] Display multiple layers with alpha compositing and independent opacity.
- [x] Render the same composition in a preview and one fullscreen display window.
- [x] Provide basic blackout and output-close controls.
- [x] Build with Xcode and resolve compiler issues for the Intel x86-64 target.
- [ ] Run on macOS 12+ and verify media import, playback, display routing, and device diagnostics.
- [ ] Profile two simultaneous 1080p videos at 60 FPS on the 2019 Intel MacBook Pro.
- [ ] Run an extended playback session and check memory and frame pacing.

## Phase 2 — Projection mapping MVP

Add a resolution-independent surface model, four-corner perspective correction, concave polygon mask, cross and ceiling surface presets, interactive handles, source assignment, independent brightness/opacity, calibration patterns, surface lock, and mapping save/restore. Composite all mapped surfaces into one physical output framebuffer. Add geometry and project-serialization tests before relying on saved calibration.

## Phase 3 — Live production and persistence

Add a media library and clip launcher, independent transport and playback settings, scene recall, preview/program workflow, transitions, cues, full show-file persistence, media relinking, autosave, and crash recovery. Scene recall must not alter calibrated physical geometry.

## Phase 4 — Optional inputs and effects

Add NDI only after checking SDK availability, Intel support, licensing, and redistribution terms. Isolate NDI, USB capture, and Syphon adapters from the core renderer so failures or unavailable SDKs do not prevent local-media projection. Add GPU effects and audio only with measured resource budgets.

## Phase 5 — External control and expansion

Add MIDI Learn, OSC, Stream Deck integration, a local control API, remote calibration, multiple projectors, and edge blending. Treat network-facing controls as a separate security and reliability review item.

## Validation record

The Debug app target built successfully with Xcode 17.4 for `x86_64-apple-macos12.0`. No automated tests or target-hardware performance run has been recorded. The build was run with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` because the machine's global developer directory points to Command Line Tools. Do not describe frame rate or Intel GPU performance as validated until measured on the stated hardware.
