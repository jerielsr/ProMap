import AppKit
import AVFoundation
import Combine
import CoreVideo
import Metal
import MetalKit
import QuartzCore

final class MetalRenderer: NSObject, ObservableObject, MTKViewDelegate {
    @Published private(set) var gpuName = "Metal device unavailable"
    @Published private(set) var renderingAvailable = false
    @Published private(set) var presentedFPS = 0.0
    @Published private(set) var presentedFPSByOutputID: [UUID: Double] = [:]
    @Published private(set) var latePresentationPercentByOutputID: [UUID: Double] = [:]
    @Published private(set) var gpuTimeMillisecondsByOutputID: [UUID: Double] = [:]

    private(set) var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var fallbackTexture: MTLTexture?
    private var textureCache: CVMetalTextureCache?
    private struct ViewRenderTarget {
        let session: RenderSession
        let outputID: UUID
        let isProjectorOutput: Bool
    }
    private var sessionsByView: [ObjectIdentifier: ViewRenderTarget] = [:]
    private let sessionsLock = NSLock()
    private let texturePruneLock = NSLock()
    private var lastTexturePruneTime: CFTimeInterval = 0
    private let frameRateLock = NSLock()
    private let gpuTimingLock = NSLock()
    private struct FrameRateCounter {
        var outputID: UUID
        var intervalStart: CFTimeInterval
        var frameCount: Int
        var measuredFPS: Double
        var lastSampleTime: CFTimeInterval
        var targetFramesPerSecond: Double
        var lastPresentedTime: CFTimeInterval?
        var measuredIntervals: Int
        var lateIntervals: Int
        var latePresentationPercent: Double
    }
    private var frameRateCounters: [ObjectIdentifier: FrameRateCounter] = [:]
    private struct GPUTimingCounter {
        var outputID: UUID
        var windowStart: CFTimeInterval
        var totalMilliseconds: Double
        var sampleCount: Int
        var averageMilliseconds: Double?
        var lastSampleTime: CFTimeInterval
    }
    private var gpuTimingCounters: [ObjectIdentifier: GPUTimingCounter] = [:]

    var usesLowPowerGPU: Bool? { device?.isLowPower }

    private struct CachedTexture {
        let texture: MTLTexture
        let cvTexture: CVMetalTexture?
        let frameSequence: UInt64?

        init(texture: MTLTexture, cvTexture: CVMetalTexture?, frameSequence: UInt64? = nil) {
            self.texture = texture
            self.cvTexture = cvTexture
            self.frameSequence = frameSequence
        }
    }

    private let textureLock = NSLock()
    private var textures: [UUID: CachedTexture] = [:]
    private var failedTextureIDs: Set<UUID> = []

    override init() {
        super.init()

        let devices = MTLCopyAllDevices()
        guard let selectedDevice = devices.first(where: { !$0.isLowPower })
            ?? devices.first
            ?? MTLCreateSystemDefaultDevice()
        else {
            gpuName = "No compatible Metal GPU found"
            return
        }

        device = selectedDevice
        gpuName = selectedDevice.name
        commandQueue = selectedDevice.makeCommandQueue()

        if let commandQueue = commandQueue {
            _ = commandQueue
        } else {
            gpuName = "Could not create a Metal command queue"
            return
        }

        var createdTextureCache: CVMetalTextureCache?
        let cacheStatus = CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            selectedDevice,
            nil,
            &createdTextureCache
        )
        if cacheStatus == kCVReturnSuccess {
            textureCache = createdTextureCache
        }

