import Combine
import CoreVideo
import Foundation
import IOSurface
import Metal
import QuartzCore
import Syphon

struct SyphonSourceDescriptor: Identifiable, Equatable {
    let reference: String
    let name: String
    let applicationName: String
    let serverDescription: [String: Any]

    var id: String { reference }
    var displayName: String {
        applicationName.isEmpty ? name : "\(name) · \(applicationName)"
    }

    static func reference(forServerID serverID: String) -> String {
        let encoded = Data(serverID.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "syphon://\(encoded)"
    }

    static func serverID(from reference: String) -> String? {
        guard reference.hasPrefix("syphon://") else { return nil }
        let encoded = String(reference.dropFirst("syphon://".count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: padded) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    init?(serverDescription: [String: Any]) {
        guard let serverID = serverDescription[SyphonServerDescriptionUUIDKey] as? String,
              let name = serverDescription[SyphonServerDescriptionNameKey] as? String,
              !serverID.isEmpty, !name.isEmpty else { return nil }
        reference = Self.reference(forServerID: serverID)
        self.name = name
        applicationName = serverDescription[SyphonServerDescriptionAppNameKey] as? String ?? ""
        self.serverDescription = serverDescription
    }

    static func == (lhs: SyphonSourceDescriptor, rhs: SyphonSourceDescriptor) -> Bool {
        lhs.reference == rhs.reference && lhs.name == rhs.name && lhs.applicationName == rhs.applicationName
    }
}

final class SyphonService: ObservableObject {
    static let shared = SyphonService()

    @Published private(set) var isEnabled = false
    @Published private(set) var sources: [SyphonSourceDescriptor] = []
    @Published private(set) var status = "Syphon discovery is off"

    private var directory: SyphonServerDirectory?
    private var notificationTokens: [NSObjectProtocol] = []

    private init() {}

    func configure(enabled: Bool) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.configure(enabled: enabled) }
            return
        }
        guard isEnabled != enabled else {
            if enabled { refresh() }
            return
        }
        isEnabled = enabled
        if enabled {
            let directory = SyphonServerDirectory.shared()
            self.directory = directory
            for name in [Notification.Name.SyphonServerAnnounce, .SyphonServerUpdate, .SyphonServerRetire] {
                notificationTokens.append(NotificationCenter.default.addObserver(
                    forName: name,
                    object: nil,
                    queue: .main
                ) { [weak self] _ in self?.refresh() })
            }
            refresh()
        } else {
            notificationTokens.forEach(NotificationCenter.default.removeObserver)
            notificationTokens.removeAll()
            directory = nil
            sources = []
            status = "Syphon discovery is off"
        }
    }

    func refresh() {
        guard isEnabled, let directory else { return }
        let discovered = directory.servers
            .compactMap(SyphonSourceDescriptor.init(serverDescription:))
            .sorted {
                let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
                return nameOrder == .orderedSame
                    ? $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName) == .orderedAscending
                    : nameOrder == .orderedAscending
            }
        sources = discovered
        status = discovered.isEmpty
            ? "Syphon ready · no servers found"
            : "Syphon ready · \(discovered.count) server\(discovered.count == 1 ? "" : "s") found"
    }

    func source(for reference: String) -> SyphonSourceDescriptor? {
        sources.first(where: { $0.reference == reference })
    }
}

private final class SyphonFrameStore {
    private let lock = NSLock()
    private var latestFrame: CapturedVideoFrame?
    private var sequence: UInt64 = 0
    private var lastFrameTime: CFTimeInterval = 0
    private var smoothedFrameRate: Double?

    func store(_ pixelBuffer: CVPixelBuffer) {
        let now = CACurrentMediaTime()
        lock.lock()
        sequence &+= 1
        if lastFrameTime > 0 {
            let instantaneousRate = 1 / max(now - lastFrameTime, 0.001)
            if instantaneousRate.isFinite, instantaneousRate < 240 {
                smoothedFrameRate = smoothedFrameRate.map { $0 * 0.8 + instantaneousRate * 0.2 } ?? instantaneousRate
            }
        }
        lastFrameTime = now
        latestFrame = CapturedVideoFrame(
            pixelBuffer: pixelBuffer,
            sequence: sequence,
            framesPerSecond: smoothedFrameRate
        )
        lock.unlock()
    }

    func snapshot() -> CapturedVideoFrame? {
        lock.lock()
        defer { lock.unlock() }
        return latestFrame
    }

    var hasFreshFrame: Bool {
        lock.lock()
        defer { lock.unlock() }
        return latestFrame != nil && CACurrentMediaTime() - lastFrameTime < 2
    }
}

final class SyphonReceiver {
    private let frameStore = SyphonFrameStore()
    private let client: SyphonMetalClient
    private let statusTimer: DispatchSourceTimer
    private var lastPublishedConnectionState = false
    var statusHandler: ((Bool) -> Void)?

