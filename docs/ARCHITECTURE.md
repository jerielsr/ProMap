# ProMap architecture

## Scope and hardware assumptions

The app targets macOS 12 Monterey and later, including the 2019 Intel MacBook Pro with a discrete AMD Radeon Pro GPU. It uses SwiftUI, AppKit, Metal/MetalKit, AVFoundation, Core Video, Core Audio, Core MIDI, ImageIO and Core Graphics. NDI remains optional: its macOS runtime is loaded dynamically when installed and is not bundled with ProMap. The renderer prefers a Metal device not marked low-power and disables automatic graphics switching in the app properties. AVPlayer audio can route to a Core Audio device selected in Settings. Presented FPS is measured per output and shown for the active output in the footer; discrete GPU selection and sustained performance still need verification on the target Mac.

The windowed virtual output uses the same Metal renderer and session as physical output windows. It sets a nominal drawable size such as 1920×1080 without creating a system display device. A physical output uses one fullscreen borderless window. Each view registers its own render session with the shared renderer, so the editor preview, staged scene preview, persistent program monitor and projector output can render independently while sharing the texture cache.

## Project layout

```text
ProMap.xcodeproj/
ProMap/
  ProMapApp.swift             SwiftUI entry point and application metadata
  MainWorkspaceView.swift     Media, mapping editor, surface controls, scenes and outputs
  MediaLibrary.swift          Imported sources, layer state, render session and scenes
  ProjectionModels.swift      Surface geometry, homography, mask and JSON document models
  RenderEngine.swift          Metal renderer, texture cache and output windows
  MIDIControl.swift           Core MIDI input, learning and persistent assignments
  ProMapShaders.metal         Surface warp, mask and calibration shaders
  Info.plist                  macOS deployment and graphics switching properties
ProMapTests/
  ProjectionModelTests.swift  Geometry, mask and serialization unit tests
docs/
  ARCHITECTURE.md
  DEVELOPMENT.md
  USER_GUIDE.md
```

## Runtime and saved models

- **MediaSource** owns either an ImageIO-decoded `CGImage`, an `AVPlayer` and `AVPlayerItemVideoOutput`, an optional `AVCaptureSession`, or an optional NDI receiver feeding the latest live frame. Video audio defaults to muted and exposes source mute/volume controls.
- **RenderLayer** references a media source with an independent name, enabled, solo and lock state, opacity, source-content transform and ordered effect stack. Duplicated layers share the same decoded `MediaSource` while keeping their visual controls independent.
- **ProjectionOutput** stores its display or virtual-canvas identity, resolution, per-edge blend falloff and post-warp exclusion paths.
- **ProjectionSurface** stores four normalized output corners, a main normalized source-space polygon plus up to seven additional included or subtractive mask paths, an optional source-content transform, optional mesh warp, output assignment, media path/layer-stack assignment, visibility, geometry lock, blackout, brightness, opacity, optional surface colour correction and an ordered effect stack.
- **RenderSession** publishes UI state and creates lock-protected snapshots for the Metal render callbacks, including a source catalog for direct surface assignments that must not enter the full-canvas layer stack. It also captures scene state and restores layers/surface controls without changing calibrated corners or mask vertices. A second session stages scenes; video sources are copied and muted in that preview session so live playback is not changed before TAKE.
- **MappingDocument** stores surface and output geometry/configuration. **ShowDocument** stores surfaces, output assignments, current layers, scene snapshots and playback positions. Both are versioned JSON documents; portable `.promapshow` folders can package local media and use bundle-relative paths.
- **ProjectorOutputController** owns either a borderless physical-screen window or a windowed virtual output. Both output views provide a right-click **Close Output** menu. The app setting can raise the active output to the AppKit screen-saver window level so it covers the menu bar and ordinary windows on that display.

## Rendering and geometry

```text
AVPlayer / ImageIO / AVCaptureSession
       │
       ├── video: AVPlayerItemVideoOutput → CVPixelBuffer
       ├── capture: AVCaptureVideoDataOutput → CVPixelBuffer
       ├── NDI: optional runtime receiver → CVPixelBuffer
       └── image: CGImage
                    │
           CVMetalTextureCache / MTKTextureLoader
                    │
          shared texture cache per media source
                    │
      surface assignment and layer selection
                    │
    quad rasterization → homography → source UV
                    │
           polygon mask and calibration
                    │
     alpha blend all surfaces into drawable
                    │
       preview / physical output / virtual output
```