        let fallbackDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        fallbackDescriptor.usage = .shaderRead
        if let texture = selectedDevice.makeTexture(descriptor: fallbackDescriptor) {
            let white: [UInt8] = [255, 255, 255, 255]
            white.withUnsafeBufferPointer { buffer in
                if let base = buffer.baseAddress {
                    texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: base, bytesPerRow: 4)
                }
            }
            fallbackTexture = texture
        }

        guard
            let library = selectedDevice.makeDefaultLibrary(),
            let vertexFunction = library.makeFunction(name: "surfaceVertex"),
            let fragmentFunction = library.makeFunction(name: "texturedFragment")
        else {
            gpuName = "Metal shader library could not be loaded"
            return
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        do {
            pipeline = try selectedDevice.makeRenderPipelineState(descriptor: descriptor)
            renderingAvailable = true
        } catch {
            gpuName = "Metal pipeline error: \(error.localizedDescription)"
        }
    }

    func makeView(
        session: RenderSession,
        outputID: UUID = ProjectionOutput.mainID,
        frame: CGRect = .zero,
        preferredFramesPerSecond: Int = 60,
        previewScale: Double = 1,
        isProjectorOutput: Bool = false,
        onClose: (() -> Void)? = nil
    ) -> MTKView {
        let view = OutputMetalView(frame: frame, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.isProjectorView = isProjectorOutput
        view.setPreviewScale(previewScale)
        view.framebufferOnly = !(isProjectorOutput && (NDIOutputService.shared.isEnabled || SyphonOutputService.shared.isEnabled))
        view.preferredFramesPerSecond = preferredFramesPerSecond
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.closeOutput = onClose
        updateSession(for: view, session: session, outputID: outputID, isProjectorOutput: isProjectorOutput)
        view.delegate = self
        return view
    }

    func updateSession(
        for view: MTKView,
        session: RenderSession,
        outputID: UUID = ProjectionOutput.mainID,
        isProjectorOutput: Bool = false,
        previewScale: Double = 1
    ) {
        sessionsLock.lock()
        sessionsByView[ObjectIdentifier(view)] = ViewRenderTarget(
            session: session,
            outputID: outputID,
            isProjectorOutput: isProjectorOutput
        )
        sessionsLock.unlock()
        (view as? OutputMetalView)?.setPreviewScale(previewScale)
    }

    func releaseView(_ view: MTKView) {
        sessionsLock.lock()
        sessionsByView.removeValue(forKey: ObjectIdentifier(view))
        sessionsLock.unlock()
        gpuTimingLock.lock()
        gpuTimingCounters.removeValue(forKey: ObjectIdentifier(view))
        let remainingGPUTimes = Self.gpuTimesByOutput(gpuTimingCounters)
        gpuTimingLock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.gpuTimeMillisecondsByOutputID = remainingGPUTimes
        }
        frameRateLock.lock()
        frameRateCounters.removeValue(forKey: ObjectIdentifier(view))
        let currentMaximum = frameRateCounters.values.map(\.measuredFPS).max() ?? 0
        var ratesByOutput: [UUID: Double] = [:]
        var latePercentByOutput: [UUID: Double] = [:]
        for sample in frameRateCounters.values {
            ratesByOutput[sample.outputID] = max(ratesByOutput[sample.outputID] ?? 0, sample.measuredFPS)
            latePercentByOutput[sample.outputID] = max(latePercentByOutput[sample.outputID] ?? 0, sample.latePresentationPercent)
        }
        frameRateLock.unlock()
        DispatchQueue.main.async { [weak self] in
            self?.presentedFPS = currentMaximum
            self?.presentedFPSByOutputID = ratesByOutput
            self?.latePresentationPercentByOutputID = latePercentByOutput
        }
        view.isPaused = true
        view.delegate = nil
    }

    private func renderTarget(for view: MTKView) -> ViewRenderTarget? {
        sessionsLock.lock()
        defer { sessionsLock.unlock() }
        return sessionsByView[ObjectIdentifier(view)]
    }

    private func activeSessions() -> [RenderSession] {
        sessionsLock.lock()
        let entries = Array(sessionsByView.values.map(\.session))
        sessionsLock.unlock()
        var seen = Set<ObjectIdentifier>()
        return entries.filter { seen.insert(ObjectIdentifier($0)).inserted }
    }

    func estimatedTextureMemoryBytes() -> UInt64 {
        textureLock.lock()
        defer { textureLock.unlock() }
        return textures.values.reduce(UInt64(0)) { total, cached in
            total + UInt64(cached.texture.allocatedSize)
        }
    }

    private static func gpuTimesByOutput(_ counters: [ObjectIdentifier: GPUTimingCounter]) -> [UUID: Double] {
        var times: [UUID: Double] = [:]
        for sample in counters.values {
            guard let average = sample.averageMilliseconds else { continue }
            times[sample.outputID] = max(times[sample.outputID] ?? 0, average)
        }
        return times
    }

    private func recordGPUTime(_ milliseconds: Double, for viewID: ObjectIdentifier, outputID: UUID) {
        let now = CACurrentMediaTime()
        gpuTimingLock.lock()
        var counter = gpuTimingCounters[viewID] ?? GPUTimingCounter(
            outputID: outputID,
            windowStart: now,
            totalMilliseconds: 0,
            sampleCount: 0,
            averageMilliseconds: nil,
            lastSampleTime: now
        )
        counter.outputID = outputID
        counter.totalMilliseconds += milliseconds
        counter.sampleCount += 1
        counter.lastSampleTime = now
        let elapsed = now - counter.windowStart
        if elapsed >= 0.5 {
            counter.averageMilliseconds = counter.totalMilliseconds / Double(max(counter.sampleCount, 1))
            counter.windowStart = now
            counter.totalMilliseconds = 0
            counter.sampleCount = 0
        }
        gpuTimingCounters[viewID] = counter
        gpuTimingCounters = gpuTimingCounters.filter { now - $0.value.lastSampleTime <= 2 }
        let timesByOutput = Self.gpuTimesByOutput(gpuTimingCounters)
        gpuTimingLock.unlock()
        if elapsed >= 0.5 {
            DispatchQueue.main.async { [weak self] in
                self?.gpuTimeMillisecondsByOutputID = timesByOutput
            }
        }
    }

    private func pruneUnusedTexturesIfNeeded() {
        let now = CACurrentMediaTime()
        texturePruneLock.lock()
        guard now - lastTexturePruneTime >= 2 else {
            texturePruneLock.unlock()
            return
        }
        lastTexturePruneTime = now
        texturePruneLock.unlock()

        let snapshots = activeSessions().map { $0.snapshot() }
        let sourceIDs = Set(snapshots.flatMap { snapshot in
            let sourceByReference = Dictionary(
                snapshot.sourceCatalog.map { ($0.reference, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let directSurfaceIDs = snapshot.surfaces.compactMap { surface -> UUID? in
                guard let reference = surface.sourcePath else { return nil }
                return sourceByReference[reference]?.id
            }
            return snapshot.layers.map { $0.source.id } + directSurfaceIDs
        })
        pruneUnusedTextures(keeping: sourceIDs)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard
            let commandQueue,
            let target = renderTarget(for: view),
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let passDescriptor = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable
        else { return }

        passDescriptor.colorAttachments[0].loadAction = .clear
        passDescriptor.colorAttachments[0].storeAction = .store
        passDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor) else {
            return
        }

        if let pipeline {
            let snapshot = target.session.snapshot()
            pruneUnusedTexturesIfNeeded()
            if !snapshot.isBlackout && snapshot.outputIntensity > 0 {
                encoder.setRenderPipelineState(pipeline)
                var inFlightCVTextures: [CVMetalTexture] = []
                let pattern = snapshot.calibrationPattern
                let hasSoloLayers = snapshot.layers.contains { $0.isEnabled && $0.isSolo }
                let enabledLayers = snapshot.layers.filter { $0.isEnabled && (!hasSoloLayers || $0.isSolo) }
                let layersByReference = Dictionary(grouping: snapshot.layers, by: { $0.source.reference })
                let sourceByReference = Dictionary(
                    snapshot.sourceCatalog.map { ($0.reference, $0) },
                    uniquingKeysWith: { first, _ in first }
                )
                let outputSize = SIMD2<Float>(Float(drawable.texture.width), Float(drawable.texture.height))
                let outputConfiguration = snapshot.outputs.first(where: { $0.id == target.outputID }) ?? .main
                var edgeBlendWidths = SIMD4<Float>(
                    Float(outputConfiguration.blendLeft),
                    Float(outputConfiguration.blendRight),
                    Float(outputConfiguration.blendTop),
                    Float(outputConfiguration.blendBottom)
                )
                withUnsafeBytes(of: &edgeBlendWidths) { bytes in
                    if let base = bytes.baseAddress {
                        encoder.setFragmentBytes(base, length: bytes.count, index: 13)
                    }
                }
                var outputMaskPoints: [SIMD2<Float>] = []
                var outputMaskPointCounts: [UInt32] = []
                for path in (outputConfiguration.exclusionPaths ?? []).prefix(8) where (3...32).contains(path.points.count) {
                    outputMaskPoints.append(contentsOf: path.points.prefix(32).map {
                        SIMD2<Float>(Float($0.x), Float($0.y))
                    })
                    outputMaskPointCounts.append(UInt32(min(path.points.count, 32)))
                }
                if outputMaskPoints.isEmpty {
                    outputMaskPoints = [SIMD2<Float>(repeating: 0)]
                    outputMaskPointCounts = [0]
                }
                outputMaskPoints.withUnsafeBytes { bytes in
                    if let base = bytes.baseAddress {
                        encoder.setFragmentBytes(base, length: bytes.count, index: 19)
                    }
                }
                outputMaskPointCounts.withUnsafeBytes { bytes in
                    if let base = bytes.baseAddress {
                        encoder.setFragmentBytes(base, length: bytes.count, index: 20)
                    }
                }
                var outputMaskCount = UInt32(outputMaskPointCounts.first == 0 ? 0 : outputMaskPointCounts.count)
                encoder.setFragmentBytes(&outputMaskCount, length: MemoryLayout<UInt32>.size, index: 21)
                var outputMaskFeather = Float(outputConfiguration.exclusionFeather ?? 0)
                encoder.setFragmentBytes(&outputMaskFeather, length: MemoryLayout<Float>.size, index: 22)
                for surface in snapshot.surfaces
                    where (surface.outputID ?? ProjectionOutput.mainID) == target.outputID
                        && surface.isVisible && !surface.isBlackout {
                    let content = surface.contentTransform?.sanitized() ?? .identity
                    var contentParameters = SIMD4<Float>(
                        Float(content.zoomX),
                        Float(content.zoomY),
                        Float(content.offsetX),
                        Float(content.offsetY)
                    )
                    encoder.setFragmentBytes(&contentParameters, length: MemoryLayout<SIMD4<Float>>.size, index: 16)
                    var contentRotation = Float(content.rotationDegrees * .pi / 180)
                    encoder.setFragmentBytes(&contentRotation, length: MemoryLayout<Float>.size, index: 17)
                    var contentFlips: UInt32 = 0
                    if content.isFlippedHorizontally { contentFlips |= 1 }
                    if content.isFlippedVertically { contentFlips |= 2 }
                    encoder.setFragmentBytes(&contentFlips, length: MemoryLayout<UInt32>.size, index: 18)
                    guard surface.hasUsableGeometry,
                          let transform = ProjectiveTransform.make(
                            from: surface.corners,
                            to: ProjectionSurface.rectanglePoints
                          ) else { continue }

                    let assignedLayers: [RenderLayer]
                    if pattern != .off {
                        assignedLayers = []
                    } else if let sourcePath = surface.sourcePath {
                        if let sourceLayers = layersByReference[sourcePath] {
                            assignedLayers = sourceLayers.filter { $0.isEnabled && (!hasSoloLayers || $0.isSolo) }
                        } else if let source = sourceByReference[sourcePath] {
                            assignedLayers = [RenderLayer(source: source)]
                        } else {
                            assignedLayers = []
                        }
                    } else if surface.usesLayerStack {
                        assignedLayers = enabledLayers
                    } else {
                        assignedLayers = []
                    }

                    let drawSources: [(CachedTexture, Float, [SurfaceEffect], VisualGenerator?, SurfaceContentTransform)]
                    if pattern != .off {
                        guard let fallbackTexture else { continue }
                        drawSources = [(CachedTexture(texture: fallbackTexture, cvTexture: nil), 1, [], nil, .identity)]
                    } else {
                        drawSources = assignedLayers.compactMap { layer in
                            guard layer.opacity > 0, let cached = texture(for: layer.source) else { return nil }
                            if let cvTexture = cached.cvTexture { inFlightCVTextures.append(cvTexture) }
                            return (
                                cached,
                                Float(layer.opacity),
                                layer.effectStack ?? [],
                                layer.source.generator,
                                layer.contentTransform?.sanitized() ?? .identity
                            )
                        }
                    }
                    guard !drawSources.isEmpty else { continue }

                    let homography = transform.map(Float.init)
                    let meshEnabled = surface.meshWarp != nil
                    let vertexData = meshEnabled ? meshVertices(for: surface) : quadVertices(for: surface)
                    guard !vertexData.isEmpty else { continue }
                    let maskPaths = [
                        ProjectionMaskPath(name: "Main", operation: .include, points: surface.maskPoints)
                    ] + (surface.additionalMaskPaths ?? []).prefix(7)
                    var flattenedMaskPoints: [SIMD2<Float>] = []
                    var maskPathPointCounts: [UInt32] = []
                    var maskPathOperations: [UInt32] = []
                    for maskPath in maskPaths.prefix(8) where maskPath.points.count >= 3 {
                        flattenedMaskPoints.append(contentsOf: maskPath.points.prefix(32).map {
                            SIMD2<Float>(Float($0.x), Float($0.y))
                        })
                        maskPathPointCounts.append(UInt32(min(maskPath.points.count, 32)))
                        maskPathOperations.append(maskPath.operation == .exclude ? 1 : 0)
                    }
                    guard !flattenedMaskPoints.isEmpty, !maskPathPointCounts.isEmpty else { continue }

                    vertexData.withUnsafeBytes { bytes in
                        if let base = bytes.baseAddress {
                            encoder.setVertexBytes(base, length: bytes.count, index: 0)
                        }
                    }
                    homography.withUnsafeBytes { bytes in
                        if let base = bytes.baseAddress {
                            encoder.setFragmentBytes(base, length: bytes.count, index: 0)
                        }
                    }
                    var outputSizeBytes = outputSize
                    withUnsafeBytes(of: &outputSizeBytes) { bytes in
                        if let base = bytes.baseAddress {
                            encoder.setFragmentBytes(base, length: bytes.count, index: 1)
                        }
                    }
                    flattenedMaskPoints.withUnsafeBytes { bytes in
                        if let base = bytes.baseAddress {
                            encoder.setFragmentBytes(base, length: bytes.count, index: 2)
                        }
                    }
                    var maskPathCount = UInt32(maskPathPointCounts.count)
                    encoder.setFragmentBytes(&maskPathCount, length: MemoryLayout<UInt32>.size, index: 3)
                    maskPathPointCounts.withUnsafeBytes { bytes in
                        if let base = bytes.baseAddress {
                            encoder.setFragmentBytes(base, length: bytes.count, index: 14)
                        }
                    }
                    maskPathOperations.withUnsafeBytes { bytes in
                        if let base = bytes.baseAddress {
                            encoder.setFragmentBytes(base, length: bytes.count, index: 15)
                        }
                    }
                    var maskFeather = Float(surface.maskFeather ?? 0)
                    encoder.setFragmentBytes(&maskFeather, length: MemoryLayout<Float>.size, index: 11)
                    var useMeshWarp: UInt32 = meshEnabled ? 1 : 0
                    encoder.setFragmentBytes(&useMeshWarp, length: MemoryLayout<UInt32>.size, index: 12)

                    let colorCorrection = surface.colorCorrection?.sanitized() ?? .neutral
                    var colorAdjustments = SIMD4<Float>(
                        Float(colorCorrection.contrast),
                        Float(colorCorrection.saturation),
                        Float(colorCorrection.exposure),
                        Float(colorCorrection.gamma)
                    )
                    var rgbGain = SIMD3<Float>(
                        Float(colorCorrection.redGain),
                        Float(colorCorrection.greenGain),
                        Float(colorCorrection.blueGain)
                    )
                    var colorLooks: UInt32 = 0
                    if colorCorrection.isGrayscale { colorLooks |= 1 }
                    if colorCorrection.isSepia { colorLooks |= 2 }
                    if colorCorrection.isInverted { colorLooks |= 4 }
                    encoder.setFragmentBytes(&colorAdjustments, length: MemoryLayout<SIMD4<Float>>.size, index: 5)
                    encoder.setFragmentBytes(&rgbGain, length: MemoryLayout<SIMD3<Float>>.size, index: 6)
                    encoder.setFragmentBytes(&colorLooks, length: MemoryLayout<UInt32>.size, index: 7)

                    let surfaceEffects = (surface.effectStack ?? []).filter(\.isEnabled)
                    for (cachedTexture, layerOpacity, layerEffects, generator, layerContent) in drawSources {
                        let activeEffects = (layerEffects.filter(\.isEnabled) + surfaceEffects)
                            .prefix(SurfaceEffect.maximumStackSize * 2)
                        var effectParameters: [SIMD4<Float>] = activeEffects.map { effect in
                            let kind: Float
                            let primary: Double
                            switch effect.kind {
                            case .blur:
                                kind = 1
                                primary = effect.radius
                            case .chromaKey:
                                kind = 2
                                primary = effect.threshold
                            case .brightness:
                                kind = 3
                                primary = effect.threshold * 2
                            case .saturation:
                                kind = 4
                                primary = effect.threshold * 2
                            case .grayscale: kind = 5; primary = 0
                            case .sepia: kind = 6; primary = 0
                            case .invert: kind = 7; primary = 0
                            case .pixelate:
                                kind = 8
                                primary = max(effect.radius, 1)
                            case .hueRotation:
                                kind = 9
                                primary = effect.radius
                            case .tint:
                                kind = 10
                                primary = effect.threshold
                            case .sharpen:
                                kind = 11
                                primary = effect.radius
                            case .vignette:
                                kind = 12
                                primary = effect.threshold
                            case .lumaKey:
                                kind = 13
                                primary = effect.threshold
                            case .threshold:
                                kind = 14
                                primary = effect.threshold
                            }
                            return SIMD4<Float>(kind, Float(primary), Float(effect.softness), 0)
                        }
                        var effectColors: [SIMD4<Float>] = activeEffects.map { effect in
                            SIMD4<Float>(
                                Float(effect.keyColor.red),
                                Float(effect.keyColor.green),
                                Float(effect.keyColor.blue),
                                1
                            )
                        }
                        let effectCountValue = UInt32(effectParameters.count)
                        if effectParameters.isEmpty {
                            effectParameters = [SIMD4<Float>(repeating: 0)]
                            effectColors = [SIMD4<Float>(repeating: 0)]
                        }
                        effectParameters.withUnsafeBytes { bytes in
                            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 8)
                        }
                        effectColors.withUnsafeBytes { bytes in
                            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 9)
                        }
                        var effectCount = effectCountValue
                        encoder.setFragmentBytes(&effectCount, length: MemoryLayout<UInt32>.size, index: 10)

                        var settings: SIMD4<Float> = [
                            layerOpacity * Float(surface.opacity),
                            Float(surface.brightness * snapshot.outputIntensity),
                            pattern.shaderValue,
                            surface.isMaskInverted ? 1 : 0
                        ]
                        encoder.setFragmentTexture(cachedTexture.texture, index: 0)
                        encoder.setFragmentBytes(&settings, length: MemoryLayout<SIMD4<Float>>.size, index: 4)
                        var generatorParameters = SIMD4<Float>(repeating: 0)
                        var generatorPrimaryColor = SIMD4<Float>(repeating: 0)
                        var generatorSecondaryColor = SIMD4<Float>(repeating: 0)
                        if let generator {
                            generatorParameters = SIMD4<Float>(
                                generator.kind.shaderValue,
                                Float(generator.speed),
                                Float(generator.scale),
                                Float(CACurrentMediaTime())
                            )
                            generatorPrimaryColor = SIMD4<Float>(
                                Float(generator.primaryColor.red),
                                Float(generator.primaryColor.green),
                                Float(generator.primaryColor.blue),
                                Float(generator.directionDegrees * .pi / 180)
                            )
                            generatorSecondaryColor = SIMD4<Float>(
                                Float(generator.secondaryColor.red),
                                Float(generator.secondaryColor.green),
                                Float(generator.secondaryColor.blue),
                                1
                            )
                        }
                        encoder.setFragmentBytes(&generatorParameters, length: MemoryLayout<SIMD4<Float>>.size, index: 23)
                        encoder.setFragmentBytes(&generatorPrimaryColor, length: MemoryLayout<SIMD4<Float>>.size, index: 24)
                        encoder.setFragmentBytes(&generatorSecondaryColor, length: MemoryLayout<SIMD4<Float>>.size, index: 25)
                        var layerContentParameters = SIMD4<Float>(
                            Float(layerContent.zoomX),
                            Float(layerContent.zoomY),
                            Float(layerContent.offsetX),
                            Float(layerContent.offsetY)
                        )
                        encoder.setFragmentBytes(&layerContentParameters, length: MemoryLayout<SIMD4<Float>>.size, index: 26)
                        var layerContentRotation = Float(layerContent.rotationDegrees * .pi / 180)
                        encoder.setFragmentBytes(&layerContentRotation, length: MemoryLayout<Float>.size, index: 27)
                        var layerContentFlips: UInt32 = 0
                        if layerContent.isFlippedHorizontally { layerContentFlips |= 1 }
                        if layerContent.isFlippedVertically { layerContentFlips |= 2 }
                        encoder.setFragmentBytes(&layerContentFlips, length: MemoryLayout<UInt32>.size, index: 28)
                        encoder.drawPrimitives(
                            type: meshEnabled ? .triangle : .triangleStrip,
                            vertexStart: 0,
                            vertexCount: vertexData.count
                        )
                    }
                }
                if !inFlightCVTextures.isEmpty {
                    commandBuffer.addCompletedHandler { _ in
                        withExtendedLifetime(inFlightCVTextures) {}
                    }
                }
            }
        }

        encoder.endEncoding()
        if target.isProjectorOutput {
            SyphonOutputService.shared.publishFrame(drawable.texture, commandBuffer: commandBuffer, outputID: target.outputID)
        }
        let ndiOutput = NDIOutputService.shared
        if target.isProjectorOutput,
           let renderDevice = device,
           let buffer = ndiOutput.beginFrameCapture(
                for: target.outputID,
                device: renderDevice,
                width: drawable.texture.width,
                height: drawable.texture.height
           ) {
            let width = drawable.texture.width
            let height = drawable.texture.height
            let bytesPerRow = width * 4
            let byteCount = bytesPerRow * height
            if let blitEncoder = commandBuffer.makeBlitCommandEncoder() {
                blitEncoder.copy(
                    from: drawable.texture,
                    sourceSlice: 0,
                    sourceLevel: 0,
                    sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                    sourceSize: MTLSize(width: width, height: height, depth: 1),
                    to: buffer,
                    destinationOffset: 0,
                    destinationBytesPerRow: bytesPerRow,
                    destinationBytesPerImage: byteCount
                )
                blitEncoder.endEncoding()
                commandBuffer.addCompletedHandler { commandBuffer in
                    guard commandBuffer.status == .completed else {
                        ndiOutput.cancelFrameCapture()
                        return
                    }
                    ndiOutput.sendCapturedFrame(buffer, width: width, height: height, outputID: target.outputID)
                }
            } else {
                ndiOutput.cancelFrameCapture()
            }
        }
        let viewID = ObjectIdentifier(view)
        let targetFramesPerSecond = max(view.preferredFramesPerSecond, 1)
        let outputID = target.outputID
        drawable.addPresentedHandler { [weak self] _ in
            self?.recordPresentedFrame(for: viewID, targetFramesPerSecond: targetFramesPerSecond)
        }
        commandBuffer.addCompletedHandler { [weak self] completedBuffer in
            guard completedBuffer.status == .completed,
                  completedBuffer.gpuStartTime > 0,
                  completedBuffer.gpuEndTime > completedBuffer.gpuStartTime else { return }
            let gpuMilliseconds = (completedBuffer.gpuEndTime - completedBuffer.gpuStartTime) * 1_000
            self?.recordGPUTime(gpuMilliseconds, for: viewID, outputID: outputID)
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func recordPresentedFrame(for viewID: ObjectIdentifier, targetFramesPerSecond: Int) {
        let now = CACurrentMediaTime()
        sessionsLock.lock()
        let outputID = sessionsByView[viewID]?.outputID ?? ProjectionOutput.mainID
        sessionsLock.unlock()
        frameRateLock.lock()
        var counter = frameRateCounters[viewID] ?? FrameRateCounter(
            outputID: outputID,
            intervalStart: now,
            frameCount: 0,
            measuredFPS: 0,
            lastSampleTime: now,
            targetFramesPerSecond: Double(max(targetFramesPerSecond, 1)),
            lastPresentedTime: nil,
            measuredIntervals: 0,
            lateIntervals: 0,
            latePresentationPercent: 0
        )
        counter.outputID = outputID
        counter.targetFramesPerSecond = Double(max(targetFramesPerSecond, 1))
        if let lastPresentedTime = counter.lastPresentedTime {
            let presentationInterval = max(now - lastPresentedTime, 0)
            let expectedInterval = 1 / counter.targetFramesPerSecond
            counter.measuredIntervals += 1
            if presentationInterval > expectedInterval * 1.5 {
                counter.lateIntervals += 1
            }
        }
        counter.lastPresentedTime = now
        counter.frameCount += 1
        let elapsed = now - counter.intervalStart
        guard elapsed >= 0.5 else {
            frameRateCounters[viewID] = counter
            frameRateLock.unlock()
            return
        }
        counter.measuredFPS = Double(counter.frameCount) / elapsed
        counter.latePresentationPercent = counter.measuredIntervals > 0
            ? Double(counter.lateIntervals) / Double(counter.measuredIntervals) * 100
            : 0
        counter.intervalStart = now
        counter.frameCount = 0
        counter.measuredIntervals = 0
        counter.lateIntervals = 0
        counter.lastSampleTime = now
        frameRateCounters[viewID] = counter
        frameRateCounters = frameRateCounters.filter { now - $0.value.lastSampleTime <= 1.5 }
        let currentMaximum = frameRateCounters.values.map(\.measuredFPS).max() ?? 0
        var ratesByOutput: [UUID: Double] = [:]
        var latePercentByOutput: [UUID: Double] = [:]
        for sample in frameRateCounters.values {
            ratesByOutput[sample.outputID] = max(ratesByOutput[sample.outputID] ?? 0, sample.measuredFPS)
            latePercentByOutput[sample.outputID] = max(latePercentByOutput[sample.outputID] ?? 0, sample.latePresentationPercent)
        }
        frameRateLock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.presentedFPS = currentMaximum
            self?.presentedFPSByOutputID = ratesByOutput
            self?.latePresentationPercentByOutputID = latePercentByOutput
        }
    }

    private func quadVertices(for surface: ProjectionSurface) -> [SIMD4<Float>] {
        guard surface.corners.count == 4 else { return [] }
        let vertices: [(NormalizedPoint, NormalizedPoint)] = [
            (surface.corners[0], NormalizedPoint(0, 0)),
            (surface.corners[1], NormalizedPoint(1, 0)),
            (surface.corners[3], NormalizedPoint(0, 1)),
            (surface.corners[2], NormalizedPoint(1, 1))
        ]
        return vertices.map { output, source in
            SIMD4<Float>(Float(output.x), Float(output.y), Float(source.x), Float(source.y))
        }
    }

    private func meshVertices(for surface: ProjectionSurface) -> [SIMD4<Float>] {
        guard let warp = surface.meshWarp?.sanitized(), let grid = surface.meshGridPoints else { return [] }
        let divisions = warp.subdivisionCount
        let side = divisions + 1
        guard grid.count == side * side else { return [] }
        func vertex(_ row: Int, _ column: Int) -> SIMD4<Float> {
            let output = grid[row * side + column]
            return SIMD4<Float>(
                Float(output.x),
                Float(output.y),
                Float(column) / Float(divisions),
                Float(row) / Float(divisions)
            )
        }
        var result: [SIMD4<Float>] = []
        result.reserveCapacity(divisions * divisions * 6)
        for row in 0..<divisions {
            for column in 0..<divisions {
                let topLeft = vertex(row, column)
                let topRight = vertex(row, column + 1)
                let bottomLeft = vertex(row + 1, column)
                let bottomRight = vertex(row + 1, column + 1)
                result.append(contentsOf: [topLeft, topRight, bottomRight, topLeft, bottomRight, bottomLeft])
            }
        }
        return result
    }

    private func texture(for source: MediaSource) -> CachedTexture? {
        textureLock.lock()
        defer { textureLock.unlock() }

        if source.kind == .generator {
            guard let fallbackTexture else { return nil }
            return CachedTexture(texture: fallbackTexture, cvTexture: nil)
        }

        if let cached = textures[source.id] {
            switch source.kind {
            case .image, .generator:
                return cached
            case .capture, .ndi, .syphon:
                let canRenderHeldNDIFrame = source.kind == .ndi && source.ndiFallbackMode == .holdLastFrame
                guard source.isCaptureConnected || canRenderHeldNDIFrame else {
                    textures.removeValue(forKey: source.id)
                    return nil
                }
                if source.latestCaptureFrame?.sequence == cached.frameSequence { return cached }
            case .video:
                break
            }
        }
        guard !failedTextureIDs.contains(source.id), let device else { return textures[source.id] }

        if source.kind == .image, let image = source.image {
            do {
                let loader = MTKTextureLoader(device: device)
                let texture = try loader.newTexture(cgImage: image, options: [
                    .SRGB: false,
                    .textureUsage: MTLTextureUsage.shaderRead.rawValue
                ])
                let cached = CachedTexture(texture: texture, cvTexture: nil)
                textures[source.id] = cached
                return cached
            } catch {
                failedTextureIDs.insert(source.id)
                return nil
            }
        }

        guard let textureCache else { return textures[source.id] }

        let pixelBuffer: CVPixelBuffer?
        let frameSequence: UInt64?
        switch source.kind {
        case .capture, .ndi, .syphon:
            let frame = source.latestCaptureFrame
            pixelBuffer = frame?.pixelBuffer
            frameSequence = frame?.sequence
        case .video:
            guard let videoOutput = source.videoOutput else { return textures[source.id] }
            let itemTime = videoOutput.itemTime(forHostTime: CACurrentMediaTime())
            if videoOutput.hasNewPixelBuffer(forItemTime: itemTime) {
                var displayTime = CMTime.invalid
                pixelBuffer = videoOutput.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &displayTime)
            } else {
                return textures[source.id]
            }
            frameSequence = nil
        case .image, .generator:
            return textures[source.id]
        }

        guard let pixelBuffer else { return textures[source.id] }
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            CVPixelBufferGetWidth(pixelBuffer),
            CVPixelBufferGetHeight(pixelBuffer),
            0,
            &cvTexture
        )
        if status == kCVReturnSuccess,
           let cvTexture,
           let metalTexture = CVMetalTextureGetTexture(cvTexture) {
            textures[source.id] = CachedTexture(
                texture: metalTexture,
                cvTexture: cvTexture,
                frameSequence: frameSequence
            )
        }

        return textures[source.id]
    }

    private func pruneUnusedTextures(keeping sourceIDs: Set<UUID>) {
        textureLock.lock()
        textures = textures.filter { sourceIDs.contains($0.key) }
        failedTextureIDs.formIntersection(sourceIDs)
        textureLock.unlock()
    }
}

