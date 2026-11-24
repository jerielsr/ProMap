# Development status

## Status at a glance

| Phase | Status | Scope |
| --- | --- | --- |
| 1 — Rendering foundation | Implemented; hardware validation pending | Native shell, Metal rendering, local still/video media, opacity layers, display output, GPU name and presented-frame-rate monitor |
| 2 — Projection mapping MVP | Implemented; installation acceptance still pending | Multi-surface output, projective corner warp, adjustable mesh warp, polygon masks, cross and ceiling presets, editor handles, source assignment, calibration patterns, surface controls, mapping files |
| 3 — Live production | In progress | Clip grid and intentional layer stack, layer naming/duplication/locking, layer reordering and solo, per-layer source transforms, isolated per-mask media assignments, named scenes, cue reordering, operator notes, timed cue advancement, configurable scene fades, preview/program, persistent program monitor, show save/load, unique-name media relinking, debounced autosave with recovery, unclean-exit detection and portable media bundles are implemented; full crash/restart acceptance remains |
| 4 — Advanced inputs and effects | In progress | GPU surface/per-layer effects, editable shader-generated solid/gradient/starfield/cloud presets, AVFoundation capture preview/format selection/status and reconnect, NDI discovery/manual source setup/audio-video receive and video send, bandwidth, disconnect fallback and live video format reporting, Syphon input/output, per-source audio controls, master volume, Core Audio output-device selection, scene-synchronized audio fades, NDI source audio meters and adjustable input delay, adjustable 2×2–6×6 mesh warping, source transforms, multiple include/cutout paths per surface and post-warp output exclusion masks are implemented; general video-source meters/delay and NDI target-receiver validation remain |
| 5 — External control and expansion | In progress | Optional HTTP/OSC control for blackout, actual master intensity, per-surface active/blackout/intensity, scenes and cues; token-protected remote corner calibration; MIDI Learn; separately assigned physical/virtual canvases and per-edge GPU blend falloff are implemented; Stream Deck-specific integration and projector overlap validation remain |

Output windows can target independent physical displays or windowed virtual canvases. Virtual outputs simulate a chosen pixel canvas inside an ordinary macOS window; they do not create system-level virtual monitors. Preset and custom virtual sizes are available (custom canvases allow 320–7680 × 240–4320 pixels). Each surface is assigned to one saved output ID, and each output window composites only its assigned surfaces into its framebuffer. Mapping and show files preserve output IDs, display IDs and canvas dimensions. Edge blend falloff is set per output edge and still needs calibration with overlapping physical projectors.

The output can be raised above the macOS menu bar from **ProMap → Settings**. Each mask output can be assigned a separate media source from the clip grid; the layer stack remains available for surfaces that use layered content.

## Phase 1 exit checklist

- [x] Native SwiftUI/AppKit application and macOS 12 deployment target.
- [x] Prefer a high-performance Metal device and show the selected device name.
- [x] Import local still images and videos.
- [x] Composite multiple enabled layers with independent opacity.
- [x] Render the session in the editor preview and output window.
- [x] Master blackout and close output controls.
- [x] Measure successfully presented Metal frames and show the active output's rolling rate.
- [x] Show a live estimate of presentation intervals that exceed 1.5× the selected frame interval; this measures cadence only and does not claim GPU utilization.
- [x] Intel x86-64 and Apple Silicon builds compile.
- [ ] Run on macOS 12+ and verify actual projector routing and device diagnostics.
- [ ] Profile two simultaneous 1080p videos at 60 FPS on the 2019 Intel MacBook Pro.
- [ ] Run an extended playback session and check memory and frame pacing.

## Phase 2 — Projection mapping MVP

