# ProMap architecture

## Scope and hardware assumptions

The first milestone implements the rendering foundation: native application shell, GPU selection, local image and video playback, basic layer compositing, fullscreen display output, and basic diagnostics. Projection mapping, persistent shows, and live input integrations follow in later phases.

The minimum supported system is **macOS 12 Monterey**. The primary target is a 2019 16-inch Intel MacBook Pro with a dedicated AMD Radeon Pro GPU and an external projector. The implementation uses no Apple Silicon-only APIs. On systems with multiple Metal devices, the renderer chooses the first device that is not marked low-power, then falls back to another available Metal device. `NSSupportsAutomaticGraphicsSwitching` is disabled so macOS does not switch away from the high-performance GPU while the app runs. If no device can be created, the UI remains available and reports that rendering is unavailable.

macOS may use VideoToolbox's own decode scheduling and memory path; ProMap does not assume that decode and Metal rendering use the same physical GPU. Video decoding, CVPixelBuffer-to-Metal texture sharing, and end-to-end frame pacing still need profiling on the target hardware before performance claims can be made.

## Frameworks and dependencies

| Area | Frameworks |
| --- | --- |
| App and display windows | SwiftUI, AppKit |
| Rendering | Metal, MetalKit |
| Video playback and decode | AVFoundation, Core Video, VideoToolbox (through AVFoundation) |
| Still image decoding | ImageIO, Core Graphics |

Phase 1 has no third-party dependencies. NDI, Syphon, and Stream Deck SDKs are not included. Before those phases, confirm each vendor's current Intel/macOS support, license terms, redistribution rules, and signing/notarization constraints. Keep any such integration behind an optional adapter so a missing SDK does not prevent the core app from building.

## Project layout

```text
ProMap.xcodeproj/
ProMap/
  ProMapApp.swift             SwiftUI entry point and application metadata
  MainWorkspaceView.swift     Library, composition preview, layer controls, output controls
  MediaLibrary.swift          Imported source models and AVPlayer ownership
  RenderEngine.swift          Metal device, frame rendering, texture cache, output window
  ProMapShaders.metal         Full-canvas textured quad compositing shader
  Info.plist                 macOS deployment and graphics switching properties
docs/
  ARCHITECTURE.md
  DEVELOPMENT.md
```

As features grow, split the runtime into `Sources`, `Layers`, `Compositions`, `Surfaces`, `Outputs`, `Displays`, `Scenes`, and `ShowDocument` modules. The first release keeps the number of files modest while preserving those boundaries in its models.

## Core data model

- **MediaSource** owns one imported URL and its decoded representation: an `AVPlayer` plus `AVPlayerItemVideoOutput` for video, or an immutable `CGImage` for a still image. Layers can refer to the same source object.
- **RenderLayer** assigns a source to a composition with independent enabled and opacity values. Phase 1 draws layers in array order over a single full-frame composition.
- **RenderSession** is the current composition state. It publishes UI changes and provides a locked snapshot at a frame boundary to the renderer.
- **Surface**, **Output**, **Display**, **Scene**, and **Show** are planned entities. Phase 2 adds independently mapped surfaces; Phase 3 adds scene and show persistence. Keeping these distinct prevents physical calibration from being coupled to source transforms or scene recall.

## Rendering pipeline

```text
AVPlayer / ImageIO
       │
       ├── video: AVPlayerItemVideoOutput → CVPixelBuffer
       └── image: CGImage
                    │
           CVMetalTextureCache / MTKTextureLoader
                    │
        shared source texture cache (per MediaSource)
                    │
         ordered layer compositing in Metal
                    │
           composition render destination
             ┌──────┴────────┐
       editor preview    fullscreen display
```

The first milestone renders each layer as a full-canvas textured triangle. A single command buffer composites all active layers, with source alpha and per-layer opacity, into each view's drawable. The video frame texture is shared by preview and output views; the renderer retains the most recent frame so both can display it. `CVMetalTextureCache` wraps decoded BGRA pixel buffers without an explicit CPU pixel copy. Still-image textures are uploaded once and retained while at least one layer uses that source, then removed from the renderer cache.

Phase 2 will add a logical output canvas and surface pass. A surface will sample a source/composition texture through four-corner or mesh geometry, then apply a polygon mask in the output coordinate space. All surfaces assigned to a projector will be drawn into one final framebuffer; the physical output remains one fullscreen window rather than one window per surface.

## Coordinate systems

- **Source pixels:** decoded image/video pixels, origin at the top-left.
- **Source UV:** normalised `[0, 1] × [0, 1]`, origin at the top-left. Metal texture sampling converts the full-screen vertex's lower-left NDC origin to this convention.
- **Composition:** normalised canvas coordinates, origin at the top-left, independent of physical pixel resolution.
- **Surface geometry:** Phase 2 vertices stored in normalised output coordinates, so calibration survives resolution changes.
- **Physical output:** drawable pixels in the selected `NSScreen`'s backing resolution.
- **Editor viewport:** SwiftUI/AppKit points. Convert through the viewport's drawable scale before writing geometry; do not persist Retina-scaled coordinates.
- **Metal clip space:** `x` and `y` in `[-1, 1]`, with positive Y upward. Convert explicitly at the renderer boundary.

The Phase 1 full-canvas path only performs the source UV to Metal clip-space conversion. Mapping code must centralise the remaining transforms and account for the opposite vertical origins of AppKit and Metal.

## Threading and frame updates

SwiftUI model edits happen on the main thread. The renderer takes a locked immutable session snapshot before issuing draw calls, and does not read a mutable SwiftUI collection while it is being changed. AVPlayer decodes asynchronously. Render callbacks use a Metal command queue, and `CVMetalTextureCache` avoids CPU copies for decoded frames. No file loading or synchronous media probing occurs in the render callback.

The media import path creates player objects and still-image references away from the per-frame path. Future thumbnail generation, project loading, and capture/network input must remain asynchronous. Mapping edits should become immutable frame snapshots swapped at frame boundaries to avoid races and partial geometry updates.

## Risks and constraints

1. **Discrete GPU selection is a request, not a performance guarantee.** Device enumeration and the graphics-switching property make the choice explicit, but verify the active GPU and power state on the 2019 Intel target.
2. **Decoded frame sharing and frame pacing are unprofiled.** Measure two simultaneous 1080p sources, preview plus output, and long playback on the target machine. Validate CVPixelBuffer lifetime and memory use under repeated clip switching.
3. **The first renderer is a composition foundation, not a mapper.** It has no projective warp, mask, per-surface brightness, calibration pattern, or saved mapping yet. Do not use it as the finished church installation workflow.
4. **Media support depends on system codecs.** AVFoundation handles supported video codecs and ImageIO handles still images. Unsupported codec warnings, animated GIF playback, and ProRes alpha verification remain follow-up work.
5. **Display topology can change during a service.** Phase 1 lets the operator choose a connected screen and close the output. Reconnection and output migration behavior need dedicated handling and tests.
6. **Third-party live inputs carry integration and licensing risk.** NDI/Syphon work remains optional and gated on vendor SDK compatibility and license review.

## Licensing and distribution

The initial implementation links only Apple SDK frameworks and has no external runtime dependency. Review the applicable Apple developer agreement and distribution/signing requirements when preparing a release. Do not bundle an NDI SDK until its current license and redistribution requirements have been confirmed. Keep SDK notice and license files with any future third-party integration.
