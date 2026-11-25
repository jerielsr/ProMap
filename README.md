# ProMap

ProMap is a native macOS projection-mapping and live-media application for multiple projector outputs. It includes the projection-mapping MVP, a live clip/layer workflow, scene/show persistence and GPU surface-colour effects.

## What works

- Import local images and videos, assign them directly to masks, or explicitly add them as layers.
- Add live camera or USB video capture sources through AVFoundation, with a low-rate preview thumbnail before assignment.
- Choose a supported capture resolution and frame rate, see connection state and resume a known source when its device reconnects.
- Browse imported media in a clip grid, assign a clip directly to the selected mask output, and control video playback.
- Loop local video clips or play once with the final frame held; recall the loop choice with shows and scenes.
- Scrub clips, step by frames, jump five seconds and set playback speed from 0.5× to 2×; scene and show recall preserve direct-mask video position and speed.
- Add shader-generated solid colours, animated gradients, starfields and cloud textures for ambient surfaces without importing a media file; adjust their colours, speed, scale and direction in the clip grid.
- Control source mute and volume from each video clip; video audio starts muted to avoid unexpected playback.
- Scale all video source levels with the master media volume setting.
- Route video audio to a selected macOS audio output device.
- Monitor local-video audio and add a per-file 0–500 ms delay to align it with the picture.
- Fade per-source video audio with visual opacity during scene transitions.
- Add quadrilateral, triangle, circle, ellipse and editable polygon projection surfaces; compose complex shapes from multiple masks.
- Duplicate a configured surface, then adjust the copy independently.
- Assign a different media source or the layer stack to each surface, so one display can contain separate cross and ceiling outputs.
- Build a cross or ceiling mask with editable polygons and multiple surfaces, each with its own source, mask and keystone on the same physical output.
- Drag four output corners for perspective correction, move each edge independently with its canvas handle, adjust individual edge widths, or use symmetric horizontal/vertical keystone steps.
- Create a Resolume-style vertical layer composition with one clip slot per track; load multiple local or live sources, reorder tracks, and adjust each source's zoom, position, rotation, skew, opacity and effects independently.
- Enable GPU mesh warping with adjustable 2×2 through 6×6 cell grids for curved or irregular surfaces.
- Enter precise normalized corner and mask coordinates; move, scale, rotate, reset, zoom, pan, snap and undo geometry edits.
- Edit masks in a dedicated canvas mode with larger numbered handles, one-click edge insertion, a numbered vertex selector, precision output-space nudging and contextual vertex removal.
- Build one mask from multiple included regions and subtractive cutouts, then edit each path with the numbered vertex tools.
- Soften polygon mask edges with a live feather control.
- Add feathered output-space exclusion polygons that remain fixed while mapped surfaces move.
- Adjust surface brightness, opacity, visibility and blackout independently; lock calibrated geometry.
- Adjust master output intensity and blackout independently from per-surface controls.
- Apply live per-surface contrast, saturation, exposure, gamma, RGB gains, grayscale, sepia and invert correction in Metal.
- Add ordered GPU surface and layer effects: blur, chroma/luma key, brightness, saturation, hue rotation, tint, sharpen, vignette, threshold, grayscale, sepia, invert and pixelation. Built-in soft-focus and green/blue-screen presets are included.
- Save, apply and delete custom effect-stack presets for reuse across layers and surfaces.
- Use grid, checkerboard, color bars and surface-outline calibration patterns.
- Save/load mapping presets, or save/load a show with media paths, layer playback states and named scenes.
- Use the separate Playback workspace to auto-preview cues, then TAKE them to Program with Cut, Dissolve or Dip to Black transitions and configurable timing.
- Autosave the active show after changes settle and every 30 seconds; keep a previous valid recovery snapshot.
- Open multiple fullscreen physical outputs or virtual 720p, 1080p, 4K or custom-size windows. Right-click an output to close it.
- Use Performance, Balanced and Full Detail rendering profiles to adjust output frame rate and editor preview refresh/resolution without changing mapping coordinates or projector output resolution.
- Open Diagnostics to inspect the active GPU, measured Metal frame rate and command time, process CPU and memory, cached texture allocation, media input rates and NDI/Syphon/output status.
- Optionally publish the currently selected projector output as a named video-only NDI source at up to 30 FPS.
- Receive two independent NDI video/audio sources when the NDI runtime is installed; assign each input to a different mask on one projector output. NDI clips include an input audio meter, mute/level and A/V delay controls; local videos include a meter and per-file A/V delay.
- Set the output window above the macOS menu bar from **ProMap → Settings**.
- Optionally enable HTTP and OSC controls for master blackout/intensity, per-mask active/blackout/intensity, cue stepping and scene TAKE; both are disabled by default. FreeShow can use GET REST commands on the same Mac, including mask controls by unique name or persistent UUID. Token-protected remote calibration can edit surface corners from a phone or tablet on a trusted local network.
- Optionally learn MIDI note/button controls for blackout, cue stepping and saved-scene TAKE; MIDI input is disabled by default.