- [x] Resolution-independent surface and mask coordinates.
- [x] Four-corner projective mapping with geometry validation and numeric percent entry.
- [x] Adjustable GPU mesh warp with 2×2 through 6×6 cell grids, draggable control points, resolution-change interpolation, reset and inversion checks.
- [x] Cross and ceiling presets, editable polygon masks and draggable corner/mask handles.
- [x] Numeric corner and selected mask-vertex coordinates, whole-surface move/scale/rotate, per-corner reset and reset-all.
- [x] Mapping zoom/pan/fit, larger numbered handles, edge-midpoint vertex insertion, contextual vertex deletion, grid snap, grouped geometry undo/redo and surface duplication.
- [x] Add fine/medium/coarse horizontal and vertical keystone adjustment, a numbered vertex selector, larger drag targets and output-space vertex nudge controls.
- [x] Add draggable per-edge output handles and independent width controls for top, right, bottom and left edges; preserve mesh shape while adjusting corners or edges.
- [x] Add independent per-surface source zoom, position, rotation and flip controls without changing output geometry or mask paths.
- [x] Independent media assignment, visibility, blackout, brightness, opacity and geometry lock per surface.
- [x] Grid, checkerboard, color bars and surface-outline calibration patterns.
- [x] Save/load mapping geometry and relink source paths from the local media library when possible.
- [x] Right-click an output to close it; open a virtual 720p, 1080p or 4K output without a projector.
- [x] Unit tests for projective transforms, mask inclusion, quad validation, mapping serialization and show serialization.
- [ ] Validate pixel accuracy, calibration workflow and output behaviour on the church projector.
- [x] Add adjustable soft feathering to individual polygon masks.
- [x] Add multiple included regions and subtractive mask paths per surface, including soft-edged holes.
- [x] Add feathered output-space exclusion masks that apply after surface warping.

Mask vertices use normalized source coordinates and warp with their surface. The editor supports direct drag, edge insertion, deletion, selection by numbered strip, precision output-space nudging and source-coordinate entry, with transformed output-position readback. A surface supports a main polygon plus up to seven additional include or cutout paths. Each output also supports up to eight feathered exclusion polygons in final output coordinates.

## Phase 3 — Live production and persistence

- [x] Capture and recall named scenes without changing calibrated geometry.
- [x] Crossfade layer opacity over 350 ms during scene recall.
- [x] Step backward and forward through the captured scene list as a cue sequence.
- [x] Save/load show JSON containing surface mapping, layer states, scene states, source paths and playback positions.
- [x] Autosave changed sessions every 30 seconds and offer recovery on the next launch.
- [x] Debounce autosaves after session changes, keep the previous valid recovery file and fall back to it if the latest file is unreadable.
- [x] Mark active app sessions and identify an unclean exit in the autosave recovery prompt; clear the marker during normal termination.
- [x] Browse media in a clip grid, assign media directly to one mask without spilling into the full-canvas layer stack, and add layers explicitly.
- [x] Reorder layers with forward/back controls and solo one or more layers; persist solo state with shows.
- [x] Rename and duplicate layers; lock transforms, opacity, effects, deletion and stack order while retaining live enable and solo controls. Persist names and locks with shows; scenes recall names without changing the operator's lock state.
- [x] Transform layer source content independently with horizontal/vertical zoom, position, rotation and flips; persist transforms in shows and scenes without changing surface geometry.
- [x] Stage a scene in an independent preview session, with a persistent program monitor and explicit TAKE/CANCEL controls.
- [x] Configure scene fade duration from Settings; video preview copies are muted and use the saved scene playback position/state.
- [x] Reorder cues, save operator notes and configure per-cue auto-advance duration with an operator-controlled AUTO gate.
- [x] Offer a guided folder search when show media is missing; relink unique filename matches and leave ambiguous or absent files offline with a summary.
- [x] Package available media into a portable `.promapshow` folder with relative paths; missing media and live capture references remain external.
- [x] Detect an unexpectedly terminated ProMap process and offer its latest valid autosave on the next launch.

Preview and program render through separate `RenderSession` snapshots and share the Metal device/texture cache. Staged video sources use muted player copies so auditioning a scene does not seek, pause or change the volume of the live program source. Taking a scene recalls its saved state with the configured crossfade.

## Phase 4 — Optional inputs and effects