private final class OutputMetalView: MTKView {
    var closeOutput: (() -> Void)?
    var isProjectorView = false
    private var previewScale = 1.0

    func setPreviewScale(_ scale: Double) {
        previewScale = min(max(scale.isFinite ? scale : 1, 0.5), 1)
        autoResizeDrawable = isProjectorView || previewScale >= 0.999
        updatePreviewDrawableSize()
    }

    override func layout() {
        super.layout()
        updatePreviewDrawableSize()
    }

    private func updatePreviewDrawableSize() {
        guard !isProjectorView, previewScale < 0.999 else { return }
        let backingScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
        let width = max(1, Int((bounds.width * backingScale * previewScale).rounded(.up)))
        let height = max(1, Int((bounds.height * backingScale * previewScale).rounded(.up)))
        let newSize = CGSize(width: width, height: height)
        if drawableSize != newSize {
            drawableSize = newSize
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard closeOutput != nil else { return super.menu(for: event) }
        let menu = NSMenu()
        let closeItem = NSMenuItem(title: "Close Output", action: #selector(closeOutputFromMenu), keyEquivalent: "")
        closeItem.target = self
        menu.addItem(closeItem)
        return menu
    }

    @objc private func closeOutputFromMenu(_ sender: Any?) {
        closeOutput?()
    }
}

final class ProjectorOutputController: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var activeOutputTitle: String?
    @Published private(set) var isVirtualOutput = false
    @Published private(set) var activeOutputID: UUID?
    @Published private(set) var openOutputIDs: Set<UUID> = []
    @Published private(set) var isOutputFrozen = false

    private struct OpenOutput {
        let window: NSWindow
        let title: String
        let isVirtual: Bool
    }

    private let renderer: MetalRenderer
    private let session: RenderSession
    private var windowsByOutputID: [UUID: OpenOutput] = [:]
    private var openOrder: [UUID] = []
    private var outputAboveMenuBar = UserDefaults.standard.bool(forKey: "outputAboveMenuBar")
    private var outputFrameRate = UserDefaults.standard.object(forKey: "outputFrameRate") as? Int ?? 60
    private var preventsSleepWhileOpen = UserDefaults.standard.object(forKey: "preventSleepWhileOutputOpen") as? Bool ?? true
    private var displaySleepActivity: NSObjectProtocol?

    init(renderer: MetalRenderer, session: RenderSession) {
        self.renderer = renderer
        self.session = session
        super.init()
    }

    func setOutputAboveMenuBar(_ enabled: Bool) {
        outputAboveMenuBar = enabled
        applyWindowLevel()
    }

    func setOutputFrameRate(_ framesPerSecond: Int) {
        let validRates = [24, 25, 30, 50, 60]
        let selectedRate = validRates.contains(framesPerSecond) ? framesPerSecond : 60
        guard outputFrameRate != selectedRate else { return }
        outputFrameRate = selectedRate
        for output in windowsByOutputID.values {
            (output.window.contentView as? MTKView)?.preferredFramesPerSecond = selectedRate
        }
    }

    func setOutputFrozen(_ frozen: Bool) {
        guard isOutputFrozen != frozen else { return }
        isOutputFrozen = frozen
        for output in windowsByOutputID.values {
            (output.window.contentView as? MTKView)?.isPaused = frozen
        }
    }

    func setNDIOutputEnabled(_ enabled: Bool) {
        for output in windowsByOutputID.values {
            (output.window.contentView as? MTKView)?.framebufferOnly = !(enabled || SyphonOutputService.shared.isEnabled)
        }
    }

    func setSyphonOutputEnabled(_ enabled: Bool) {
        for output in windowsByOutputID.values {
            (output.window.contentView as? MTKView)?.framebufferOnly = !(enabled || NDIOutputService.shared.isEnabled)
        }
    }

    func setPreventSleepWhileOutputOpen(_ enabled: Bool) {
        preventsSleepWhileOpen = enabled
        refreshDisplaySleepActivity()
    }

    private func refreshDisplaySleepActivity() {
        let shouldPreventSleep = preventsSleepWhileOpen && !windowsByOutputID.isEmpty
        if shouldPreventSleep, displaySleepActivity == nil {
            displaySleepActivity = ProcessInfo.processInfo.beginActivity(
                options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled],
                reason: "ProMap is showing a live projection output"
            )
        } else if !shouldPreventSleep, let displaySleepActivity {
            ProcessInfo.processInfo.endActivity(displaySleepActivity)
            self.displaySleepActivity = nil
        }
    }

