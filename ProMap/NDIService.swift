import AppKit
import AVFoundation
import AudioToolbox
import Combine
import CoreVideo
import CoreAudio
import Darwin
import Foundation
import Metal
import QuartzCore

enum NDIReceiveBandwidth: String, CaseIterable, Identifiable {
    case reduced
    case full

    var id: String { rawValue }
    var title: String { self == .reduced ? "Reduced" : "Full quality" }
    var bridgeValue: Int32 { self == .reduced ? 0 : 100 }
}

enum NDIFallbackMode: String, CaseIterable, Identifiable {
    case holdLastFrame
    case black

    var id: String { rawValue }
    var title: String { self == .holdLastFrame ? "Hold last frame" : "Show black" }
}

struct NDIStreamFormat: Equatable {
    let width: Int
    let height: Int
    let framesPerSecond: Double?
}

private final class NDIAudioOutput {
    private static let outputSampleRate = 48_000.0
    private static let maximumQueuedBuffers = 64

    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let audioQueue = DispatchQueue(label: "ProMap.ndi-audio", qos: .userInitiated)
    private let stateLock = NSLock()
    private let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
    private var isMuted = true
    private var sourceVolume = 1.0
    private var masterVolume = 1.0
    private var outputDeviceUID = ""
    private var queuedBufferCount = 0
    private var queueGeneration = 0
    private var audioDelaySeconds = 0.0
    private var mostRecentMeterLevel = 0.0
    private var meterUpdatedAt = CACurrentMediaTime()