- [x] Add real-time Metal surface colour correction for contrast, saturation, exposure, gamma and RGB gains, plus grayscale, sepia and invert looks.
- [x] Persist surface corrections in mapping/show files and recall them with scenes; older files without correction data continue to load.
- [x] Add opt-in AVFoundation live camera and external USB video sources with permission handling and stable show references.
- [x] Add ordered, enableable surface effects with Metal blur, chroma/luma key, brightness, saturation, hue rotation, tint, sharpen, vignette, threshold, grayscale, sepia, invert and pixelation, built-in reusable presets, and scene persistence.
- [x] Add per-layer effect stacks with enable, reorder, parameter, tint-color and built-in preset controls; show/scene serialization includes layer effects.
- [x] Save, apply and delete reusable effect-stack presets across surfaces and layers.
- [x] Select a supported capture-device resolution and common frame rate; persist the choice per device and show connection status.
- [x] Rebuild and resume AVFoundation capture when a known device reconnects; clear stale frames and show disconnected state while absent.
- [x] Add a throttled live thumbnail preview for capture sources in the media library, independent of projector assignment.
- [x] Add GPU-generated solid-colour, animated-gradient, starfield and cloud presets as assignable media sources with portable show/mapping references.
- [x] Add controls to edit generator colours, speed, scale and animation direction after creation.
- [x] Evaluate NDI/Syphon availability: the [official NDI SDK page](https://ndi.video/for-developers/ndi-sdk/) lists macOS and Intel/ARM CPU support, while its [SDK FAQ](https://docs.ndi.video/all/faq/sdk/what-are-the-differences-between-the-ndi-sdk-and-the-ndi-advanced-sdk) says commercial software use requires licensing discussion; the [official Syphon framework](https://github.com/Syphon/Syphon-Framework) provides a Metal client/server API under a BSD-style license.
- [x] Add opt-in NDI network discovery, a live receiver, clip-grid assignment, show-reference restoration and runtime status. The receiver loads the installed macOS NDI runtime dynamically; NDI binaries are not bundled.
- [x] Configure NDI receive bandwidth and hold-last-frame or black disconnect fallback; report received video resolution and frame rate in the clip tile.
- [x] Add a manually configured NDI source by name and address, and preserve that reference through show restore.
- [x] Receive NDI audio with live mute/level controls and route it to the selected Core Audio output; NDI clips start muted.
- [x] Show a live NDI input audio meter and allow 0–500 ms audio delay for A/V sync; persist levels and delay in scenes and shows.
- [x] Publish the selected physical or virtual projector output as a named, video-only NDI source at up to 30 fps.
- [x] Reuse one shared GPU readback buffer for NDI output frames and drop capture requests while a frame is in flight.
- [ ] Verify NDI output discovery, frame format, latency and sustained playback in NDI Studio Monitor and the target receiver on the intended network.
- [ ] Add NDI output audio after defining a reliable program-audio mix and synchronization path.
- [x] Add Syphon Metal input discovery and output publishing. Input sources restore from stable show references and wrap incoming IOSurfaces as CVPixelBuffers for the existing Metal texture-cache path. Output publishes the selected projector canvas directly from its Metal drawable when a Syphon client is connected.
- [x] Embed a universal Syphon framework for Intel and Apple Silicon, retain its upstream source and license, and document the source revision/build steps in `ThirdParty/Syphon/README.md`.
- [ ] Verify NDI input/output interoperability, latency and sustained playback with the actual NDI runtime and receivers on the intended network; confirm runtime licensing and redistribution requirements before packaging a release.
- [x] Add per-source mute and volume controls; newly imported video is muted by default and audio settings save with scenes/shows.
- [x] Add a master volume setting that scales per-source AVPlayer and NDI receiver audio.
- [x] Enumerate Core Audio output devices and route AVPlayer video audio and NDI receiver audio to the selected device or macOS System Default.
- [x] Fade per-source video audio with scene opacity during scene transitions.
- [ ] Add audio meters and configurable delay for local video sources; profile NDI and Syphon frame pacing, thumbnail work, and NDI meter/delay resource use on Intel hardware.
- [x] Add adjustable GPU mesh warping with configurable 2×2 through 6×6 cell grids and inversion prevention.
- [x] Add multiple included and subtractive source-space mask paths per surface.
- [x] Add feathered post-warp output-space exclusion masks.

## Phase 5 — External control and expansion

- [x] Add optional local HTTP controls for blackout, cue stepping and taking scenes, plus a JSON status endpoint.
- [x] Apply master output intensity in the Metal render and expose GET/POST controls for FreeShow.
- [x] Control each mask's visibility, blackout and intensity independently through HTTP.
- [x] Offer named-mask HTTP routes as well as UUID routes for simpler FreeShow cue setup.
- [x] Add optional OSC input for blackout, cue stepping and taking scenes.
- [x] Keep listeners disabled by default and use loopback unless remote access is explicitly enabled.
- [x] Add an opt-in token-protected remote calibration page for surface selection, numeric corner editing, blackout and scene TAKE.
- [x] Keep remote-network binding disabled by default and require a bearer token when enabled.
- [x] Add opt-in MIDI Learn for blackout, cue stepping and saved-scene TAKE; assignments persist across launches and all connected input sources are monitored.
- [x] Open multiple physical and virtual output windows, assign each surface to a saved output, and preserve output configuration in mapping/show files.
- [x] Select a 24/25/30/50/60 fps output rate and apply it to open projector windows.
- [x] Select a separate 5/10/15/30 fps editor and monitor preview rate.
- [x] Add per-edge smooth GPU blend falloff controls on output canvases.
- [ ] Validate overlap alignment and blend brightness with two physical projectors on the target installation.
- [ ] Add a dedicated Stream Deck integration; the local HTTP API can already be used by automation tools.

The HTTP API is available at `http://127.0.0.1:<port>/v1/status`. Controls support JSON POST and query-string GET forms for simple automation: `/v1/blackout/on`, `/v1/blackout/off`, `/v1/blackout/toggle`, `/v1/output/active?value=true|false`, `/v1/output/blackout/on|off|toggle`, `/v1/output/intensity?value=0.0-1.0`, `/v1/surface/<UUID>/active?value=true|false`, `/v1/surface/<UUID>/blackout?value=true|false`, `/v1/surface/<UUID>/intensity?value=0.0-1.0`, `/v1/surface/active?name=Church%20Cross&value=false`, `/v1/surface/blackout?name=Ceiling&value=true`, `/v1/surface/intensity?name=Ceiling&value=0.5`, `/v1/cue/next`, `/v1/cue/previous`, and `/v1/scene/<UUID>/take`. Named routes require a unique surface name and match case-insensitively. Equivalent POST requests use JSON such as `{"name":"Ceiling","active":false}` or `{"value":0.5}`. GET controls are provided for FreeShow's Send REST Command action, which accepts a URL, method, content type and payload; choose GET and leave the body fields empty. Master intensity scales rendered projector pixels and is shared by all output windows. The status response includes output-open and blackout state, master intensity, scene list, and each surface's output assignment, source reference, visibility and intensity. OSC listens on the configured localhost UDP port and accepts `/promap/blackout` (boolean or integer argument; empty toggles), `/promap/cue/next`, `/promap/cue/previous`, and `/promap/scene/<UUID>/take`. Enabling local-network access changes the HTTP listener to all interfaces; use a bearer token on API requests and visit `/calibrate?token=<token>` on a trusted network. The remote interface can adjust the four surface corners, trigger blackout and take scenes. HTTP is unencrypted, so remote access should be switched off when it is not needed.

## Validation record

- `xcodebuild test` passed 18 tests, including legacy-file compatibility, geometry undo, source-transform bounds, output-exclusion persistence, hue-effect bounds, recovery-session marker lifecycle and generated-source reference persistence. The test target emits a linker warning because the installed XCTest framework targets macOS 14 while the app deployment target is macOS 12; the app itself continues to target macOS 12.
- Debug builds compile for Intel x86-64 and Apple Silicon arm64 with Xcode 26.5 / the installed macOS SDK.
- The footer reports the measured frame rate for the active output. No target-hardware GPU performance, capture-card interoperability or church projector calibration run has been recorded; the 2019 Intel system still needs the two-video 60 FPS and extended-playback benchmarks above.
