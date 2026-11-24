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

    private(set) var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var textureCache: CVMetalTextureCache?
    private var session: RenderSession?

    private struct CachedTexture {
        let texture: MTLTexture
        let cvTexture: CVMetalTexture?
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

        guard
            let library = selectedDevice.makeDefaultLibrary(),
            let vertexFunction = library.makeFunction(name: "fullscreenVertex"),
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

    func makeView(session: RenderSession, frame: CGRect = .zero) -> MTKView {
        let view = MTKView(frame: frame, device: device)
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        self.session = session
        view.delegate = self
        return view
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard
            let commandQueue,
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

        if let pipeline, let session {
            let snapshot = session.snapshot()
            pruneUnusedTextures(keeping: Set(snapshot.layers.map { $0.source.id }))
            if !snapshot.isBlackout {
                encoder.setRenderPipelineState(pipeline)
                var inFlightCVTextures: [CVMetalTexture] = []
                for layer in snapshot.layers where layer.isEnabled && layer.opacity > 0 {
                    guard let cachedTexture = texture(for: layer.source) else { continue }
                    if let cvTexture = cachedTexture.cvTexture {
                        inFlightCVTextures.append(cvTexture)
                    }
                    var opacity = Float(layer.opacity)
                    encoder.setFragmentTexture(cachedTexture.texture, index: 0)
                    encoder.setFragmentBytes(&opacity, length: MemoryLayout<Float>.size, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
                }
                if !inFlightCVTextures.isEmpty {
                    commandBuffer.addCompletedHandler { _ in
                        withExtendedLifetime(inFlightCVTextures) {}
                    }
                }
            }
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func texture(for source: MediaSource) -> CachedTexture? {
        textureLock.lock()
        defer { textureLock.unlock() }

        if let cached = textures[source.id] {
            if source.kind == .image { return cached }
        }
        guard !failedTextureIDs.contains(source.id), let device else { return textures[source.id] }

        if let image = source.image {
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

        guard
            let videoOutput = source.videoOutput,
            let textureCache
        else { return textures[source.id] }

        let itemTime = videoOutput.itemTime(forHostTime: CACurrentMediaTime())
        if videoOutput.hasNewPixelBuffer(forItemTime: itemTime) {
            var displayTime = CMTime.invalid
            if let pixelBuffer = videoOutput.copyPixelBuffer(
                forItemTime: itemTime,
                itemTimeForDisplay: &displayTime
            ) {
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
                    textures[source.id] = CachedTexture(texture: metalTexture, cvTexture: cvTexture)
                }
            }
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

final class ProjectorOutputController: ObservableObject {
    @Published private(set) var activeScreenName: String?

    private let renderer: MetalRenderer
    private let session: RenderSession
    private var window: NSWindow?

    init(renderer: MetalRenderer, session: RenderSession) {
        self.renderer = renderer
        self.session = session
    }

    func open(on screen: NSScreen) {
        close()
        let outputWindow = NSWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        outputWindow.title = "ProMap Output"
        outputWindow.isReleasedWhenClosed = false
        outputWindow.isOpaque = true
        outputWindow.backgroundColor = .black
        outputWindow.collectionBehavior = [.fullScreenAuxiliary, .stationary]
        outputWindow.setFrame(screen.frame, display: true)
        outputWindow.contentView = renderer.makeView(
            session: session,
            frame: CGRect(origin: .zero, size: screen.frame.size)
        )
        window = outputWindow
        activeScreenName = screen.localizedName
        outputWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.orderOut(nil)
        window?.close()
        window = nil
        activeScreenName = nil
    }
}
