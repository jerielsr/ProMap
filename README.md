# ProMap

ProMap is a native macOS projection and live media application. The repository is beginning with the rendering foundation from Phase 1 of the project brief.

## Current milestone

The app shell provides a Metal-backed composition preview, local image and video import, multiple opacity-controlled layers, discrete-GPU preference, and a fullscreen output window for a selected display. Projection geometry, masking, project files, scenes, and advanced inputs are planned for later phases; see [Development status](./docs/DEVELOPMENT.md).

## Requirements

- macOS 12 Monterey or later
- Xcode 14 or later, with the macOS SDK
- A Metal-capable GPU

The deployment target is macOS 12 to support the 2019 Intel MacBook Pro while keeping the initial implementation on stable SwiftUI, AppKit, Metal, and AVFoundation APIs. Apple Silicon remains supported by the same code path.

## Build and run

1. Open `ProMap.xcodeproj` in Xcode.
2. Select the **ProMap** scheme and a Mac destination.
3. Build and run.

The app prefers a non-low-power Metal device and disables automatic graphics switching in its application properties. On dual-GPU Intel MacBook Pros, macOS should therefore keep the discrete AMD GPU active while ProMap is running. The Diagnostics panel shows the Metal device selected by the renderer.

To project, connect the display, choose it from **Output**, and open the fullscreen output. Import media, add it to the layer stack, and start video playback from its media row.

## Documentation

- [Architecture and technical decisions](./docs/ARCHITECTURE.md)
- [Development status and phased plan](./docs/DEVELOPMENT.md)

Performance has not been profiled on the target Intel MacBook Pro. The current app is a foundation milestone and does not yet implement the projection mapping acceptance workflow.