    init(outputDeviceUID: String) {
        self.outputDeviceUID = outputDeviceUID
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: outputFormat)
        applyOutputDevice()
    }

    func setMuted(_ muted: Bool) {
        stateLock.lock()
        isMuted = muted
        if muted {
            queueGeneration &+= 1
            queuedBufferCount = 0
        }
        stateLock.unlock()
        audioQueue.async { [weak self] in
            guard let self else { return }
            if muted {
                self.player.stop()
            } else {
                self.startPlaybackIfNeeded()
            }
        }
    }

    func setSourceVolume(_ volume: Double) {
        stateLock.lock()
        sourceVolume = min(max(volume.isFinite ? volume : 1, 0), 1)
        let effectiveVolume = Float(sourceVolume * masterVolume)
        stateLock.unlock()
        audioQueue.async { [weak self] in self?.player.volume = effectiveVolume }
    }

    func setMasterVolume(_ volume: Double) {
        stateLock.lock()
        masterVolume = min(max(volume.isFinite ? volume : 1, 0), 1)
        let effectiveVolume = Float(sourceVolume * masterVolume)
        stateLock.unlock()
        audioQueue.async { [weak self] in self?.player.volume = effectiveVolume }
    }

    func setOutputDeviceUID(_ uniqueID: String?) {
        stateLock.lock()
        outputDeviceUID = uniqueID ?? ""
        stateLock.unlock()
        audioQueue.async { [weak self] in self?.applyOutputDevice() }
    }

    func setAudioDelayMilliseconds(_ milliseconds: Double) {
        stateLock.lock()
        audioDelaySeconds = min(max(milliseconds.isFinite ? milliseconds : 0, 0), 500) / 1000
        stateLock.unlock()
    }

    var audioMeterLevel: Double {
        stateLock.lock()
        defer { stateLock.unlock() }
        let elapsed = max(0, CACurrentMediaTime() - meterUpdatedAt)
        return max(0, mostRecentMeterLevel - elapsed * 2.2)
    }

    func enqueue(_ frame: ProMapNDIAudioFrame) {
        guard frame.isFloatPlanar,
              frame.sampleRate >= 8_000, frame.sampleRate <= 192_000,
              frame.channelCount > 0, frame.channelCount <= 32,
              frame.sampleCount > 0, frame.sampleCount <= 16_384,
              frame.channelStride >= frame.sampleCount * Int32(MemoryLayout<Float>.size),
              let data = frame.data else { return }
        let sampleCount = Int(frame.sampleCount)
        let channelCount = Int(frame.channelCount)
        let channelStride = Int(frame.channelStride)
        let sourceChannels = (0..<channelCount).map { channel in
            UnsafeRawPointer(data).advanced(by: channel * channelStride).assumingMemoryBound(to: Float.self)
        }
        var squaredTotal = 0.0
        var measuredSampleCount = 0
        for channel in 0..<min(channelCount, 2) {
            let samples = sourceChannels[channel]
            for index in 0..<sampleCount {
                let sample = samples[index]
                if sample.isFinite {
                    let value = Double(sample)
                    squaredTotal += value * value
                    measuredSampleCount += 1
                }
            }
        }
        let rms = measuredSampleCount > 0 ? sqrt(squaredTotal / Double(measuredSampleCount)) : 0
        let decibels = 20 * log10(max(rms, 0.001))
        let measuredLevel = min(max((decibels + 60) / 60, 0), 1)

        stateLock.lock()
        mostRecentMeterLevel = measuredLevel
        meterUpdatedAt = CACurrentMediaTime()
        guard !isMuted, queuedBufferCount < Self.maximumQueuedBuffers else {
            stateLock.unlock()
            return
        }
        queuedBufferCount += 1
        let generation = queueGeneration
        let delaySeconds = audioDelaySeconds
        stateLock.unlock()

        let outputSampleCount = Int((Double(frame.sampleCount) * Self.outputSampleRate / Double(frame.sampleRate)).rounded())
        guard outputSampleCount > 0,
              outputSampleCount <= 32_768,
              let buffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(outputSampleCount)),
              let outputChannels = buffer.floatChannelData else {
            adjustQueuedBufferCount(by: -1, generation: generation)
            return
        }
        buffer.frameLength = AVAudioFrameCount(outputSampleCount)
        for outputIndex in 0..<outputSampleCount {
            let sourcePosition = min(
                Double(outputIndex) * Double(frame.sampleRate) / Self.outputSampleRate,
                Double(sampleCount - 1)
            )
            let firstIndex = min(Int(sourcePosition), sampleCount - 1)
            let secondIndex = min(firstIndex + 1, sampleCount - 1)
            let fraction = Float(sourcePosition - Double(firstIndex))
            let leftSource = sourceChannels[0]
            let rightSource = sourceChannels[min(1, sourceChannels.count - 1)]
            let left = leftSource[firstIndex] + (leftSource[secondIndex] - leftSource[firstIndex]) * fraction
            let right = rightSource[firstIndex] + (rightSource[secondIndex] - rightSource[firstIndex]) * fraction
            outputChannels[0][outputIndex] = left.isFinite ? left : 0
            outputChannels[1][outputIndex] = right.isFinite ? right : 0
        }

        audioQueue.asyncAfter(deadline: .now() + delaySeconds) { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let shouldPlay = !self.isMuted && generation == self.queueGeneration
            let volume = Float(self.sourceVolume * self.masterVolume)
            self.stateLock.unlock()
            guard shouldPlay else {
                self.adjustQueuedBufferCount(by: -1, generation: generation)
                return
            }
            self.startPlaybackIfNeeded()
            self.player.volume = volume
            self.player.scheduleBuffer(buffer) { [weak self] in
                self?.adjustQueuedBufferCount(by: -1, generation: generation)
            }
            if !self.player.isPlaying { self.player.play() }
        }
    }

    func stop() {
        stateLock.lock()
        isMuted = true
        queueGeneration &+= 1
        queuedBufferCount = 0
        stateLock.unlock()
        audioQueue.async { [weak self] in
            self?.player.stop()
            self?.engine.stop()
        }
    }

    private func startPlaybackIfNeeded() {
        guard !engine.isRunning else { return }
        do {
            try engine.start()
            player.play()
        } catch {
            NSLog("ProMap could not start NDI audio output: %@", error.localizedDescription)
        }
    }

    private func applyOutputDevice() {
        stateLock.lock()
        let uniqueID = outputDeviceUID
        stateLock.unlock()
        let wasRunning = engine.isRunning
        if wasRunning {
            player.pause()
            engine.stop()
        }
        guard let outputUnit = engine.outputNode.audioUnit else { return }
        let deviceID = uniqueID.isEmpty
            ? AudioOutputDevice.defaultOutputDeviceID()
            : AudioOutputDevice.deviceID(uniqueID: uniqueID)
        guard var deviceID else { return }
        let status = AudioUnitSetProperty(
            outputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            NSLog("ProMap could not route NDI audio to the selected output device (%d).", status)
        }
        if wasRunning {
            do {
                try engine.start()
                stateLock.lock()
                let shouldPlay = !isMuted
                stateLock.unlock()
                if shouldPlay { player.play() }
            } catch {
                NSLog("ProMap could not restart NDI audio after changing output: %@", error.localizedDescription)
            }
        }
    }

    private func adjustQueuedBufferCount(by amount: Int, generation: Int) {
        stateLock.lock()
        if generation == queueGeneration {
            queuedBufferCount = max(0, queuedBufferCount + amount)
        }
        stateLock.unlock()
    }
}