All visible surfaces assigned to a particular output are drawn into one framebuffer for that output. The vertex shader rasterizes a four-corner quad. For each fragment, the renderer passes a CPU-computed 3×3 homography that maps normalized output coordinates back into normalized surface UV. A separate source-content transform applies zoom, position, rotation and flips only when sampling content; it does not change the output homography or mask paths. Source UV outside the texture is transparent. The shader unions included paths, subtracts cutout paths and applies adjustable feathering in surface UV before alpha blending the selected source layer(s). A separate output-UV exclusion mask is applied after surface warping so architectural exclusions remain fixed when a surface moves. One surface can instead use the existing ordered layer stack.

The homography is solved from four point pairs with pivoted Gaussian elimination. Corner edits are clamped to the output canvas and rejected if they create a degenerate or non-convex quad. Corner, source transform and mask positions are stored normalized or resolution-independent, so the same mapping can be used at a different drawable resolution. The editor supports numeric percent entry, stepped fine/medium/coarse horizontal and vertical keystone adjustment, grouped geometry undo/redo, whole-surface move/scale/rotation, zoom/pan, grid snapping and larger labeled handles. Surface and layer source content can be zoomed, repositioned, rotated and flipped separately from calibrated output geometry. Layer transforms apply after surface input transforms in source sampling, and are stored with the layer's show/scene state. Mask vertices are inserted at the chosen edge midpoint and can be selected from a numbered strip, precisely nudged in output space, numerically edited or deleted individually. Selecting or adding a mask path enters vertex editing for that path. The editor translates SwiftUI points to normalized canvas coordinates; the renderer translates between top-left-origin output coordinates and Metal clip space.

The Metal fragment shader samples each source, applies enabled layer effects followed by surface effects, then applies surface colour correction. Available effects include five-sample cross blur, chroma and luma key, brightness, saturation, hue rotation, tint, sharpen, vignette, threshold, grayscale, sepia, invert and pixelation. Built-in soft-focus, green-screen and blue-screen presets can be applied to either stack. Correction applies exposure, contrast, saturation, gamma, RGB gain and optional grayscale, sepia or invert looks before converting back to sRGB. Surface brightness and master output intensity scale corrected RGB; surface opacity scales output alpha. A surface blackout skips its draw, while master blackout skips all surfaces. Calibration mode replaces content with a grid, checkerboard, color bars or surface-outline pattern and is off by default. Zero master intensity skips surface rendering while keeping the output window black.

## Source assignment and scenes

The clip grid assigns a source directly to the selected surface; this does not add the source to the full-canvas layer stack. The stack button is an explicit action for layer composition. Local files use standardized paths as source references; capture devices use stable `capture://` references based on their AVFoundation unique IDs; procedural visuals use self-contained `generator://` references that store the preset and its editable colour/motion parameters. Solid colour, animated gradient, starfield and cloud visuals are evaluated in the Metal fragment shader, so they do not allocate a per-frame CPU bitmap or upload. The initial **Main Surface** renders only the ordered layer stack. Layer controls support naming, duplication, locking, forward/back reordering and multi-layer solo. Duplicates share one source decoder but retain independent visual state. Solo is preserved in show files; taking a scene clears solo, retains operator lock state, and recalls layer names and order. Other surfaces may reference one source, so different NDI feeds or videos can be independently keystoned and masked onto a cross and ceiling within the same display output. Each surface can also be assigned to a saved physical or virtual output ID; each output window renders only its assigned surfaces. Per-edge output blending applies a smooth falloff across selected normalized canvas edges. Output-level exclusion paths mask fixed areas after all surface transforms. Surfaces draw in list order. A scene stores layer order, names, enabled state, opacity, content transforms, playback position, per-source audio state and layer effects, plus non-geometric surface state (source assignment, visibility, blackout, brightness, opacity, mask inversion, colour correction and surface effects), including direct-mask source mute, volume and NDI delay. Show files also store audio state for media sources outside the layer stack. Recall crossfades layer opacity and source audio while leaving corner and mask geometry unchanged. The captured scene list also acts as a simple forward/back cue sequence. Autosave runs every 30 seconds and after a short debounce when the show changes. Each successful write keeps the previous valid snapshot; launch recovery offers the newest readable copy.

Mapping presets save surfaces and output configuration. JSON show files save surfaces, output assignments/configuration, active layers, scenes and absolute source paths. Portable `.promapshow` bundles store `Show.json` with paths relative to a `Media` directory and copy available local files. Capture references remain live device IDs and missing files retain their old paths. When a show contains missing files, ProMap can search one selected folder and relink unique filename matches. Ambiguous or missing matches remain offline; bookmark-based access is not implemented.

## Coordinate systems