    init(source: SyphonSourceDescriptor, device: MTLDevice) throws {
        let frameStore = self.frameStore
        client = SyphonMetalClient(
            serverDescription: source.serverDescription,
            device: device,
            options: nil
        ) { client in
            guard let texture = client.newFrameImage(),
                  let surface = texture.iosurface else { return }
            var unmanagedPixelBuffer: Unmanaged<CVPixelBuffer>?
            let attributes = [kCVPixelBufferMetalCompatibilityKey as String: true] as CFDictionary
            guard CVPixelBufferCreateWithIOSurface(
                kCFAllocatorDefault,
                surface,
                attributes,
                &unmanagedPixelBuffer
            ) == kCVReturnSuccess,
                  let unmanagedPixelBuffer else { return }
            let pixelBuffer = unmanagedPixelBuffer.takeRetainedValue()
            frameStore.store(pixelBuffer)
        }
        guard client.isValid else { throw MediaImportError.cannotConfigureSyphonDevice(source.displayName) }

        statusTimer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "ProMap.syphon-status", qos: .utility))
        statusTimer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        statusTimer.setEventHandler { [weak self] in self?.publishConnectionState() }
        statusTimer.resume()
    }

    var isConnected: Bool { frameStore.hasFreshFrame }

    func snapshot() -> CapturedVideoFrame? {
        guard isConnected else { return nil }
        return frameStore.snapshot()
    }

    func stop() {
        statusTimer.cancel()
        client.stop()
        statusHandler?(false)
    }

    private func publishConnectionState() {
        let isConnected = frameStore.hasFreshFrame
        guard isConnected != lastPublishedConnectionState else { return }
        lastPublishedConnectionState = isConnected
        DispatchQueue.main.async { [weak self] in self?.statusHandler?(isConnected) }
    }
}

final class SyphonOutputService: ObservableObject {
    static let shared = SyphonOutputService()

    @Published private(set) var isEnabled = false
    @Published private(set) var status = "Syphon output is off"

    private let stateLock = NSLock()
    private var server: SyphonMetalServer?
    private var targetOutputID: UUID?
    private var configuredName = "ProMap Program"
    private var configuredDeviceID: ObjectIdentifier?
    private var outputClientConnected = false

    private init() {}

    func configure(enabled: Bool, sourceName: String, targetOutputID: UUID?, device: MTLDevice?) {
        let name = Self.sanitizedSourceName(sourceName)
        stateLock.lock()
        let currentServer = server
        let needsReplacement = enabled && (
            currentServer == nil || configuredName != name || configuredDeviceID != device.map(ObjectIdentifier.init)
        )
        if !enabled {
            server = nil
            self.targetOutputID = nil
            configuredDeviceID = nil
            outputClientConnected = false
            stateLock.unlock()
            currentServer?.stop()
            publish(enabled: false, status: "Syphon output is off")
            return
        }
        if !needsReplacement {
            self.targetOutputID = targetOutputID
            stateLock.unlock()
            publish(enabled: currentServer != nil, status: currentServer == nil
                ? "Open a projector output to start Syphon"
                : "On Air · \(name) · waiting for a Syphon client")
            return
        }
        stateLock.unlock()

        guard let device else {
            stateLock.lock()
            let unavailableServer = server
            server = nil
            self.targetOutputID = nil
            configuredDeviceID = nil
            outputClientConnected = false
            stateLock.unlock()
            unavailableServer?.stop()
            publish(enabled: false, status: "Metal device unavailable")
            return
        }
        let newServer = SyphonMetalServer(name: name, device: device, options: nil)
        stateLock.lock()
        let replacedServer = server
        server = newServer
        configuredName = name
        configuredDeviceID = ObjectIdentifier(device)
        self.targetOutputID = targetOutputID
        outputClientConnected = false
        stateLock.unlock()
        replacedServer?.stop()
        publish(enabled: true, status: targetOutputID == nil
            ? "Enabled · open a projector output to stream"
            : "On Air · \(name) · waiting for a Syphon client")
    }

    func publishFrame(_ texture: MTLTexture, commandBuffer: MTLCommandBuffer, outputID: UUID) {
        stateLock.lock()
        let currentServer = server
        let matchesOutput = targetOutputID == outputID
        stateLock.unlock()
        guard matchesOutput, let currentServer else { return }
        let hasClients = currentServer.hasClients
        stateLock.lock()
        let clientStateChanged = outputClientConnected != hasClients
        outputClientConnected = hasClients
        let name = configuredName
        stateLock.unlock()
        if clientStateChanged {
            publish(enabled: true, status: "On Air · \(name) · \(hasClients ? "client connected" : "waiting for a Syphon client")")
        }
        guard hasClients else { return }
        currentServer.publishFrameTexture(
            texture,
            on: commandBuffer,
            imageRegion: NSRect(x: 0, y: 0, width: texture.width, height: texture.height),
            flipped: false
        )
    }

    private func publish(enabled: Bool, status: String) {
        DispatchQueue.main.async {
            self.isEnabled = enabled
            self.status = status
        }
    }

    deinit {
        server?.stop()
    }

    private static func sanitizedSourceName(_ name: String) -> String {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((cleaned.isEmpty ? "ProMap Program" : cleaned).prefix(128))
    }
}