struct NDISourceDescriptor: Identifiable, Equatable, Codable {
    let name: String
    let url: String

    var id: String { url.isEmpty ? name : url }

    var reference: String {
        let encodedName = Self.encode(name)
        guard !url.isEmpty else { return "ndi://\(encodedName)" }
        return "ndi://\(encodedName).\(Self.encode(url))"
    }

    static func sourceName(from reference: String) -> String? {
        guard reference.hasPrefix("ndi://") else { return nil }
        let payload = String(reference.dropFirst("ndi://".count))
        let encodedName = payload.split(separator: ".", maxSplits: 1).first.map(String.init) ?? payload
        return decode(encodedName)
    }

    static func sourceURL(from reference: String) -> String? {
        guard reference.hasPrefix("ndi://") else { return nil }
        let payload = String(reference.dropFirst("ndi://".count))
        guard let separator = payload.firstIndex(of: ".") else { return nil }
        return decode(String(payload[payload.index(after: separator)...]))
    }

    static func descriptor(from reference: String) -> NDISourceDescriptor? {
        guard let name = sourceName(from: reference) else { return nil }
        return NDISourceDescriptor(name: name, url: sourceURL(from: reference) ?? "")
    }

    private static func encode(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decode(_ value: String) -> String? {
        let encoded = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padded = encoded + String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: padded) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

final class NDIService: ObservableObject {
    static let shared = NDIService()

    @Published private(set) var isEnabled = false
    @Published private(set) var status = "Discovery disabled"
    @Published private(set) var sources: [NDISourceDescriptor] = []
    @Published private(set) var manualSources: [NDISourceDescriptor] = []

    private let queue = DispatchQueue(label: "ProMap.ndi-discovery", qos: .userInitiated)
    private var finder: UnsafeMutableRawPointer?
    private var timer: DispatchSourceTimer?
    private var didAttemptInitialize = false
    private var discoveryRequested = false
    private var runtimeAvailable = false
    private var runtimeStatus = "NDI runtime has not been checked."
    private var statusValue = "Discovery disabled"
    private var discoveredSources: [NDISourceDescriptor] = []
    private var storedManualSources: [NDISourceDescriptor] = {
        guard let data = UserDefaults.standard.data(forKey: "ndiManualSources"),
              let sources = try? JSONDecoder().decode([NDISourceDescriptor].self, from: data) else { return [] }
        return sources
    }()

    private init() {
        manualSources = storedManualSources
    }

    func configure(enabled: Bool) {
        guard isEnabled != enabled else {
            if enabled { refresh() }
            return
        }
        if Thread.isMainThread {
            isEnabled = enabled
        } else {
            DispatchQueue.main.async { self.isEnabled = enabled }
        }
        if enabled {
            queue.async { [weak self] in
                guard let self else { return }
                self.discoveryRequested = true
                self.startDiscovery()
            }
        } else {
            queue.async { [weak self] in
                guard let self else { return }
                self.discoveryRequested = false
                self.stopDiscovery()
            }
        }
    }

    func refresh() {
        queue.async { [weak self] in
            guard let self, self.discoveryRequested else { return }
            if self.finder == nil {
                self.startDiscovery()
            } else {
                self.updateDiscoveredSources(waitMilliseconds: 300)
            }
        }
    }

    @discardableResult
    func addManualSource(name: String, address: String) -> String? {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanAddress = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { return "Enter the NDI source name." }
        guard !cleanAddress.isEmpty else { return "Enter the source URL or address." }
        let descriptor = NDISourceDescriptor(name: cleanName, url: cleanAddress)
        queue.async { [weak self] in
            guard let self else { return }
            self.storedManualSources.removeAll { $0.name == descriptor.name && $0.url == descriptor.url }
            self.storedManualSources.append(descriptor)
            if let data = try? JSONEncoder().encode(self.storedManualSources) {
                UserDefaults.standard.set(data, forKey: "ndiManualSources")
            }
            guard self.discoveryRequested else {
                self.publish(status: self.statusValue, sources: self.sourcesForDisplay())
                return
            }
            self.publish(
                status: self.runtimeAvailable ? "NDI ready · manual source added" : self.runtimeStatus,
                sources: self.sourcesForDisplay()
            )
        }
        return nil
    }

    func removeManualSource(reference: String) {
        queue.async { [weak self] in
            guard let self else { return }
            self.storedManualSources.removeAll { $0.reference == reference }
            if let data = try? JSONEncoder().encode(self.storedManualSources) {
                UserDefaults.standard.set(data, forKey: "ndiManualSources")
            }
            self.publish(status: self.statusValue, sources: self.sourcesForDisplay())
        }
    }

    private func startDiscovery() {
        guard discoveryRequested else { return }
        if !didAttemptInitialize {
            didAttemptInitialize = true
            let result = ProMapNDIInitialize()
            guard result == 1 else {
                runtimeStatus = String(cString: ProMapNDIStatusMessage(result))
                publish(status: runtimeStatus, sources: sourcesForDisplay())
                return
            }
            runtimeAvailable = true
            runtimeStatus = "NDI runtime ready"
        }
        guard runtimeAvailable else {
            publish(status: runtimeStatus, sources: sourcesForDisplay())
            return
        }
        guard finder == nil else {
            updateDiscoveredSources(waitMilliseconds: 100)
            return
        }
        guard let finder = ProMapNDIFindCreate() else {
            runtimeStatus = "NDI runtime is ready, but discovery could not start."
            publish(status: runtimeStatus, sources: sourcesForDisplay())
            return
        }
        self.finder = finder
        updateDiscoveredSources(waitMilliseconds: 300)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, self.discoveryRequested else { return }
            self.updateDiscoveredSources(waitMilliseconds: 100)
        }
        self.timer = timer
        timer.resume()
    }

    private func stopDiscovery() {
        timer?.cancel()
        timer = nil
        if let finder {
            ProMapNDIFindDestroy(finder)
            self.finder = nil
        }
        discoveredSources = []
        ProMapNDIFreeCopiedSources()
        publish(status: "Discovery disabled", sources: [])
    }

    private func updateDiscoveredSources(waitMilliseconds: UInt32) {
        guard let finder else { return }
        _ = ProMapNDIFindWaitForSources(finder, waitMilliseconds)
        let count = ProMapNDIFindCopySources(finder)
        guard count > 0 else {
            discoveredSources = []
            let sources = sourcesForDisplay()
            publish(status: sources.isEmpty ? "NDI ready · no sources found" : "NDI ready · \(sources.count) sources available", sources: sources)
            return
        }
        defer { ProMapNDIFreeCopiedSources() }

        discoveredSources = (0..<Int(count)).compactMap { index -> NDISourceDescriptor? in
            guard let namePointer = ProMapNDIFindSourceNameAt(UInt32(index)) else { return nil }
            let name = String(cString: namePointer)
            guard !name.isEmpty else { return nil }
            let url = ProMapNDIFindSourceURLAt(UInt32(index)).map(String.init(cString:)) ?? ""
            return NDISourceDescriptor(name: name, url: url)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        let discovered = sourcesForDisplay()

        publish(
            status: discovered.isEmpty
                ? "NDI ready · no sources found"
                : "NDI ready · \(discovered.count) source\(discovered.count == 1 ? "" : "s") found",
            sources: discovered
        )
    }

    private func sourcesForDisplay() -> [NDISourceDescriptor] {
        let manual = storedManualSources.filter { manual in
            !discoveredSources.contains(where: { $0.name == manual.name && $0.url == manual.url })
        }
        return (discoveredSources + manual)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func publish(status: String, sources: [NDISourceDescriptor]) {
        statusValue = status
        let configuredManualSources = storedManualSources
        DispatchQueue.main.async {
            self.status = status
            self.sources = sources
            self.manualSources = configuredManualSources
        }
    }
}

final class NDIOutputService: ObservableObject {
    static let shared = NDIOutputService()

    @Published private(set) var isEnabled = false
    @Published private(set) var status = "NDI output disabled"

    private let queue = DispatchQueue(label: "ProMap.ndi-output", qos: .userInitiated)
    private let stateLock = NSLock()
    private var targetOutputID: UUID?
    private var isCapturePending = false
    private var lastCaptureTime: CFTimeInterval = 0
    private var requestedEnabled = false
    private var requestedName = "ProMap Program"
    private var configurationRevision: UInt64 = 0
    private var sender: UnsafeMutableRawPointer?
    private var senderName: String?
    private var captureBuffer: MTLBuffer?
    private let outputFrameRate = 30

    private init() {}

    func configure(enabled: Bool, sourceName: String, targetOutputID: UUID?) {
        let cleanedName = Self.sanitizedSourceName(sourceName)
        stateLock.lock()
        requestedEnabled = enabled
        requestedName = cleanedName
        self.targetOutputID = targetOutputID
        configurationRevision &+= 1
        let revision = configurationRevision
        stateLock.unlock()

        DispatchQueue.main.async {
            self.isEnabled = enabled
            self.status = enabled
                ? (targetOutputID == nil ? "Enabled · open a projector output to stream" : "Connecting NDI sender…")
                : "NDI output disabled"
        }

        queue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let isCurrentConfiguration = self.configurationRevision == revision
            let shouldEnable = self.requestedEnabled
            let name = self.requestedName
            self.stateLock.unlock()
            guard isCurrentConfiguration else { return }

            if !shouldEnable {
                self.destroySender()
                self.stateLock.lock()
                self.captureBuffer = nil
                self.stateLock.unlock()
                self.publishStatus("NDI output disabled")
                return
            }

            if self.sender != nil && self.senderName == name {
                self.publishStatus(targetOutputID == nil
                    ? "Enabled · open a projector output to stream"
                    : "On Air · \(name) · video only at \(self.outputFrameRate) fps")
                return
            }

            self.destroySender()
            let initialization = ProMapNDIInitialize()
            guard initialization == 1 else {
                self.publishStatus(String(cString: ProMapNDIStatusMessage(initialization)))
                return
            }
            guard ProMapNDISendAvailable() else {
                self.publishStatus("The installed NDI runtime does not support video sending.")
                return
            }
            let created = name.withCString { ProMapNDISendCreate($0) }
            guard let created else {
                self.publishStatus("ProMap could not create the NDI sender. Check the source name and runtime.")
                return
            }
            self.sender = created
            self.senderName = name
            self.publishStatus(targetOutputID == nil
                ? "Ready · open a projector output to stream"
                : "On Air · \(name) · video only at \(self.outputFrameRate) fps")
        }
    }

    func beginFrameCapture(for outputID: UUID, device: MTLDevice, width: Int, height: Int) -> MTLBuffer? {
        guard width > 0, height > 0, width.isMultiple(of: 2), width <= Int32.max, height <= Int32.max else {
            if !width.isMultiple(of: 2) { publishStatus("NDI output needs an even video width.") }
            return nil
        }
        let (bytesPerRow, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        let (byteCount, imageOverflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !rowOverflow, !imageOverflow, byteCount > 0 else { return nil }

        stateLock.lock()
        defer { stateLock.unlock() }
        guard requestedEnabled, targetOutputID == outputID, !isCapturePending else { return nil }
        let now = CACurrentMediaTime()
        guard now - lastCaptureTime >= 1.0 / Double(outputFrameRate) else { return nil }
        if captureBuffer?.length != byteCount {
            captureBuffer = device.makeBuffer(length: byteCount, options: .storageModeShared)
        }
        guard let captureBuffer else { return nil }
        isCapturePending = true
        lastCaptureTime = now
        return captureBuffer
    }

    func sendCapturedFrame(_ buffer: MTLBuffer, width: Int, height: Int, outputID: UUID) {
        queue.async { [weak self, buffer] in
            guard let self else { return }
            self.stateLock.lock()
            let shouldSend = self.requestedEnabled && self.targetOutputID == outputID
            self.stateLock.unlock()
            defer {
                self.stateLock.lock()
                self.isCapturePending = false
                self.stateLock.unlock()
            }
            guard shouldSend, let sender = self.sender else { return }
            guard width.isMultiple(of: 2), height > 0 else {
                self.publishStatus("NDI output needs an even video width.")
                return
            }
            let accepted = ProMapNDISendVideoFrame(
                sender,
                Int32(width),
                Int32(height),
                Int32(self.outputFrameRate),
                1,
                buffer.contents().assumingMemoryBound(to: UInt8.self)
            )
            if !accepted {
                self.publishStatus("NDI could not send this output frame.")
            }
        }
    }

    func cancelFrameCapture() {
        stateLock.lock()
        isCapturePending = false
        stateLock.unlock()
    }

    private func destroySender() {
        if let sender { ProMapNDISendDestroy(sender) }
        sender = nil
        senderName = nil
    }

    private func publishStatus(_ value: String) {
        DispatchQueue.main.async { self.status = value }
    }

    private static func sanitizedSourceName(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "\\/:*?\"<>|")
        let cleaned = value
            .components(separatedBy: invalid)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String((cleaned.isEmpty ? "ProMap Program" : cleaned).prefix(200))
    }
}

final class NDIReceiver {
    private let receiveQueue: DispatchQueue
    private let frameLock = NSLock()
    private let statusLock = NSLock()
    private var receiver: UnsafeMutableRawPointer?
    private var latestFrame: CapturedVideoFrame?
    private var sequence: UInt64 = 0
    private var running = true
    private var connected = false
    private var lastVideoFrameAt = Date.distantPast
    private let holdsLastFrame: Bool
    private let audioOutput: NDIAudioOutput
    var statusHandler: ((Bool) -> Void)?

    var isConnected: Bool {
        statusLock.lock()
        defer { statusLock.unlock() }
        return connected
    }

    init(
        source: NDISourceDescriptor,
        bandwidth: NDIReceiveBandwidth = .full,
        fallbackMode: NDIFallbackMode = .black
    ) throws {
        holdsLastFrame = fallbackMode == .holdLastFrame
        audioOutput = NDIAudioOutput(
            outputDeviceUID: UserDefaults.standard.string(forKey: "audioOutputDeviceUID") ?? ""
        )
        var createdReceiver: UnsafeMutableRawPointer?
        source.name.withCString { name in
            if source.url.isEmpty {
                createdReceiver = ProMapNDIReceiverCreate(name, nil, bandwidth.bridgeValue)
            } else {
                source.url.withCString { url in
                    createdReceiver = ProMapNDIReceiverCreate(name, url, bandwidth.bridgeValue)
                }
            }
        }
        guard let createdReceiver else {
            throw MediaImportError.cannotConfigureNDIDevice(source.name)
        }
        receiver = createdReceiver
        receiveQueue = DispatchQueue(label: "ProMap.ndi-receiver.\(UUID().uuidString)", qos: .userInitiated)
        receiveQueue.async { [weak self] in self?.receiveFrames() }
    }

    deinit {
        stop()
    }

    func snapshot() -> CapturedVideoFrame? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return latestFrame
    }

    func stop() {
        statusLock.lock()
        running = false
        statusLock.unlock()
        frameLock.lock()
        latestFrame = nil
        frameLock.unlock()
        setConnected(false)
        audioOutput.stop()
    }

    func setAudioMuted(_ muted: Bool) { audioOutput.setMuted(muted) }
    func setAudioVolume(_ volume: Double) { audioOutput.setSourceVolume(volume) }
    func setMasterAudioVolume(_ volume: Double) { audioOutput.setMasterVolume(volume) }
    func setAudioOutputDeviceUID(_ uniqueID: String?) { audioOutput.setOutputDeviceUID(uniqueID) }
    func setAudioDelayMilliseconds(_ milliseconds: Double) { audioOutput.setAudioDelayMilliseconds(milliseconds) }
    var audioMeterLevel: Double { audioOutput.audioMeterLevel }

    private func receiveFrames() {
        guard let receiver else { return }
        while shouldRun {
            var videoFrame = ProMapNDIVideoFrame()
            var audioFrame = ProMapNDIAudioFrame()
            var frameHandle: UnsafeMutableRawPointer?
            let result = ProMapNDIReceiverCapture(receiver, &videoFrame, &audioFrame, &frameHandle, 100)
            if let frameHandle {
                defer { ProMapNDIReceiverFreeFrame(receiver, frameHandle) }
                if result == 1, let pixelBuffer = makePixelBuffer(from: videoFrame) {
                    frameLock.lock()
                    sequence &+= 1
                    let denominator = Double(videoFrame.frameRateDenominator)
                    let frameRate = denominator > 0
                        ? Double(videoFrame.frameRateNumerator) / denominator
                        : nil
                    latestFrame = CapturedVideoFrame(
                        pixelBuffer: pixelBuffer,
                        sequence: sequence,
                        framesPerSecond: frameRate
                    )
                    frameLock.unlock()
                    lastVideoFrameAt = Date()
                    setConnected(true)
                } else if result == 2 {
                    audioOutput.enqueue(audioFrame)
                }
            } else if result == 4 {
                setConnected(false)
            } else if isConnected && Date().timeIntervalSince(lastVideoFrameAt) > 3 {
                setConnected(false)
            }
        }
        ProMapNDIReceiverDestroy(receiver)
        self.receiver = nil
    }

    private var shouldRun: Bool {
        statusLock.lock()
        defer { statusLock.unlock() }
        return running
    }

    private func setConnected(_ value: Bool) {
        statusLock.lock()
        let changed = connected != value
        connected = value
        statusLock.unlock()
        if !value && !holdsLastFrame {
            frameLock.lock()
            latestFrame = nil
            frameLock.unlock()
        }
        if changed { DispatchQueue.main.async { self.statusHandler?(value) } }
    }

    private func makePixelBuffer(from frame: ProMapNDIVideoFrame) -> CVPixelBuffer? {
        let width = Int(frame.width)
        let height = Int(frame.height)
        guard width > 0, height > 0,
              width <= 16_384, height <= 16_384,
              width <= 33_177_600 / height,
              Int64(frame.stride) >= Int64(width) * 4,
              let sourceData = frame.data else { return nil }
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        ) == kCVReturnSuccess, let pixelBuffer else { return nil }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else { return nil }
        guard let destinationData = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            return nil
        }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let destinationStride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bytesPerRow = width * 4
        for row in 0..<height {
            let sourceRow = sourceData.advanced(by: row * Int(frame.stride))
            let destinationRow = destinationData.advanced(by: row * destinationStride)
            memcpy(destinationRow, sourceRow, bytesPerRow)
            if !frame.hasAlpha {
                for pixel in 0..<width {
                    destinationRow.storeBytes(of: UInt8(255), toByteOffset: pixel * 4 + 3, as: UInt8.self)
                }
            }
        }
        return pixelBuffer
    }
}