The virtual output is a resizable window with a fixed nominal render resolution. It helps develop and preview mappings without a projector, but it does not add a virtual display to macOS.

## Requirements

- macOS 12 Monterey or later
- Xcode with the macOS SDK
- A Metal-capable GPU

The deployment target is macOS 12 for the 2019 Intel MacBook Pro. Apple Silicon uses the same renderer code. The renderer prefers a high-performance Metal device, but output performance has not been profiled on the target Intel hardware.

## Build and run

1. Open `ProMap.xcodeproj` in Xcode.
2. Select the **ProMap** scheme and a Mac destination.
3. Build and run.

Import media to the left-side clip grid. Choose a mask output as the assignment target, then click a clip to map it to that mask; video clips start playing when assigned. Use a clip's layer button to add a track to the composition grid. Select a layer track, then click another library clip to load it into that track's clip slot. Each track can be positioned, skewed, faded and processed independently; mask corners and vertices place that composition on the physical output. Build a cross from editable polygon masks and map a second source to another mask on the same projector for the ceiling. The **Playback** workspace provides auto-preview, Program/Preview monitors and TAKE transitions. **Diagnostics** reports frame cadence, GPU timing where the Metal driver provides it, CPU use and input status. **ProMap → Settings** contains General, Audio, NDI I/O, Syphon I/O, Network and MIDI pages. The app's File, Workspace, Playback and Output menus provide show, cue and live-output commands. FreeShow URLs for blackout, intensity and per-mask controls are listed under **Settings → Network**.

For a standalone build, use:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project ProMap.xcodeproj -scheme ProMap -configuration Debug \
  -destination 'platform=macOS' build CODE_SIGNING_ALLOWED=NO
```

Run the model tests with:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project ProMap.xcodeproj -scheme ProMap -configuration Debug \
  -destination 'platform=macOS' test CODE_SIGNING_ALLOWED=NO
```

## Documentation

- [Architecture and technical decisions](./docs/ARCHITECTURE.md)
- [Development status and remaining work](./docs/DEVELOPMENT.md)
- [Operator and calibration guide](./docs/USER_GUIDE.md)

JSON show files store absolute media paths. **Project → Export Portable Show Bundle** copies available media into a `.promapshow` folder and stores relative paths; loading the bundle resolves those files in place. Missing files remain linked to their original paths, and capture devices remain live references. When loading any show with missing files, ProMap can search a selected folder and relink unique filename matches. Independent physical and virtual output canvases with per-edge blend falloff and output-space exclusion masks are implemented. NDI video/audio input and video output are available when the NDI runtime is installed; NDI output sends video only at up to 30 FPS and needs receiver validation. Syphon input and output use the bundled universal framework. Dedicated Stream Deck feedback, NDI interoperability, target-projector validation and Intel performance profiling remain. Mesh warping supports configurable 2×2 through 6×6 cell grids.