    deinit {
        if let displaySleepActivity {
            ProcessInfo.processInfo.endActivity(displaySleepActivity)
        }
    }

    private func applyWindowLevel() {
        for output in windowsByOutputID.values {
            output.window.level = outputAboveMenuBar ? .screenSaver : .normal
        }
    }

    func open(on screen: NSScreen) {
        open(on: screen, outputID: ProjectionOutput.mainID)
    }

    func open(on screen: NSScreen, outputID: UUID) {
        close(outputID: outputID)
        let outputWindow = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        outputWindow.title = "ProMap Output"
        outputWindow.delegate = self
        outputWindow.isReleasedWhenClosed = false
        outputWindow.isOpaque = true
        outputWindow.backgroundColor = .black
        outputWindow.collectionBehavior = [.fullScreenAuxiliary, .stationary]
        outputWindow.setFrame(screen.frame, display: true)
        outputWindow.level = outputAboveMenuBar ? .screenSaver : .normal
        outputWindow.contentView = renderer.makeView(
            session: session,
            outputID: outputID,
            frame: CGRect(origin: .zero, size: screen.frame.size),
            preferredFramesPerSecond: outputFrameRate,
            onClose: { [weak self] in self?.close(outputID: outputID) }
        )
        windowsByOutputID[outputID] = OpenOutput(window: outputWindow, title: screen.localizedName, isVirtual: false)
        openOrder.removeAll { $0 == outputID }
        openOrder.append(outputID)
        if isOutputFrozen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak outputWindow] in
                (outputWindow?.contentView as? MTKView)?.isPaused = true
            }
        }
        refreshActiveOutputState()
        refreshDisplaySleepActivity()
        outputWindow.orderFrontRegardless()
    }

    func openVirtual(width: Int, height: Int) {
        openVirtual(width: width, height: height, outputID: ProjectionOutput.mainID)
    }

    func openVirtual(width: Int, height: Int, outputID: UUID) {
        close(outputID: outputID)
        let nominalSize = NSSize(width: width, height: height)
        let windowSize = NSSize(width: 960, height: 540)
        let outputWindow = NSWindow(
            contentRect: NSRect(origin: .zero, size: windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        outputWindow.title = "Virtual Output — \(width) × \(height)"
        outputWindow.delegate = self
        outputWindow.isReleasedWhenClosed = false
        outputWindow.isOpaque = true
        outputWindow.backgroundColor = .black
        outputWindow.level = outputAboveMenuBar ? .screenSaver : .normal
        outputWindow.contentAspectRatio = NSSize(width: width, height: height)
        outputWindow.minSize = NSSize(width: 480, height: 270)
        outputWindow.center()

        let outputView = renderer.makeView(
            session: session,
            outputID: outputID,
            frame: CGRect(origin: .zero, size: windowSize),
            preferredFramesPerSecond: outputFrameRate,
            onClose: { [weak self] in self?.close(outputID: outputID) }
        )
        outputView.autoResizeDrawable = false
        outputView.drawableSize = nominalSize
        outputWindow.contentView = outputView
        let title = "Virtual Output \(width) × \(height)"
        windowsByOutputID[outputID] = OpenOutput(window: outputWindow, title: title, isVirtual: true)
        openOrder.removeAll { $0 == outputID }
        openOrder.append(outputID)
        if isOutputFrozen {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak outputWindow] in
                (outputWindow?.contentView as? MTKView)?.isPaused = true
            }
        }
        refreshActiveOutputState()
        refreshDisplaySleepActivity()
        outputWindow.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard let activeOutputID else { return }
        close(outputID: activeOutputID)
    }

    func close(outputID: UUID) {
        guard let closingOutput = windowsByOutputID.removeValue(forKey: outputID) else { return }
        openOrder.removeAll { $0 == outputID }
        if let outputView = closingOutput.window.contentView as? MTKView {
            renderer.releaseView(outputView)
        }
        closingOutput.window.delegate = nil
        closingOutput.window.orderOut(nil)
        closingOutput.window.close()
        if windowsByOutputID.isEmpty { setOutputFrozen(false) }
        refreshActiveOutputState()
        refreshDisplaySleepActivity()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow,
              let outputID = windowsByOutputID.first(where: { $0.value.window === closingWindow })?.key,
              let closingOutput = windowsByOutputID.removeValue(forKey: outputID) else { return }
        if let outputView = closingOutput.window.contentView as? MTKView {
            renderer.releaseView(outputView)
        }
        openOrder.removeAll { $0 == outputID }
        if windowsByOutputID.isEmpty { setOutputFrozen(false) }
        refreshActiveOutputState()
        refreshDisplaySleepActivity()
    }

    private func refreshActiveOutputState() {
        openOutputIDs = Set(windowsByOutputID.keys)
        let lastOpenID = openOrder.last(where: { windowsByOutputID[$0] != nil })
        activeOutputID = lastOpenID
        activeOutputTitle = lastOpenID.flatMap { windowsByOutputID[$0]?.title }
        isVirtualOutput = lastOpenID.flatMap { windowsByOutputID[$0]?.isVirtual } ?? false
    }
}