- **Source pixels:** decoded image/video pixels, top-left origin.
- **Source UV:** normalized `[0, 1] × [0, 1]`, top-left origin.
- **Output UV:** normalized final canvas coordinates, top-left origin.
- **Surface corners:** four output UV positions ordered top-left, top-right, bottom-right, bottom-left.
- **Mask vertices:** normalized surface UV positions ordered around polygon paths. Concave polygons, multiple included regions and subtractive cutouts are supported; post-warp global output exclusions are not.
- **Physical output:** drawable pixels from the selected `NSScreen`.
- **Virtual output:** fixed nominal drawable resolution, displayed inside a resizable 16:9 macOS window.
- **Editor viewport:** SwiftUI points. Handle positions are normalized against the aspect-fitted preview canvas; Retina scale is not persisted.
- **Metal clip space:** x/y in `[-1, 1]`, with positive Y upward. The surface vertex shader performs the output UV conversion.

## Threading and resource lifetime

File imports decode away from the render callback. AVFoundation supplies video frames asynchronously. Renderer callbacks take a locked `RenderSnapshot`, read shared media textures through the texture cache, then issue one command buffer for each drawable. CVMetalTexture wrappers are retained until their command buffer completes. Texture lookup and pruning use a lock because the preview and output may render concurrently. Unused-texture collection scans active source catalogs at most once every two seconds instead of rebuilding source dictionaries and sets for every displayed frame.

Scene fades publish a bounded sequence of opacity snapshots on the main queue. Scene preview copies retain the saved playback position and paused/playing state. Output windows can be resized while the virtual drawable stays at the selected nominal resolution.

## External control

`ExternalControlManager` uses Network.framework TCP and UDP listeners. HTTP/OSC are disabled by default and bind to IPv4 loopback. HTTP supports JSON POST controls plus query-string GET controls for FreeShow's REST action, including master blackout/intensity, UUID- or uniquely named per-surface active/blackout/intensity, cue stepping and scene recall. Same-Mac automation origins are permitted for CORS; other origins are rejected. The operator can explicitly enable HTTP LAN access; that listener then binds all IPv4 interfaces and requires a bearer token (the browser calibration page receives it as a one-time URL query and keeps it in session storage). Corner requests pass through the same geometry validation and lock checks as native edits. The remote page uses unencrypted HTTP, so LAN access is intended for a trusted network and should be disabled after use.

## Known risks and limits

1. **GPU choice and performance are unmeasured on the target hardware.** Selection preference does not prove that the AMD device is active or that 60 FPS is sustained.
2. **Video sharing and frame pacing need stress testing.** Measure two 1080p videos, preview plus output, and long playback on the 2019 Intel system.
3. **Polygon masks are available at both surface and output levels.** Surface paths support included regions and subtractive cutouts. Output masks provide post-warp exclusions; image-based alpha masks are not implemented.
4. **Geometry editing supports projective quads, adjustable mesh warps, source transforms and polygon masks.** Mesh grids offer 2×2 through 6×6 cells with draggable interior controls. Changing grid density interpolates existing offsets. Numeric percent entry, source zoom/position/rotation/flips, move/scale/rotate controls, snapping and undo/redo are available.
5. **Effects are an initial GPU-accelerated slice.** The blur is a lightweight five-sample cross filter and chroma key uses RGB distance. Layer and surface stacks plus reusable user presets are available; spatial filters, parameter animation and calibrated projector profiling remain unimplemented.
6. **Capture support is an initial live input path.** USB/camera capture uses the AVFoundation video output callback and Metal texture cache. Device format selection, a throttled media-library thumbnail and reconnect are implemented; multi-device hardware validation remains.
7. **Media path portability depends on collection.** Portable show bundles copy available local files and use relative paths; missing media and live capture references remain external. Security-scoped bookmarks are not implemented.
8. **Display topology changes need dedicated handling.** Reconnect and resolution-change behavior have not been tested against a physical projector.
9. **NDI and Syphon exchange live video.** NDI input discovery, manual address entry, bandwidth selection, hold-last/black fallback, muted audio input, audio level/delay, and named video output are implemented. The installed NDI runtime remains optional and is loaded dynamically. Syphon input discovery, show restoration, and output publishing use the bundled universal Metal framework. Incoming Syphon IOSurfaces are wrapped as CVPixelBuffers and imported through the existing Metal texture cache; the selected projector drawable is published directly, only when a Syphon client is connected. Validate NDI receivers and Syphon peers on the target Intel Mac before a live deployment.
10. **Remote HTTP is unencrypted.** The token protects routes from casual access but can be observed on an untrusted network; use loopback by default and enable LAN control only on a trusted private network.
