import AppKit
import AVFoundation
import Combine
import CoreImage
import CoreGraphics
import CoreAudio
import Foundation
import ImageIO
import Metal

enum MediaImportError: LocalizedError {
    case unsupportedFile(URL)
    case unreadableImage(URL)
    case cannotConfigureCaptureDevice(String)
    case cannotConfigureNDIDevice(String)
    case cannotConfigureSyphonDevice(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFile(let url):
            return "\(url.lastPathComponent) is not a supported image or video file."
        case .unreadableImage(let url):
            return "ProMap could not decode \(url.lastPathComponent)."
        case .cannotConfigureCaptureDevice(let name):
            return "ProMap could not start video capture from \(name)."
        case .cannotConfigureNDIDevice(let name):
            return "ProMap could not connect to the NDI source \(name). Check that it is online and that the NDI runtime is installed."
        case .cannotConfigureSyphonDevice(let name):
            return "ProMap could not connect to the Syphon server \(name). Check that it is still running."
        }
    }
}

struct CapturedVideoFrame {
    let pixelBuffer: CVPixelBuffer
    let sequence: UInt64
    let width: Int
    let height: Int
    let framesPerSecond: Double?

    init(pixelBuffer: CVPixelBuffer, sequence: UInt64, framesPerSecond: Double? = nil) {
        self.pixelBuffer = pixelBuffer
        self.sequence = sequence
        width = CVPixelBufferGetWidth(pixelBuffer)
        height = CVPixelBufferGetHeight(pixelBuffer)
        self.framesPerSecond = framesPerSecond.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
    }
}

struct CaptureFormatOption: Identifiable, Equatable {
    let width: Int32
    let height: Int32
    let framesPerSecond: Int

    var id: String { "\(width)x\(height)@\(framesPerSecond)" }
    var title: String { "\(width) × \(height) · \(framesPerSecond) fps" }
}

struct AudioOutputDevice: Identifiable, Equatable {
    let uniqueID: String
    let name: String

    var id: String { uniqueID }

    static func availableDevices() -> [AudioOutputDevice] {
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &devicesAddress,
            0,
            nil,
            &dataSize
        ) == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var deviceIDs = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        let readStatus = deviceIDs.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &devicesAddress,
                0,
                nil,
                &dataSize,
                buffer.baseAddress!
            )
        }
        guard readStatus == noErr else { return [] }

        return deviceIDs.compactMap { deviceID in
            guard Self.hasOutputStreams(deviceID),
                  let uniqueID = Self.stringProperty(kAudioDevicePropertyDeviceUID, deviceID: deviceID),
                  let name = Self.stringProperty(kAudioObjectPropertyName, deviceID: deviceID) else { return nil }
            return AudioOutputDevice(uniqueID: uniqueID, name: name)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func deviceID(uniqueID: String) -> AudioDeviceID? {
        var devicesAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return nil }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: kAudioObjectUnknown, count: count)
        let result = deviceIDs.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &devicesAddress, 0, nil, &dataSize, buffer.baseAddress!)
        }
        guard result == noErr else { return nil }
        return deviceIDs.first { Self.stringProperty(kAudioDevicePropertyDeviceUID, deviceID: $0) == uniqueID }
    }

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    private static func stringProperty(_ selector: AudioObjectPropertySelector, deviceID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString?
        var dataSize = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &value) { valuePointer in
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, valuePointer)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }

    private static func hasOutputStreams(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize >= MemoryLayout<AudioBufferList>.size else { return false }
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, storage) == noErr else { return false }
        return storage.assumingMemoryBound(to: AudioBufferList.self).pointee.mNumberBuffers > 0
    }
}

private final class CaptureFrameStore: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let lock = NSLock()
    private var latestFrame: CapturedVideoFrame?
    private var sequence: UInt64 = 0

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        sequence &+= 1
        latestFrame = CapturedVideoFrame(pixelBuffer: pixelBuffer, sequence: sequence)
        lock.unlock()
    }

    func snapshot() -> CapturedVideoFrame? {
        lock.lock()
        defer { lock.unlock() }
        return latestFrame
    }

    func clear() {
        lock.lock()
        latestFrame = nil
        lock.unlock()
    }
}

final class MediaSource: ObservableObject, Identifiable {
    enum Kind {
        case image
        case video
        case capture
        case ndi
        case syphon
        case generator
    }

    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "tif", "tiff", "gif"]
    static let videoExtensions: Set<String> = ["mov", "mp4", "m4v"]
    static let supportedExtensions = Array(imageExtensions.union(videoExtensions)).sorted()

    let id = UUID()
    let url: URL
    let kind: Kind
    let image: CGImage?
    let player: AVPlayer?
    let videoOutput: AVPlayerItemVideoOutput?
    private(set) var captureSession: AVCaptureSession?
    let captureDeviceID: String?
    let captureDeviceName: String?
    let ndiSourceName: String?
    private let ndiSourceReference: String?
    let syphonSourceName: String?
    private let syphonSourceReference: String?
    let ndiFallbackMode: NDIFallbackMode?
    @Published private(set) var generator: VisualGenerator?
    private(set) var captureDevice: AVCaptureDevice?
    private(set) var captureFormatOptions: [CaptureFormatOption]
    private let captureFrameStore: CaptureFrameStore?
    private let ndiReceiver: NDIReceiver?
    private let syphonReceiver: SyphonReceiver?

    @Published private(set) var isPlaying = false
    @Published private(set) var isAudioMuted = true
    @Published private(set) var audioVolume = 1.0
    @Published private(set) var audioDelayMilliseconds = 0.0
    @Published private(set) var audioMeterLevel = 0.0
    private var masterAudioVolume = 1.0
    @Published private(set) var isCaptureConnected = true
    @Published private(set) var captureFormatLabel = "Device Default"
    @Published private(set) var capturePreviewImage: NSImage?
    private var lastCapturePreviewSequence: UInt64 = 0
    private var isCapturePreviewProcessing = false
    private let capturePreviewLock = NSLock()

    private static let capturePreviewContext = CIContext(options: [.useSoftwareRenderer: false])
    private static let capturePreviewQueue = DispatchQueue(label: "ProMap.capture-preview", qos: .utility)

    var title: String { captureDeviceName ?? ndiSourceName ?? syphonSourceName ?? generator?.title ?? url.deletingPathExtension().lastPathComponent }
    var fileExtension: String { kind == .capture || kind == .ndi || kind == .syphon ? "LIVE" : (kind == .generator ? "GEN" : url.pathExtension.uppercased()) }
    var reference: String {
        if let ndiSourceReference { return ndiSourceReference }
        if let syphonSourceReference { return syphonSourceReference }
        if let generator { return generator.reference }
        guard let captureDeviceID else { return url.standardizedFileURL.path }
        return Self.captureReference(forDeviceID: captureDeviceID)
    }
    var latestCaptureFrame: CapturedVideoFrame? { captureFrameStore?.snapshot() ?? ndiReceiver?.snapshot() ?? syphonReceiver?.snapshot() }
    var liveInputMetadata: String {
        guard let frame = latestCaptureFrame else { return isCaptureConnected ? "Waiting for video" : "No signal" }
        let size = "\(frame.width) × \(frame.height)"
        guard let framesPerSecond = frame.framesPerSecond else { return size }
        return "\(size) · \(framesPerSecond.formatted(.number.precision(.fractionLength(0...2)))) fps"
    }
    private static func availableCaptureFormats(for captureDevice: AVCaptureDevice) -> [CaptureFormatOption] {
        let commonRates = [24, 25, 30, 50, 60]
        var seen = Set<String>()
        return captureDevice.formats.flatMap { format -> [CaptureFormatOption] in
            let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let supportedRates = commonRates.filter { rate in
                format.videoSupportedFrameRateRanges.contains { range in
                    Double(rate) >= range.minFrameRate && Double(rate) <= range.maxFrameRate
                }
            }
            return supportedRates.compactMap { rate in
                let option = CaptureFormatOption(width: dimensions.width, height: dimensions.height, framesPerSecond: rate)
                return seen.insert(option.id).inserted ? option : nil
            }
        }
        .sorted { lhs, rhs in
            if lhs.width * lhs.height != rhs.width * rhs.height { return lhs.width * lhs.height < rhs.width * rhs.height }
            return lhs.framesPerSecond < rhs.framesPerSecond
        }
    }

    static func captureReference(forDeviceID deviceID: String) -> String {
        let encodedID = Data(deviceID.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "capture://\(encodedID)"
    }

    init(url: URL) throws {
        let fileExtension = url.pathExtension.lowercased()
        self.url = url

        if Self.imageExtensions.contains(fileExtension) {
            guard
                let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                let decodedImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
            else {
                throw MediaImportError.unreadableImage(url)
            }

            kind = .image
            image = decodedImage
            player = nil
            videoOutput = nil
            captureSession = nil
            captureDeviceID = nil
            captureDeviceName = nil
            ndiSourceName = nil
            ndiSourceReference = nil
            syphonSourceName = nil
            syphonSourceReference = nil
            ndiFallbackMode = nil
            generator = nil
            captureDevice = nil
            captureFormatOptions = []
            captureFrameStore = nil
            ndiReceiver = nil
            syphonReceiver = nil
        } else if Self.videoExtensions.contains(fileExtension) {
            let item = AVPlayerItem(url: url)
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            item.add(output)
            let videoPlayer = AVPlayer(playerItem: item)
            videoPlayer.isMuted = true

            kind = .video
            image = nil
            player = videoPlayer
            videoOutput = output
            captureSession = nil
            captureDeviceID = nil
            captureDeviceName = nil
            ndiSourceName = nil
            ndiSourceReference = nil
            syphonSourceName = nil
            syphonSourceReference = nil
            ndiFallbackMode = nil
            generator = nil
            captureDevice = nil
            captureFormatOptions = []
            captureFrameStore = nil
            ndiReceiver = nil
            syphonReceiver = nil
        } else {
            throw MediaImportError.unsupportedFile(url)
        }
    }

    init(captureDevice: AVCaptureDevice) throws {
        guard let sourceURL = URL(string: Self.captureReference(forDeviceID: captureDevice.uniqueID)) else {
            throw MediaImportError.cannotConfigureCaptureDevice(captureDevice.localizedName)
        }
        url = sourceURL
        kind = .capture
        image = nil
        player = nil
        videoOutput = nil
        captureDeviceID = captureDevice.uniqueID
        captureDeviceName = captureDevice.localizedName
        ndiSourceName = nil
        ndiSourceReference = nil
        syphonSourceName = nil
        syphonSourceReference = nil
        ndiFallbackMode = nil
        generator = nil
        self.captureDevice = captureDevice
        captureFormatOptions = Self.availableCaptureFormats(for: captureDevice)
        isCaptureConnected = captureDevice.isConnected

        let session = AVCaptureSession()
        let input = try AVCaptureDeviceInput(device: captureDevice)
        let output = AVCaptureVideoDataOutput()
        let frameStore = CaptureFrameStore()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true

        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw MediaImportError.cannotConfigureCaptureDevice(captureDevice.localizedName)
        }
        session.beginConfiguration()
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        output.setSampleBufferDelegate(frameStore, queue: DispatchQueue(label: "ProMap.capture.\(captureDevice.uniqueID)"))
        captureSession = session
        captureFrameStore = frameStore
        ndiReceiver = nil
        syphonReceiver = nil
        applySavedCaptureFormat()
        DispatchQueue.global(qos: .userInitiated).async {
            if !session.isRunning { session.startRunning() }
        }
    }

    init(ndiSource: NDISourceDescriptor) throws {
        guard let sourceURL = URL(string: ndiSource.reference) else {
            throw MediaImportError.cannotConfigureNDIDevice(ndiSource.name)
        }
        url = sourceURL
        kind = .ndi
        image = nil
        player = nil
        videoOutput = nil
        captureSession = nil
        captureDeviceID = nil
        captureDeviceName = nil
        ndiSourceName = ndiSource.name
        ndiSourceReference = ndiSource.reference
        syphonSourceName = nil
        syphonSourceReference = nil
        let fallbackMode = NDIFallbackMode(
            rawValue: UserDefaults.standard.string(forKey: "ndiFallbackMode") ?? "black"
        ) ?? .black
        ndiFallbackMode = fallbackMode
        generator = nil
        captureDevice = nil
        captureFormatOptions = []
        captureFrameStore = nil
        syphonReceiver = nil
        isCaptureConnected = false

        let bandwidth = NDIReceiveBandwidth(
            rawValue: UserDefaults.standard.string(forKey: "ndiReceiveBandwidth") ?? "full"
        ) ?? .full
        let receiver = try NDIReceiver(source: ndiSource, bandwidth: bandwidth, fallbackMode: fallbackMode)
        ndiReceiver = receiver
        let defaults = UserDefaults.standard
        let muteKey = Self.ndiAudioPreferenceKey("muted", reference: ndiSource.reference)
        let volumeKey = Self.ndiAudioPreferenceKey("volume", reference: ndiSource.reference)
        let delayKey = Self.ndiAudioPreferenceKey("delay", reference: ndiSource.reference)
        restoreAudio(
            isMuted: defaults.object(forKey: muteKey) as? Bool ?? true,
            volume: defaults.object(forKey: volumeKey) as? Double ?? 1
        )
        setAudioDelayMilliseconds(defaults.double(forKey: delayKey))
        receiver.statusHandler = { [weak self] isConnected in
            guard let self else { return }
            self.isCaptureConnected = isConnected
            if !isConnected && fallbackMode == .black { self.capturePreviewImage = nil }
        }
    }

    init(syphonSource: SyphonSourceDescriptor, device: MTLDevice) throws {
        guard let sourceURL = URL(string: syphonSource.reference) else {
            throw MediaImportError.cannotConfigureSyphonDevice(syphonSource.displayName)
        }
        url = sourceURL
        kind = .syphon
        image = nil
        player = nil
        videoOutput = nil
        captureSession = nil
        captureDeviceID = nil
        captureDeviceName = nil
        ndiSourceName = nil
        ndiSourceReference = nil
        syphonSourceName = syphonSource.displayName
        syphonSourceReference = syphonSource.reference
        ndiFallbackMode = .black
        generator = nil
        captureDevice = nil
        captureFormatOptions = []
        captureFrameStore = nil
        ndiReceiver = nil
        isCaptureConnected = false

        let receiver = try SyphonReceiver(source: syphonSource, device: device)
        syphonReceiver = receiver
        receiver.statusHandler = { [weak self] isConnected in
            guard let self else { return }
            self.isCaptureConnected = isConnected
            if !isConnected { self.capturePreviewImage = nil }
        }
    }

    init(generator: VisualGenerator) {
        let configuration = generator.sanitized()
        self.generator = configuration
        url = URL(string: configuration.reference)!
        kind = .generator
        image = nil
        player = nil
        videoOutput = nil
        captureSession = nil
        captureDeviceID = nil
        captureDeviceName = nil
        ndiSourceName = nil
        ndiSourceReference = nil
            syphonSourceName = nil
            syphonSourceReference = nil
        ndiFallbackMode = nil
        captureDevice = nil
        captureFormatOptions = []
        captureFrameStore = nil
        ndiReceiver = nil
            syphonReceiver = nil
    }

    func updateGeneratorConfiguration(_ configuration: VisualGenerator) -> (oldReference: String, newReference: String)? {
        guard kind == .generator, let current = generator else { return nil }
        let updated = configuration.sanitized()
        guard current != updated else { return nil }
        let oldReference = current.reference
        generator = updated
        return (oldReference, updated.reference)
    }

    deinit {
        stopCapture()
    }

    func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func stop() {
        player?.pause()
        player?.seek(to: .zero)
        isPlaying = false
    }

    func makeSilentPreviewCopy(isPlaying: Bool, at seconds: Double) -> MediaSource? {
        guard kind == .video, let copy = try? MediaSource(url: url) else { return nil }
        copy.restoreAudio(isMuted: true, volume: 0)
        copy.restorePlayback(isPlaying: isPlaying, at: seconds)
        return copy
    }

    func restoreAudio(isMuted: Bool, volume: Double) {
        let boundedVolume = min(max(volume.isFinite ? volume : 1, 0), 1)
        self.isAudioMuted = isMuted
        self.audioVolume = boundedVolume
        player?.isMuted = isMuted
        player?.volume = Float(boundedVolume * masterAudioVolume)
        ndiReceiver?.setAudioMuted(isMuted)
        ndiReceiver?.setAudioVolume(boundedVolume)
        if kind == .ndi, let reference = ndiSourceReference {
            let defaults = UserDefaults.standard
            defaults.set(isMuted, forKey: Self.ndiAudioPreferenceKey("muted", reference: reference))
            defaults.set(boundedVolume, forKey: Self.ndiAudioPreferenceKey("volume", reference: reference))
        }
    }

    func setMasterAudioVolume(_ volume: Double) {
        masterAudioVolume = min(max(volume.isFinite ? volume : 1, 0), 1)
        player?.volume = Float(audioVolume * masterAudioVolume)
        ndiReceiver?.setMasterAudioVolume(masterAudioVolume)
    }

    func setAudioOutputDeviceUID(_ uniqueID: String?) {
        player?.audioOutputDeviceUniqueID = uniqueID
        ndiReceiver?.setAudioOutputDeviceUID(uniqueID)
    }

    func setAudioMuted(_ muted: Bool) {
        restoreAudio(isMuted: muted, volume: audioVolume)
    }

    func setAudioVolume(_ volume: Double) {
        restoreAudio(isMuted: isAudioMuted, volume: volume)
    }

    func setAudioDelayMilliseconds(_ milliseconds: Double) {
        let bounded = min(max(milliseconds.isFinite ? milliseconds : 0, 0), 500)
        guard audioDelayMilliseconds != bounded else { return }
        audioDelayMilliseconds = bounded
        ndiReceiver?.setAudioDelayMilliseconds(bounded)
        if kind == .ndi, let reference = ndiSourceReference {
            UserDefaults.standard.set(bounded, forKey: Self.ndiAudioPreferenceKey("delay", reference: reference))
        }
    }

    func refreshAudioMeter() {
        guard kind == .ndi else { return }
        let level = ndiReceiver?.audioMeterLevel ?? 0
        if abs(audioMeterLevel - level) > 0.008 { audioMeterLevel = level }
    }

    private static func ndiAudioPreferenceKey(_ preference: String, reference: String) -> String {
        "ndiAudio.\(preference).\(reference)"
    }

    func setCaptureFormat(_ option: CaptureFormatOption) {
        guard let captureDevice, let captureSession,
              let format = captureDevice.formats.first(where: { format in
                  let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                  return dimensions.width == option.width
                      && dimensions.height == option.height
                      && format.videoSupportedFrameRateRanges.contains {
                          Double(option.framesPerSecond) >= $0.minFrameRate
                              && Double(option.framesPerSecond) <= $0.maxFrameRate
                      }
              }) else { return }
        do {
            try captureDevice.lockForConfiguration()
            captureSession.beginConfiguration()
            captureDevice.activeFormat = format
            let frameDuration = CMTime(value: 1, timescale: CMTimeScale(option.framesPerSecond))
            captureDevice.activeVideoMinFrameDuration = frameDuration
            captureDevice.activeVideoMaxFrameDuration = frameDuration
            captureDevice.unlockForConfiguration()
            captureSession.commitConfiguration()
            captureFormatLabel = option.title
            if let captureDeviceID {
                UserDefaults.standard.set(option.id, forKey: Self.captureFormatDefaultsKey(forDeviceID: captureDeviceID))
            }
        } catch {
            captureFormatLabel = "Format unavailable"
        }
    }

    func updateCaptureConnection(isConnected: Bool) {
        if self.isCaptureConnected && !isConnected {
            captureFrameStore?.clear()
            capturePreviewImage = nil
            capturePreviewLock.lock()
            lastCapturePreviewSequence = 0
            capturePreviewLock.unlock()
            stopCapture()
        }
        isCaptureConnected = isConnected
    }

    func refreshCapturePreview() {
        guard kind == .capture || kind == .ndi || kind == .syphon else { return }
        let mayShowHeldFrame = kind == .ndi && ndiFallbackMode == .holdLastFrame
        guard (isCaptureConnected || mayShowHeldFrame), let capturedFrame = latestCaptureFrame else {
            if capturePreviewImage != nil {
                capturePreviewImage = nil
                capturePreviewLock.lock()
                lastCapturePreviewSequence = 0
                capturePreviewLock.unlock()
            }
            return
        }
        capturePreviewLock.lock()
        guard capturedFrame.sequence != lastCapturePreviewSequence, !isCapturePreviewProcessing else {
            capturePreviewLock.unlock()
            return
        }
        isCapturePreviewProcessing = true
        capturePreviewLock.unlock()

        Self.capturePreviewQueue.async { [weak self] in
            let preview = Self.makeCapturePreview(from: capturedFrame.pixelBuffer)
            DispatchQueue.main.async {
                guard let self else { return }
                self.capturePreviewLock.lock()
                self.isCapturePreviewProcessing = false
                let mayShowHeldFrame = self.kind == .ndi && self.ndiFallbackMode == .holdLastFrame
                let isCurrentFrame = (self.isCaptureConnected || mayShowHeldFrame)
                    && self.latestCaptureFrame?.sequence == capturedFrame.sequence
                if isCurrentFrame, let preview {
                    self.lastCapturePreviewSequence = capturedFrame.sequence
                    self.capturePreviewImage = preview
                }
                self.capturePreviewLock.unlock()
            }
        }
    }

    private static func makeCapturePreview(from pixelBuffer: CVPixelBuffer) -> NSImage? {
        let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
        let sourceBounds = sourceImage.extent
        guard sourceBounds.width > 0, sourceBounds.height > 0 else { return nil }
        let previewWidth: CGFloat = 160
        let previewHeight: CGFloat = 90
        let scale = max(previewWidth / sourceBounds.width, previewHeight / sourceBounds.height)
        let scaledImage = sourceImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let crop = CGRect(
            x: scaledImage.extent.midX - previewWidth * 0.5,
            y: scaledImage.extent.midY - previewHeight * 0.5,
            width: previewWidth,
            height: previewHeight
        )
        guard let cgImage = capturePreviewContext.createCGImage(scaledImage, from: crop) else { return nil }
        return NSImage(cgImage: cgImage, size: CGSize(width: previewWidth, height: previewHeight))
    }

    func reconnectCapture(to device: AVCaptureDevice) {
        guard kind == .capture, device.uniqueID == captureDeviceID,
              !isCaptureConnected, let captureFrameStore else { return }
        do {
            let session = AVCaptureSession()
            let input = try AVCaptureDeviceInput(device: device)
            let output = AVCaptureVideoDataOutput()
            output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            output.alwaysDiscardsLateVideoFrames = true
            guard session.canAddInput(input), session.canAddOutput(output) else {
                throw MediaImportError.cannotConfigureCaptureDevice(device.localizedName)
            }
            session.beginConfiguration()
            session.addInput(input)
            session.addOutput(output)
            session.commitConfiguration()
            output.setSampleBufferDelegate(captureFrameStore, queue: DispatchQueue(label: "ProMap.capture.\(device.uniqueID)"))

            let previousSession = captureSession
            captureSession = session
            captureDevice = device
            captureFormatOptions = Self.availableCaptureFormats(for: device)
            isCaptureConnected = true
            applySavedCaptureFormat()
            DispatchQueue.global(qos: .userInitiated).async {
                if previousSession?.isRunning == true { previousSession?.stopRunning() }
                if !session.isRunning { session.startRunning() }
            }
        } catch {
            isCaptureConnected = false
            NSLog("ProMap capture reconnect failed for %@: %@", device.localizedName, error.localizedDescription)
        }
    }

    private func applySavedCaptureFormat() {
        guard let captureDeviceID,
              let savedID = UserDefaults.standard.string(forKey: Self.captureFormatDefaultsKey(forDeviceID: captureDeviceID)),
              let option = captureFormatOptions.first(where: { $0.id == savedID }) else { return }
        setCaptureFormat(option)
    }

    private static func captureFormatDefaultsKey(forDeviceID id: String) -> String {
        "ProMap.captureFormat.\(id)"
    }

    func stopCapture() {
        ndiReceiver?.stop()
        syphonReceiver?.stop()
        if let captureSession {
            DispatchQueue.global(qos: .utility).async {
                if captureSession.isRunning { captureSession.stopRunning() }
            }
        }
    }

    func restorePlayback(isPlaying: Bool, at seconds: Double) {
        guard let player else { return }
        let position = max(seconds.isFinite ? seconds : 0, 0)
        player.seek(to: CMTime(seconds: position, preferredTimescale: 600))
        if isPlaying {
            player.play()
        } else {
            player.pause()
        }
        self.isPlaying = isPlaying
    }
}

final class MediaLibrary: ObservableObject {
    @Published private(set) var sources: [MediaSource] = []
    @Published private(set) var importMessage: String?
    @Published private(set) var isImporting = false
    @Published private(set) var captureDevices: [AVCaptureDevice] = []
    private var masterAudioVolume = 1.0
    private var audioOutputDeviceUID: String?

    private var deviceObservers: [NSObjectProtocol] = []
    private var pendingCaptureDeviceIDs: Set<String> = []
    private var pendingNDISourceIDs: Set<String> = []
    private var pendingSyphonSourceIDs: Set<String> = []

    init() {
        refreshCaptureDevices()
        deviceObservers = [
            AVCaptureDevice.wasConnectedNotification,
            AVCaptureDevice.wasDisconnectedNotification
        ].map { notification in
            NotificationCenter.default.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
                self?.refreshCaptureDevices()
            }
        }
    }

    deinit {
        deviceObservers.forEach(NotificationCenter.default.removeObserver)
        sources.forEach { $0.stopCapture() }
    }

    func refreshCaptureDevices() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .externalUnknown],
            mediaType: .video,
            position: .unspecified
        )
        captureDevices = discovery.devices
        for source in sources where source.kind == .capture {
            guard let deviceID = source.captureDeviceID else { continue }
            if let connectedDevice = discovery.devices.first(where: { $0.uniqueID == deviceID }) {
                if source.isCaptureConnected {
                    source.updateCaptureConnection(isConnected: true)
                } else {
                    source.reconnectCapture(to: connectedDevice)
                }
            } else {
                source.updateCaptureConnection(isConnected: false)
            }
        }
    }

    func requestCaptureAccess() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            refreshCaptureDevices()
            importMessage = "Choose a camera or USB capture device from the + menu."
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.refreshCaptureDevices()
                    self.importMessage = granted
                        ? "Camera access granted. Choose a live input from the + menu."
                        : "Camera access was denied. Allow ProMap in the camera privacy controls in System Settings (Security & Privacy on macOS 12)."
                }
            }
        case .denied, .restricted:
            importMessage = "Camera access is unavailable. Check the camera privacy controls in System Settings (Security & Privacy on macOS 12)."
        @unknown default:
            importMessage = "ProMap could not determine camera access."
        }
    }

    func addCaptureDevice(_ device: AVCaptureDevice, completion: (() -> Void)? = nil) {
        guard !sources.contains(where: { $0.captureDeviceID == device.uniqueID }),
              pendingCaptureDeviceIDs.insert(device.uniqueID).inserted else {
            completion?()
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            createCaptureSource(device, completion: completion)
        case .notDetermined:
            importMessage = "Requesting camera access…"
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { completion?(); return }
                    if granted {
                        self.createCaptureSource(device, completion: completion)
                    } else {
                        self.pendingCaptureDeviceIDs.remove(device.uniqueID)
                        self.importMessage = "Camera access was denied. Allow ProMap in the camera privacy controls in System Settings (Security & Privacy on macOS 12)."
                        completion?()
                    }
                }
            }
        case .denied, .restricted:
            pendingCaptureDeviceIDs.remove(device.uniqueID)
            importMessage = "Camera access is unavailable. Check the camera privacy controls in System Settings (Security & Privacy on macOS 12)."
            completion?()
        @unknown default:
            pendingCaptureDeviceIDs.remove(device.uniqueID)
            importMessage = "ProMap could not determine camera access."
            completion?()
        }
    }

    func addNDISource(_ ndiSource: NDISourceDescriptor, completion: (() -> Void)? = nil) {
        guard !sources.contains(where: { $0.reference == ndiSource.reference }),
              pendingNDISourceIDs.insert(ndiSource.reference).inserted else {
            completion?()
            return
        }
        isImporting = true
        importMessage = "Connecting to NDI source \(ndiSource.name)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try MediaSource(ndiSource: ndiSource) }
            DispatchQueue.main.async {
                self.isImporting = false
                self.pendingNDISourceIDs.remove(ndiSource.reference)
                switch result {
                case .success(let source):
                    source.setMasterAudioVolume(self.masterAudioVolume)
                    source.setAudioOutputDeviceUID(self.audioOutputDeviceUID)
                    self.sources.append(source)
                    self.importMessage = "NDI input ready: \(ndiSource.name)."
                case .failure(let error):
                    self.importMessage = error.localizedDescription
                }
                completion?()
            }
        }
    }

    func addSyphonSource(_ syphonSource: SyphonSourceDescriptor, device: MTLDevice?, completion: (() -> Void)? = nil) {
        guard !sources.contains(where: { $0.reference == syphonSource.reference }),
              pendingSyphonSourceIDs.insert(syphonSource.reference).inserted else {
            completion?()
            return
        }
        guard let device else {
            pendingSyphonSourceIDs.remove(syphonSource.reference)
            importMessage = "Syphon input needs an available Metal device."
            completion?()
            return
        }
        isImporting = true
        importMessage = "Connecting to Syphon server \(syphonSource.displayName)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try MediaSource(syphonSource: syphonSource, device: device) }
            DispatchQueue.main.async {
                self.isImporting = false
                self.pendingSyphonSourceIDs.remove(syphonSource.reference)
                switch result {
                case .success(let source):
                    source.setMasterAudioVolume(self.masterAudioVolume)
                    source.setAudioOutputDeviceUID(self.audioOutputDeviceUID)
                    self.sources.append(source)
                    self.importMessage = "Syphon input ready: \(syphonSource.displayName)."
                case .failure(let error):
                    self.importMessage = error.localizedDescription
                }
                completion?()
            }
        }
    }

    @discardableResult
    func addGenerator(_ generator: VisualGenerator) -> MediaSource {
        let configuration = generator.sanitized()
        if let existing = sources.first(where: { $0.reference == configuration.reference }) {
            return existing
        }
        let source = MediaSource(generator: configuration)
        sources.append(source)
        importMessage = "Generated visual ready: \(configuration.title)."
        return source
    }

    func restoreGeneratorSources(references: [String], completion: () -> Void = {}) {
        let existingReferences = Set(sources.map(\.reference))
        let configurations = references
            .filter { $0.hasPrefix("generator://") && !existingReferences.contains($0) }
            .compactMap(VisualGenerator.init(reference:))
        configurations.forEach { _ = addGenerator($0) }
        completion()
    }

    func restoreNDISources(references: [String], completion: @escaping () -> Void = {}) {
        let wantedSources = references.compactMap(NDISourceDescriptor.descriptor(from:))
        guard !wantedSources.isEmpty else { completion(); return }
        let matchingSources = wantedSources.compactMap { wanted in
            NDIService.shared.sources.first(where: { $0.name == wanted.name })
                ?? (wanted.url.isEmpty ? nil : wanted)
        }
        let uniqueSources = Dictionary(matchingSources.map { ($0.reference, $0) }, uniquingKeysWith: { first, _ in first }).values
        guard !uniqueSources.isEmpty else { completion(); return }
        var remaining = uniqueSources.count
        for source in uniqueSources {
            addNDISource(source) {
                remaining -= 1
                if remaining == 0 { completion() }
            }
        }
    }

    func restoreSyphonSources(references: [String], device: MTLDevice?, completion: @escaping () -> Void = {}) {
        let wantedReferences = Set(references.filter { SyphonSourceDescriptor.serverID(from: $0) != nil })
        let existingReferences = Set(sources.map(\.reference))
        let wantedSources = SyphonService.shared.sources.filter {
            wantedReferences.contains($0.reference) && !existingReferences.contains($0.reference)
        }
        guard !wantedSources.isEmpty else { completion(); return }
        var remaining = wantedSources.count
        for source in wantedSources {
            addSyphonSource(source, device: device) {
                remaining -= 1
                if remaining == 0 { completion() }
            }
        }
    }

    func restoreCaptureSources(references: [String], completion: @escaping () -> Void) {
        let wanted = Set(references.filter { $0.hasPrefix("capture://") })
        guard !wanted.isEmpty else { completion(); return }
        let existingDeviceIDs = Set(sources.compactMap(\.captureDeviceID))
        let devicesToRestore = captureDevices.filter {
            wanted.contains(MediaSource.captureReference(forDeviceID: $0.uniqueID))
                && !existingDeviceIDs.contains($0.uniqueID)
        }
        guard !devicesToRestore.isEmpty else { completion(); return }

        var remaining = devicesToRestore.count
        for device in devicesToRestore {
            addCaptureDevice(device) {
                remaining -= 1
                if remaining == 0 { completion() }
            }
        }
    }

    private func createCaptureSource(_ device: AVCaptureDevice, completion: (() -> Void)?) {
        isImporting = true
        importMessage = "Starting capture from \(device.localizedName)…"
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try MediaSource(captureDevice: device) }
            DispatchQueue.main.async {
                self.isImporting = false
                self.pendingCaptureDeviceIDs.remove(device.uniqueID)
                switch result {
                case .success(let source):
                    source.setMasterAudioVolume(self.masterAudioVolume)
                    source.setAudioOutputDeviceUID(self.audioOutputDeviceUID)
                    self.sources.append(source)
                    self.importMessage = "Live input ready: \(device.localizedName)."
                case .failure(let error):
                    self.importMessage = error.localizedDescription
                }
                completion?()
            }
        }
    }

    func importFiles(_ urls: [URL], completion: (([MediaSource]) -> Void)? = nil) {
        guard !urls.isEmpty else { return }
        isImporting = true
        importMessage = "Importing \(urls.count) item\(urls.count == 1 ? "" : "s")…"

        DispatchQueue.global(qos: .userInitiated).async {
            var imported: [MediaSource] = []
            var failures: [String] = []

            for url in urls {
                do {
                    imported.append(try MediaSource(url: url))
                } catch {
                    failures.append(error.localizedDescription)
                }
            }

            DispatchQueue.main.async {
                imported.forEach {
                    $0.setMasterAudioVolume(self.masterAudioVolume)
                    $0.setAudioOutputDeviceUID(self.audioOutputDeviceUID)
                }
                self.sources.append(contentsOf: imported)
                if failures.isEmpty {
                    self.importMessage = "Imported \(imported.count) item\(imported.count == 1 ? "" : "s")."
                } else {
                    self.importMessage = failures.joined(separator: "\n")
                }
                self.isImporting = false
                completion?(imported)
            }
        }
    }

    func remove(_ source: MediaSource) {
        source.stopCapture()
        sources.removeAll { $0.id == source.id }
    }

    func setMasterAudioVolume(_ volume: Double) {
        masterAudioVolume = min(max(volume.isFinite ? volume : 1, 0), 1)
        sources.forEach { $0.setMasterAudioVolume(masterAudioVolume) }
    }

    func setAudioOutputDevice(_ uniqueID: String?) {
        audioOutputDeviceUID = uniqueID
        sources.forEach { $0.setAudioOutputDeviceUID(uniqueID) }
    }
}

struct RenderLayer: Identifiable {
    var id: UUID
    let source: MediaSource
    var name: String?
    var isEnabled: Bool
    var isSolo: Bool
    var isLocked: Bool
    var opacity: Double
    var contentTransform: SurfaceContentTransform?
    var effectStack: [SurfaceEffect]?

    init(
        id: UUID = UUID(),
        source: MediaSource,
        name: String? = nil,
        isEnabled: Bool = true,
        isSolo: Bool = false,
        isLocked: Bool = false,
        opacity: Double = 1,
        contentTransform: SurfaceContentTransform? = nil,
        effectStack: [SurfaceEffect]? = nil
    ) {
        self.id = id
        self.source = source
        self.name = name.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)) }
        self.isEnabled = isEnabled
        self.isSolo = isSolo
        self.isLocked = isLocked
        self.opacity = min(max(opacity, 0), 1)
        self.contentTransform = contentTransform?.sanitized()
        self.effectStack = effectStack?.prefix(SurfaceEffect.maximumStackSize).map { $0.sanitized() }
    }

    var displayName: String {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? source.title : trimmed
    }

    var savedState: SavedLayerState {
        let currentTime = source.player?.currentTime().seconds ?? 0
        return SavedLayerState(
            id: id,
            sourcePath: source.reference,
            layerName: name,
            isEnabled: isEnabled,
            isSolo: isSolo,
            isLocked: isLocked,
            opacity: opacity,
            contentTransform: contentTransform,
            isPlaying: source.isPlaying,
            playbackTime: currentTime.isFinite ? max(currentTime, 0) : 0,
            effectStack: effectStack,
            isAudioMuted: source.isAudioMuted,
            audioVolume: source.audioVolume,
            audioDelayMilliseconds: source.kind == .ndi ? source.audioDelayMilliseconds : nil
        )
    }
}

struct RenderSnapshot {
    let layers: [RenderLayer]
    let sourceCatalog: [MediaSource]
    let surfaces: [ProjectionSurface]
    let outputs: [ProjectionOutput]
    let isBlackout: Bool
    let outputIntensity: Double
    let calibrationPattern: CalibrationPattern
}

private struct SurfaceGeometrySnapshot: Equatable {
    let id: UUID
    let outputs: [ProjectionOutput]
    let corners: [NormalizedPoint]
    let maskPoints: [NormalizedPoint]
    let additionalMaskPaths: [ProjectionMaskPath]
    let meshWarp: MeshWarp?
    let contentTransform: SurfaceContentTransform?

    init(_ surface: ProjectionSurface, outputs: [ProjectionOutput]) {
        id = surface.id
        self.outputs = outputs
        corners = surface.corners
        maskPoints = surface.maskPoints
        additionalMaskPaths = surface.additionalMaskPaths ?? []
        meshWarp = surface.meshWarp
        contentTransform = surface.contentTransform
    }
}

final class RenderSession: ObservableObject {
    @Published private(set) var layers: [RenderLayer] = []
    @Published private(set) var surfaces: [ProjectionSurface] = [.main]
    @Published private(set) var outputs: [ProjectionOutput] = [.main]
    @Published private(set) var isBlackout = false
    @Published private(set) var outputIntensity = 1.0
    @Published private(set) var isMappingLocked = false
    @Published private(set) var calibrationPattern: CalibrationPattern = .off
    @Published private(set) var scenes: [ScenePreset] = []
    @Published private(set) var currentSceneID: UUID?
    @Published private(set) var canUndoGeometry = false
    @Published private(set) var canRedoGeometry = false

    private let lock = NSLock()
    private var renderLayers: [RenderLayer] = []
    private var renderSourceCatalog: [MediaSource] = []
    private var renderSurfaces: [ProjectionSurface] = [.main]
    private var renderOutputs: [ProjectionOutput] = [.main]
    private var renderBlackout = false
    private var renderOutputIntensity = 1.0
    private var renderCalibrationPattern: CalibrationPattern = .off
    private var sceneTransitionID = UUID()
    private var geometryUndoHistory: [[SurfaceGeometrySnapshot]] = []
    private var geometryRedoHistory: [[SurfaceGeometrySnapshot]] = []
    private var geometryEditSnapshot: [SurfaceGeometrySnapshot]?
    private var stagedPreviewSources: [MediaSource] = []

    func setSourceCatalog(_ sources: [MediaSource]) {
        lock.lock()
        renderSourceCatalog = sources
        lock.unlock()
    }

    func addLayer(source: MediaSource) {
        var updated = layers
        updated.append(RenderLayer(source: source))
        commit(layers: updated, surfaces: surfaces)
    }

    func renameLayer(_ layerID: UUID, to name: String) {
        let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
        guard !trimmed.isEmpty else { return }
        var updated = layers
        guard let index = updated.firstIndex(where: { $0.id == layerID }), updated[index].displayName != trimmed else { return }
        updated[index].name = trimmed
        commit(layers: updated, surfaces: surfaces)
    }

    func duplicateLayer(_ layerID: UUID) {
        guard let index = layers.firstIndex(where: { $0.id == layerID }) else { return }
        var duplicate = layers[index]
        duplicate.id = UUID()
        duplicate.name = String("\(duplicate.displayName) Copy".prefix(80))
        duplicate.isEnabled = true
        duplicate.isSolo = false
        duplicate.isLocked = false
        var updated = layers
        updated.insert(duplicate, at: index + 1)
        commit(layers: updated, surfaces: surfaces)
    }

    func setLayerLocked(_ locked: Bool, for layerID: UUID) {
        var updated = layers
        guard let index = updated.firstIndex(where: { $0.id == layerID }), updated[index].isLocked != locked else { return }
        updated[index].isLocked = locked
        commit(layers: updated, surfaces: surfaces)
    }

    func removeLayer(_ layer: RenderLayer) {
        guard let existing = layers.first(where: { $0.id == layer.id }), !existing.isLocked else { return }
        commit(layers: layers.filter { $0.id != layer.id }, surfaces: surfaces)
    }

    func setEnabled(_ enabled: Bool, for layerID: UUID) {
        var updated = layers
        guard let index = updated.firstIndex(where: { $0.id == layerID }) else { return }
        updated[index].isEnabled = enabled
        commit(layers: updated, surfaces: surfaces)
    }

    func setSolo(_ solo: Bool, for layerID: UUID) {
        var updated = layers
        guard let index = updated.firstIndex(where: { $0.id == layerID }), updated[index].isSolo != solo else { return }
        updated[index].isSolo = solo
        commit(layers: updated, surfaces: surfaces)
    }

    func moveLayer(_ layerID: UUID, by offset: Int) {
        guard offset != 0, let sourceIndex = layers.firstIndex(where: { $0.id == layerID }) else { return }
        let destinationIndex = sourceIndex + offset
        guard layers.indices.contains(destinationIndex), !layers[sourceIndex].isLocked else { return }
        let step = offset > 0 ? 1 : -1
        for crossedIndex in stride(from: sourceIndex + step, through: destinationIndex, by: step) {
            guard !layers[crossedIndex].isLocked else { return }
        }
        var updated = layers
        let layer = updated.remove(at: sourceIndex)
        updated.insert(layer, at: destinationIndex)
        commit(layers: updated, surfaces: surfaces)
    }

    func setOpacity(_ opacity: Double, for layerID: UUID) {
        var updated = layers
        guard let index = updated.firstIndex(where: { $0.id == layerID }), !updated[index].isLocked else { return }
        updated[index].opacity = min(max(opacity, 0), 1)
        commit(layers: updated, surfaces: surfaces)
    }

    func setContentTransform(_ transform: SurfaceContentTransform, for layerID: UUID) {
        var updated = layers
        guard let index = updated.firstIndex(where: { $0.id == layerID }), !updated[index].isLocked else { return }
        let sanitized = transform.sanitized()
        guard updated[index].contentTransform?.sanitized() != sanitized else { return }
        updated[index].contentTransform = sanitized
        commit(layers: updated, surfaces: surfaces)
    }

    func setEffectStack(_ effects: [SurfaceEffect], for layerID: UUID) {
        var updated = layers
        guard let index = updated.firstIndex(where: { $0.id == layerID }), !updated[index].isLocked else { return }
        let sanitized = effects.prefix(SurfaceEffect.maximumStackSize).map { $0.sanitized() }
        updated[index].effectStack = sanitized.isEmpty ? nil : sanitized
        commit(layers: updated, surfaces: surfaces)
    }

    func toggleBlackout() {
        setBlackout(!isBlackout)
    }

    func setBlackout(_ enabled: Bool) {
        guard isBlackout != enabled else { return }
        commit(layers: layers, surfaces: surfaces, blackout: enabled)
    }

    func setOutputIntensity(_ intensity: Double) {
        let bounded = min(max(intensity.isFinite ? intensity : 0, 0), 1)
        guard outputIntensity != bounded else { return }
        lock.lock()
        renderOutputIntensity = bounded
        lock.unlock()
        outputIntensity = bounded
    }

    func setSurfaceActive(_ active: Bool, on surfaceID: UUID) {
        guard var surface = surfaces.first(where: { $0.id == surfaceID }), surface.isVisible != active else { return }
        surface.isVisible = active
        updateSurface(surface)
    }

    func setSurfaceBlackout(_ blackout: Bool, on surfaceID: UUID) {
        guard var surface = surfaces.first(where: { $0.id == surfaceID }), surface.isBlackout != blackout else { return }
        surface.isBlackout = blackout
        updateSurface(surface)
    }

    func setSurfaceIntensity(_ intensity: Double, on surfaceID: UUID) {
        guard var surface = surfaces.first(where: { $0.id == surfaceID }) else { return }
        let bounded = min(max(intensity.isFinite ? intensity : 0, 0), 1)
        guard surface.brightness != bounded else { return }
        surface.brightness = bounded
        updateSurface(surface)
    }

    func setMappingLocked(_ locked: Bool) {
        guard isMappingLocked != locked else { return }
        isMappingLocked = locked
    }

    func addSurface(_ surface: ProjectionSurface) {
        guard !isMappingLocked else { return }
        commit(layers: layers, surfaces: surfaces + [surface])
    }

    func ensurePhysicalOutput(displayID: String, name: String, width: Int, height: Int) -> ProjectionOutput {
        if let existing = outputs.first(where: { $0.displayID == displayID }) {
            var updated = existing
            updated.name = name
            updated.width = width
            updated.height = height
            updateOutput(updated)
            return updated
        }
        if outputs.count == 1, outputs.first?.id == ProjectionOutput.mainID,
           outputs.first?.displayID == nil {
            var main = outputs[0]
            main.name = name
            main.displayID = displayID
            main.width = width
            main.height = height
            setOutputs([main])
            return main
        }
        let output = ProjectionOutput(name: name, displayID: displayID, width: width, height: height)
        setOutputs(outputs + [output])
        return output
    }

    func ensureVirtualOutput(width: Int, height: Int) -> ProjectionOutput {
        if outputs.count == 1, outputs.first?.id == ProjectionOutput.mainID,
           outputs.first?.displayID == nil {
            var main = outputs[0]
            main.name = "Virtual Output \(width) × \(height)"
            main.width = width
            main.height = height
            setOutputs([main])
            return main
        }
        let output = ProjectionOutput(name: "Virtual Output \(width) × \(height)", width: width, height: height)
        setOutputs(outputs + [output])
        return output
    }

    func updateOutput(_ output: ProjectionOutput) {
        var updated = outputs
        guard let index = updated.firstIndex(where: { $0.id == output.id }) else { return }
        updated[index] = output.sanitized()
        setOutputs(updated)
    }

    func updateOutputMaskConfiguration(
        _ outputID: UUID,
        _ update: (inout ProjectionOutput) -> Void
    ) {
        guard !isMappingLocked else { return }
        guard var output = outputs.first(where: { $0.id == outputID }) else { return }
        update(&output)
        output = output.sanitized()
        guard outputs.first(where: { $0.id == outputID }) != output else { return }
        recordGeometryChange()
        updateOutput(output)
    }

    func removeOutput(_ outputID: UUID) {
        guard !isMappingLocked, outputID != ProjectionOutput.mainID, outputs.contains(where: { $0.id == outputID }) else { return }
        setOutputs(outputs.filter { $0.id != outputID })
        var reassigned = surfaces
        for index in reassigned.indices where reassigned[index].outputID == outputID {
            reassigned[index].outputID = nil
        }
        commit(layers: layers, surfaces: reassigned)
    }

    func assignSurface(_ surfaceID: UUID, to outputID: UUID) {
        guard !isMappingLocked, outputs.contains(where: { $0.id == outputID }),
              var surface = surfaces.first(where: { $0.id == surfaceID }) else { return }
        surface.outputID = outputID == ProjectionOutput.mainID ? nil : outputID
        updateSurface(surface)
    }

    private func setOutputs(_ requestedOutputs: [ProjectionOutput]) {
        var unique: [ProjectionOutput] = []
        var seen = Set<UUID>()
        for output in requestedOutputs.map({ $0.sanitized() }) where seen.insert(output.id).inserted {
            unique.append(output)
        }
        if !seen.contains(ProjectionOutput.mainID) {
            unique.insert(.main, at: 0)
        }
        lock.lock()
        renderOutputs = unique
        lock.unlock()
        outputs = unique
    }

    @discardableResult
    func duplicateSurface(_ surfaceID: UUID) -> UUID? {
        guard !isMappingLocked else { return nil }
        guard var copy = surfaces.first(where: { $0.id == surfaceID }) else { return nil }
        let baseName = "\(copy.name) Copy"
        var name = baseName
        var suffix = 2
        while surfaces.contains(where: { $0.name == name }) {
            name = "\(baseName) \(suffix)"
            suffix += 1
        }
        copy.id = UUID()
        copy.name = name
        copy.isLocked = false
        surfaces.append(copy)
        commit(layers: layers, surfaces: surfaces)
        return copy.id
    }

    func removeSurface(_ surfaceID: UUID) {
        guard !isMappingLocked, surfaces.count > 1 else { return }
        commit(layers: layers, surfaces: surfaces.filter { $0.id != surfaceID })
    }

    func updateSurface(_ surface: ProjectionSurface) {
        var updated = surfaces
        guard let index = updated.firstIndex(where: { $0.id == surface.id }) else { return }
        updated[index] = surface
        commit(layers: layers, surfaces: updated)
    }

    func updateContentTransform(on surfaceID: UUID, _ update: (inout SurfaceContentTransform) -> Void) {
        guard var surface = surfaces.first(where: { $0.id == surfaceID }), !isMappingLocked, !surface.isLocked else { return }
        var transform = surface.contentTransform?.sanitized() ?? .identity
        update(&transform)
        transform = transform.sanitized()
        guard (surface.contentTransform?.sanitized() ?? .identity) != transform else { return }
        recordGeometryChange()
        surface.contentTransform = transform == .identity ? nil : transform
        updateSurface(surface)
    }

    func updateCorner(_ cornerIndex: Int, to point: NormalizedPoint, on surfaceID: UUID) {
        guard let surface = surfaces.first(where: { $0.id == surfaceID }),
              !isMappingLocked, !surface.isLocked, surface.corners.indices.contains(cornerIndex) else { return }
        let updatedPoint = point.clamped()
        guard surface.corners[cornerIndex] != updatedPoint else { return }
        var corners = surface.corners
        corners[cornerIndex] = updatedPoint
        applyTransformedCorners(corners, to: surface)
    }

    /// Moves both corners on one side together so an operator can reshape the
    /// keystone by dragging the edge midpoint instead of targeting two handles.
    func moveSurfaceEdge(_ edgeIndex: Int, to midpoint: NormalizedPoint, on surfaceID: UUID) {
        guard let surface = surfaces.first(where: { $0.id == surfaceID }),
              !isMappingLocked, !surface.isLocked, surface.corners.count == 4,
              (0..<4).contains(edgeIndex) else { return }
        let nextIndex = (edgeIndex + 1) % 4
        let start = surface.corners[edgeIndex]
        let end = surface.corners[nextIndex]
        let currentMidpoint = NormalizedPoint((start.x + end.x) * 0.5, (start.y + end.y) * 0.5)
        let target = midpoint.clamped()
        let dx = target.x - currentMidpoint.x
        let dy = target.y - currentMidpoint.y
        guard abs(dx) > 0.0000001 || abs(dy) > 0.0000001 else { return }

        var corners = surface.corners
        corners[edgeIndex] = NormalizedPoint(start.x + dx, start.y + dy)
        corners[nextIndex] = NormalizedPoint(end.x + dx, end.y + dy)
        applyTransformedCorners(corners, to: surface)
    }

    /// Changes one edge's width while keeping its midpoint fixed.
    /// Positive values widen the edge; negative values narrow it.
    func adjustSurfaceEdgeWidth(_ edgeIndex: Int, by amount: Double, on surfaceID: UUID) {
        guard let surface = surfaces.first(where: { $0.id == surfaceID }),
              !isMappingLocked, !surface.isLocked, surface.corners.count == 4,
              (0..<4).contains(edgeIndex), amount.isFinite, abs(amount) > 0.0000001 else { return }
        let nextIndex = (edgeIndex + 1) % 4
        let start = surface.corners[edgeIndex]
        let end = surface.corners[nextIndex]
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0.0001 else { return }
        let halfAmount = amount * 0.5
        let unitX = dx / length
        let unitY = dy / length

        var corners = surface.corners
        corners[edgeIndex] = NormalizedPoint(start.x - unitX * halfAmount, start.y - unitY * halfAmount)
        corners[nextIndex] = NormalizedPoint(end.x + unitX * halfAmount, end.y + unitY * halfAmount)
        applyTransformedCorners(corners, to: surface)
    }

    func adjustHorizontalKeystone(_ amount: Double, on surfaceID: UUID) {
        adjustKeystone(amount, on: surfaceID) { corners, delta in
            guard corners.count == 4 else { return corners }
            var adjusted = corners
            adjusted[0].x += delta
            adjusted[1].x -= delta
            adjusted[2].x += delta
            adjusted[3].x -= delta
            return adjusted
        }
    }

    func adjustVerticalKeystone(_ amount: Double, on surfaceID: UUID) {
        adjustKeystone(amount, on: surfaceID) { corners, delta in
            guard corners.count == 4 else { return corners }
            var adjusted = corners
            adjusted[0].y += delta
            adjusted[1].y -= delta
            adjusted[2].y += delta
            adjusted[3].y -= delta
            return adjusted
        }
    }

    private func adjustKeystone(
        _ amount: Double,
        on surfaceID: UUID,
        transform: ([NormalizedPoint], Double) -> [NormalizedPoint]
    ) {
        guard let surface = surfaces.first(where: { $0.id == surfaceID }),
              !isMappingLocked, !surface.isLocked, amount.isFinite, abs(amount) > 0.0000001 else { return }
        applyTransformedCorners(transform(surface.corners, amount), to: surface)
    }

    func setMeshWarpEnabled(_ enabled: Bool, on surfaceID: UUID) {
        guard var surface = surfaces.first(where: { $0.id == surfaceID }), !isMappingLocked, !surface.isLocked else { return }
        guard (surface.meshWarp != nil) != enabled else { return }
        surface.meshWarp = enabled ? MeshWarp() : nil
        guard surface.hasUsableGeometry else { return }
        recordGeometryChange()
        updateSurface(surface)
    }

    func setMeshWarpSubdivisions(_ subdivisions: Int, on surfaceID: UUID) {
        guard var surface = surfaces.first(where: { $0.id == surfaceID }),
              !isMappingLocked, !surface.isLocked, let currentWarp = surface.meshWarp?.sanitized() else { return }
        let safeSubdivisions = min(max(subdivisions, 2), 6)
        guard currentWarp.subdivisionCount != safeSubdivisions else { return }
        let oldDivisions = currentWarp.subdivisionCount
        let newInterior = safeSubdivisions - 1

        func offsetAt(row: Int, column: Int) -> NormalizedPoint {
            guard row > 0, row < oldDivisions, column > 0, column < oldDivisions else {
                return NormalizedPoint(0, 0)
            }
            let index = (row - 1) * (oldDivisions - 1) + column - 1
            return currentWarp.controlOffsets[index]
        }

        func interpolatedOffset(x: Double, y: Double) -> NormalizedPoint {
            let gridX = x * Double(oldDivisions)
            let gridY = y * Double(oldDivisions)
            let x0 = min(Int(floor(gridX)), oldDivisions)
            let y0 = min(Int(floor(gridY)), oldDivisions)
            let x1 = min(x0 + 1, oldDivisions)
            let y1 = min(y0 + 1, oldDivisions)
            let tx = gridX - Double(x0)
            let ty = gridY - Double(y0)
            let topLeft = offsetAt(row: y0, column: x0)
            let topRight = offsetAt(row: y0, column: x1)
            let bottomLeft = offsetAt(row: y1, column: x0)
            let bottomRight = offsetAt(row: y1, column: x1)
            let top = NormalizedPoint(
                topLeft.x + (topRight.x - topLeft.x) * tx,
                topLeft.y + (topRight.y - topLeft.y) * tx
            )
            let bottom = NormalizedPoint(
                bottomLeft.x + (bottomRight.x - bottomLeft.x) * tx,
                bottomLeft.y + (bottomRight.y - bottomLeft.y) * tx
            )
            return NormalizedPoint(
                top.x + (bottom.x - top.x) * ty,
                top.y + (bottom.y - top.y) * ty
            )
        }

        var offsets: [NormalizedPoint] = []
        offsets.reserveCapacity(newInterior * newInterior)
        for row in 1..<safeSubdivisions {
            for column in 1..<safeSubdivisions {
                offsets.append(interpolatedOffset(
                    x: Double(column) / Double(safeSubdivisions),
                    y: Double(row) / Double(safeSubdivisions)
                ))
            }
        }
        surface.meshWarp = MeshWarp(subdivisions: safeSubdivisions, controlOffsets: offsets).sanitized()
        guard surface.hasUsableGeometry else { return }
        recordGeometryChange()
        updateSurface(surface)
    }

    func updateMeshControlPoint(_ pointIndex: Int, to point: NormalizedPoint, on surfaceID: UUID) {
        guard var surface = surfaces.first(where: { $0.id == surfaceID }),
              !isMappingLocked, !surface.isLocked, let existingWarp = surface.meshWarp?.sanitized(),
              existingWarp.controlOffsets.indices.contains(pointIndex) else { return }
        let divisions = existingWarp.subdivisionCount
        let interior = divisions - 1
        let row = pointIndex / interior + 1
        let column = pointIndex % interior + 1
        let sourcePoint = NormalizedPoint(Double(column) / Double(divisions), Double(row) / Double(divisions))
        guard let base = ProjectiveTransform.sourceToOutput(sourcePoint, corners: surface.corners) else { return }
        var warp = existingWarp
        let boundedPoint = point.clamped()
        warp.controlOffsets[pointIndex] = NormalizedPoint(boundedPoint.x - base.x, boundedPoint.y - base.y)
        surface.meshWarp = warp.sanitized()
        guard surface.hasUsableGeometry else { return }
        recordGeometryChange()
        updateSurface(surface)
    }

    func resetMeshWarp(on surfaceID: UUID) {
        guard var surface = surfaces.first(where: { $0.id == surfaceID }),
              !isMappingLocked, !surface.isLocked, surface.meshWarp != nil,
              surface.meshWarp?.controlOffsets.contains(where: { abs($0.x) > 0.000001 || abs($0.y) > 0.000001 }) == true else { return }
        recordGeometryChange()
        surface.meshWarp = MeshWarp()
        updateSurface(surface)
    }

    func beginGeometryEdit() {
        guard geometryEditSnapshot == nil else { return }
        geometryEditSnapshot = geometrySnapshot()
    }

    func endGeometryEdit() {
        guard let startingSnapshot = geometryEditSnapshot else { return }
        geometryEditSnapshot = nil
        guard startingSnapshot != geometrySnapshot() else { return }
        geometryUndoHistory.append(startingSnapshot)
        trimGeometryHistory()
        geometryRedoHistory.removeAll()
        updateGeometryHistoryAvailability()
    }

    func translateSurface(_ surfaceID: UUID, dx: Double, dy: Double) {
        guard var surface = surfaces.first(where: { $0.id == surfaceID }), !isMappingLocked, !surface.isLocked,
              dx.isFinite, dy.isFinite else { return }
        let boundaryPoints = surface.meshGridPoints ?? surface.corners
        let minimumX = boundaryPoints.map(\.x).min() ?? 0
        let maximumX = boundaryPoints.map(\.x).max() ?? 1
        let minimumY = boundaryPoints.map(\.y).min() ?? 0
        let maximumY = boundaryPoints.map(\.y).max() ?? 1
        let boundedDX = min(max(dx, -minimumX), 1 - maximumX)
        let boundedDY = min(max(dy, -minimumY), 1 - maximumY)
        guard abs(boundedDX) > 0.0000001 || abs(boundedDY) > 0.0000001 else { return }
        recordGeometryChange()
        surface.corners = surface.corners.map { NormalizedPoint($0.x + boundedDX, $0.y + boundedDY) }
        updateSurface(surface)
    }

    func scaleSurface(_ surfaceID: UUID, scaleX: Double, scaleY: Double) {
        guard let surface = surfaces.first(where: { $0.id == surfaceID }), !isMappingLocked, !surface.isLocked,
              scaleX.isFinite, scaleY.isFinite, scaleX > 0, scaleY > 0 else { return }
        let center = geometryCenter(surface.corners)
        let transformed = surface.corners.map {
            NormalizedPoint(center.x + ($0.x - center.x) * scaleX, center.y + ($0.y - center.y) * scaleY)
        }
        applyTransformedCorners(transformed, to: surface)
    }

    func rotateSurface(_ surfaceID: UUID, degrees: Double) {
        guard let surface = surfaces.first(where: { $0.id == surfaceID }), !isMappingLocked, !surface.isLocked,
              degrees.isFinite, abs(degrees) > 0.0001 else { return }
        let center = geometryCenter(surface.corners)
        let radians = degrees * .pi / 180
        let cosine = cos(radians)
        let sine = sin(radians)
        let transformed = surface.corners.map { point -> NormalizedPoint in
            let x = point.x - center.x
            let y = point.y - center.y
            return NormalizedPoint(center.x + x * cosine - y * sine, center.y + x * sine + y * cosine)
        }
        applyTransformedCorners(transformed, to: surface)
    }

    func resetCorner(_ cornerIndex: Int, on surfaceID: UUID) {
        guard surfaces.contains(where: { $0.id == surfaceID }),
              ProjectionSurface.rectanglePoints.indices.contains(cornerIndex) else { return }
        updateCorner(cornerIndex, to: ProjectionSurface.rectanglePoints[cornerIndex], on: surfaceID)
    }

    func resetGeometry(on surfaceID: UUID) {
        guard var surface = surfaces.first(where: { $0.id == surfaceID }),
              !isMappingLocked, !surface.isLocked else { return }
        let meshNeedsReset = surface.meshWarp != nil && surface.meshWarp?.sanitized() != MeshWarp()
        guard surface.corners != ProjectionSurface.rectanglePoints || meshNeedsReset else { return }
        recordGeometryChange()
        surface.corners = ProjectionSurface.rectanglePoints
        if surface.meshWarp != nil { surface.meshWarp = MeshWarp() }
        updateSurface(surface)
    }

    func undoGeometry() {
        guard geometryEditSnapshot == nil, let previous = geometryUndoHistory.popLast() else { return }
        geometryRedoHistory.append(geometrySnapshot())
        restoreGeometry(previous)
        updateGeometryHistoryAvailability()
    }

    func redoGeometry() {
        guard geometryEditSnapshot == nil, let next = geometryRedoHistory.popLast() else { return }
        geometryUndoHistory.append(geometrySnapshot())
        restoreGeometry(next)
        updateGeometryHistoryAvailability()
    }

    func updateMaskPoint(_ pointIndex: Int, to point: NormalizedPoint, on surfaceID: UUID) {
        guard var surface = surfaces.first(where: { $0.id == surfaceID }),
              !isMappingLocked, !surface.isLocked, surface.maskPoints.indices.contains(pointIndex) else { return }
        let updatedPoint = point.clamped()
        guard surface.maskPoints[pointIndex] != updatedPoint else { return }
        recordGeometryChange()
        surface.maskPoints[pointIndex] = updatedPoint
        updateSurface(surface)
    }

    func addMaskPath(
        name: String,
        operation: ProjectionMaskOperation,
        points: [NormalizedPoint],
        on surfaceID: UUID
    ) -> UUID? {
        guard var surface = surfaces.first(where: { $0.id == surfaceID }), !isMappingLocked, !surface.isLocked,
              points.count >= 3, points.count <= 32,
              (surface.additionalMaskPaths ?? []).count < 7 else { return nil }
        let path = ProjectionMaskPath(name: name, operation: operation, points: points)
        recordGeometryChange()
        surface.additionalMaskPaths = (surface.additionalMaskPaths ?? []) + [path]
        surface.maskKind = .polygon
        updateSurface(surface)
        return path.id
    }

    func removeMaskPath(_ pathID: UUID, on surfaceID: UUID) {
        guard var surface = surfaces.first(where: { $0.id == surfaceID }), !isMappingLocked, !surface.isLocked,
              let paths = surface.additionalMaskPaths,
              paths.contains(where: { $0.id == pathID }) else { return }
        recordGeometryChange()
        surface.additionalMaskPaths = paths.filter { $0.id != pathID }
        if surface.additionalMaskPaths?.isEmpty == true { surface.additionalMaskPaths = nil }
        updateSurface(surface)
    }

    func setMaskPathOperation(_ pathID: UUID, operation: ProjectionMaskOperation, on surfaceID: UUID) {
        guard var surface = surfaces.first(where: { $0.id == surfaceID }), !isMappingLocked, !surface.isLocked,
              var paths = surface.additionalMaskPaths,
              let pathIndex = paths.firstIndex(where: { $0.id == pathID }),
              paths[pathIndex].operation != operation else { return }
        recordGeometryChange()
        paths[pathIndex].operation = operation
        surface.additionalMaskPaths = paths
        updateSurface(surface)
    }

    func updateMaskPathPoint(_ pathID: UUID, pointIndex: Int, to point: NormalizedPoint, on surfaceID: UUID) {
        guard var surface = surfaces.first(where: { $0.id == surfaceID }), !isMappingLocked, !surface.isLocked,
              var paths = surface.additionalMaskPaths,
              let pathIndex = paths.firstIndex(where: { $0.id == pathID }),
              paths[pathIndex].points.indices.contains(pointIndex) else { return }
        let boundedPoint = point.clamped()
        guard paths[pathIndex].points[pointIndex] != boundedPoint else { return }
        recordGeometryChange()
        paths[pathIndex].points[pointIndex] = boundedPoint
        surface.additionalMaskPaths = paths
        updateSurface(surface)
    }

    func insertMaskPathPoint(after edgeIndex: Int, pathID: UUID, on surfaceID: UUID) {
        guard var surface = surfaces.first(where: { $0.id == surfaceID }), !isMappingLocked, !surface.isLocked,
              var paths = surface.additionalMaskPaths,
              let pathIndex = paths.firstIndex(where: { $0.id == pathID }),
              paths[pathIndex].points.count < 32,
              paths[pathIndex].points.indices.contains(edgeIndex) else { return }
        let points = paths[pathIndex].points
        let nextIndex = (edgeIndex + 1) % points.count
        let start = points[edgeIndex]
        let end = points[nextIndex]
        recordGeometryChange()
        paths[pathIndex].points.insert(NormalizedPoint((start.x + end.x) * 0.5, (start.y + end.y) * 0.5), at: edgeIndex + 1)
        surface.additionalMaskPaths = paths
        updateSurface(surface)
    }

    func removeMaskPathPoint(at pointIndex: Int, pathID: UUID, on surfaceID: UUID) {
        guard var surface = surfaces.first(where: { $0.id == surfaceID }), !isMappingLocked, !surface.isLocked,
              var paths = surface.additionalMaskPaths,
              let pathIndex = paths.firstIndex(where: { $0.id == pathID }),
              paths[pathIndex].points.count > 3,
              paths[pathIndex].points.indices.contains(pointIndex) else { return }
        recordGeometryChange()
        paths[pathIndex].points.remove(at: pointIndex)
        surface.additionalMaskPaths = paths
        updateSurface(surface)
    }

    func addMaskPoint(on surfaceID: UUID) {
        insertMaskPoint(after: 0, on: surfaceID)
    }

    func insertMaskPoint(after edgeIndex: Int, on surfaceID: UUID) {
        guard var surface = surfaces.first(where: { $0.id == surfaceID }), !isMappingLocked, !surface.isLocked,
              surface.maskPoints.count < 32, surface.maskPoints.indices.contains(edgeIndex) else { return }
        let nextIndex = (edgeIndex + 1) % surface.maskPoints.count
        let start = surface.maskPoints[edgeIndex]
        let end = surface.maskPoints[nextIndex]
        recordGeometryChange()
        surface.maskPoints.insert(NormalizedPoint((start.x + end.x) * 0.5, (start.y + end.y) * 0.5), at: edgeIndex + 1)
        surface.maskKind = .polygon
        updateSurface(surface)
    }

    func removeLastMaskPoint(on surfaceID: UUID) {
        guard let surface = surfaces.first(where: { $0.id == surfaceID }) else { return }
        removeMaskPoint(at: surface.maskPoints.count - 1, on: surfaceID)
    }

    func removeMaskPoint(at pointIndex: Int, on surfaceID: UUID) {
        guard var surface = surfaces.first(where: { $0.id == surfaceID }), !isMappingLocked, !surface.isLocked,
              surface.maskPoints.count > 3, surface.maskPoints.indices.contains(pointIndex) else { return }
        recordGeometryChange()
        surface.maskPoints.remove(at: pointIndex)
        surface.maskKind = .polygon
        updateSurface(surface)
    }

    func setCalibrationPattern(_ pattern: CalibrationPattern) {
        commit(layers: layers, surfaces: surfaces, calibration: pattern)
    }

    func setSurfaceSource(_ sourcePath: String?, usesLayerStack: Bool, on surfaceID: UUID) {
        guard var surface = surfaces.first(where: { $0.id == surfaceID }) else { return }
        surface.sourcePath = sourcePath
        surface.usesLayerStack = usesLayerStack
        updateSurface(surface)
    }

    func updateSourceReference(from oldReference: String, to newReference: String) {
        guard oldReference != newReference else { return }
        var updatedSurfaces = surfaces
        var foundReference = false
        for index in updatedSurfaces.indices where updatedSurfaces[index].sourcePath == oldReference {
            updatedSurfaces[index].sourcePath = newReference
            foundReference = true
        }

        let updatedScenes = scenes.map { scene -> ScenePreset in
            var updated = scene
            updated.layers = scene.layers.map { layer in
                var layerState = layer
                if layerState.sourcePath == oldReference {
                    layerState.sourcePath = newReference
                    foundReference = true
                }
                return layerState
            }
            updated.surfaces = scene.surfaces.map { surface in
                var surfaceState = surface
                if surfaceState.sourcePath == oldReference {
                    surfaceState.sourcePath = newReference
                    foundReference = true
                }
                return surfaceState
            }
            return updated
        }
        guard foundReference else { return }
        commit(layers: layers, surfaces: updatedSurfaces)
        scenes = updatedScenes
    }

    func setColorCorrection(_ correction: SurfaceColorCorrection, on surfaceID: UUID) {
        guard var surface = surfaces.first(where: { $0.id == surfaceID }) else { return }
        surface.colorCorrection = correction.sanitized()
        updateSurface(surface)
    }

    func resetColorCorrection(on surfaceID: UUID) {
        guard var surface = surfaces.first(where: { $0.id == surfaceID }) else { return }
        surface.colorCorrection = nil
        updateSurface(surface)
    }

    func setEffectStack(_ effects: [SurfaceEffect], on surfaceID: UUID) {
        guard var surface = surfaces.first(where: { $0.id == surfaceID }) else { return }
        let sanitized = effects.prefix(SurfaceEffect.maximumStackSize).map { $0.sanitized() }
        surface.effectStack = sanitized.isEmpty ? nil : sanitized
        updateSurface(surface)
    }

    func resetEffectStack(on surfaceID: UUID) {
        guard var surface = surfaces.first(where: { $0.id == surfaceID }) else { return }
        surface.effectStack = nil
        updateSurface(surface)
    }

    func replaceMapping(with document: MappingDocument) {
        clearGeometryHistory()
        setOutputs(document.outputs ?? [.main])
        let validSurfaces = sanitizedSurfaces(document.surfaces)
        commit(layers: layers, surfaces: validSurfaces.isEmpty ? [.main] : validSurfaces)
    }

    func captureScene(named name: String) -> ScenePreset {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let catalogByPath = Dictionary(snapshot().sourceCatalog.map { ($0.reference, $0) }, uniquingKeysWith: { first, _ in first })
        let surfaceStates = surfaces.map { surface -> SceneSurfaceState in
            guard let path = surface.sourcePath, let source = catalogByPath[path] else {
                return SceneSurfaceState(surface: surface)
            }
            return SceneSurfaceState(
                surface: surface,
                audioMuted: source.isAudioMuted,
                audioVolume: source.audioVolume,
                audioDelayMilliseconds: source.kind == .ndi ? source.audioDelayMilliseconds : nil
            )
        }
        let scene = ScenePreset(
            name: trimmedName.isEmpty ? "Scene \(scenes.count + 1)" : trimmedName,
            layers: layers.map { layer in
                var state = layer.savedState
                state.isSolo = nil
                state.isLocked = nil
                return state
            },
            surfaces: surfaceStates,
            isBlackout: isBlackout
        )
        scenes.append(scene)
        currentSceneID = scene.id
        return scene
    }

    func removeScene(_ sceneID: UUID) {
        scenes.removeAll { $0.id == sceneID }
        if currentSceneID == sceneID { currentSceneID = nil }
    }

    func moveScene(_ sceneID: UUID, by offset: Int) {
        guard offset != 0, let sourceIndex = scenes.firstIndex(where: { $0.id == sceneID }) else { return }
        let destinationIndex = sourceIndex + offset
        guard scenes.indices.contains(destinationIndex) else { return }
        var updated = scenes
        let scene = updated.remove(at: sourceIndex)
        updated.insert(scene, at: destinationIndex)
        scenes = updated
    }

    func setSceneOperatorNotes(_ notes: String, for sceneID: UUID) {
        guard let index = scenes.firstIndex(where: { $0.id == sceneID }) else { return }
        scenes[index].operatorNotes = String(notes.prefix(2000))
    }

    func setSceneAutoAdvance(_ seconds: TimeInterval?, for sceneID: UUID) {
        guard let index = scenes.firstIndex(where: { $0.id == sceneID }) else { return }
        scenes[index].autoAdvanceAfter = seconds.map { min(max($0.isFinite ? $0 : 0, 0), 3600) }
    }

    func renameScene(_ sceneID: UUID, to name: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, let index = scenes.firstIndex(where: { $0.id == sceneID }) else { return }
        scenes[index].name = trimmedName
    }

    func stepCue(_ direction: Int, sources: [MediaSource]) {
        guard !scenes.isEmpty, direction != 0 else { return }
        let currentIndex = scenes.firstIndex(where: { $0.id == currentSceneID }) ?? (direction > 0 ? -1 : 0)
        let nextIndex = (currentIndex + direction + scenes.count) % scenes.count
        recallScene(scenes[nextIndex], sources: sources)
    }

    func recallScene(_ scene: ScenePreset, sources: [MediaSource], transitionDuration: TimeInterval = 0.35) {
        setSourceCatalog(sources)
        let previousLayers = layers
        let currentLockStateByID = Dictionary(layers.map { ($0.id, $0.isLocked) }, uniquingKeysWith: { _, latest in latest })
        let sourcesByPath = Dictionary(sources.map { ($0.reference, $0) }, uniquingKeysWith: { first, _ in first })
        let restoredLayers = scene.layers.compactMap { saved -> RenderLayer? in
            guard let source = sourcesByPath[saved.sourcePath] else { return nil }
            return RenderLayer(
                id: saved.id,
                source: source,
                name: saved.layerName,
                isEnabled: saved.isEnabled,
                isSolo: false,
                isLocked: currentLockStateByID[saved.id] ?? false,
                opacity: saved.opacity,
                contentTransform: saved.contentTransform,
                effectStack: saved.effectStack
            )
        }
        var restoredSurfaces = surfaces
        for state in scene.surfaces {
            guard let index = restoredSurfaces.firstIndex(where: { $0.id == state.surfaceID }) else { continue }
            restoredSurfaces[index].sourcePath = state.sourcePath
            restoredSurfaces[index].usesLayerStack = state.usesLayerStack
            restoredSurfaces[index].isVisible = state.isVisible
            restoredSurfaces[index].isBlackout = state.isBlackout
            restoredSurfaces[index].isMaskInverted = state.isMaskInverted
            restoredSurfaces[index].brightness = min(max(state.brightness, 0), 1)
            restoredSurfaces[index].opacity = min(max(state.opacity, 0), 1)
            restoredSurfaces[index].colorCorrection = state.colorCorrection?.sanitized()
            restoredSurfaces[index].effectStack = state.effectStack?
                .prefix(SurfaceEffect.maximumStackSize)
                .map { $0.sanitized() }
        }
        currentSceneID = scene.id

        let targetAudioByPath = Dictionary(
            scene.layers.map { ($0.sourcePath, $0) }
                + scene.surfaces.compactMap { state -> (String, SavedLayerState)? in
                    guard let path = state.sourcePath,
                          state.audioMuted != nil || state.audioVolume != nil || state.audioDelayMilliseconds != nil else { return nil }
                    return (path, SavedLayerState(
                        sourcePath: path,
                        isAudioMuted: state.audioMuted,
                        audioVolume: state.audioVolume,
                        audioDelayMilliseconds: state.audioDelayMilliseconds
                    ))
                },
            uniquingKeysWith: { first, _ in first }
        )
        let previousSurfaceAudioPaths = Set(surfaces.compactMap { surface -> String? in
            guard let path = surface.sourcePath,
                  sourcesByPath[path]?.kind == .ndi || sourcesByPath[path]?.kind == .video else { return nil }
            return path
        })
        let targetSurfaceAudioPaths = Set(scene.surfaces.compactMap { state -> String? in
            guard state.audioMuted != nil || state.audioVolume != nil || state.audioDelayMilliseconds != nil else { return nil }
            return state.sourcePath
        })
        let previousAudioPaths = Set(previousLayers.map { $0.source.reference }).union(previousSurfaceAudioPaths)
        let audioTracks = sources.compactMap { source -> (
            source: MediaSource,
            start: Double,
            end: Double,
            targetMuted: Bool,
            targetVolume: Double
        )? in
            let target = targetAudioByPath[source.reference]
            guard target != nil || previousAudioPaths.contains(source.reference) || targetSurfaceAudioPaths.contains(source.reference) else { return nil }
            let targetMuted = target?.isAudioMuted ?? true
            let targetVolumeValue = target?.audioVolume ?? source.audioVolume
            let targetVolume = min(max(targetVolumeValue.isFinite ? targetVolumeValue : 1, 0), 1)
            let start = source.isAudioMuted ? 0 : source.audioVolume
            return (
                source,
                start,
                targetMuted ? 0 : targetVolume,
                targetMuted,
                targetVolume
            )
        }

        let transitionID = UUID()
        sceneTransitionID = transitionID
        let targetBlackout = scene.isBlackout ?? isBlackout
        let shouldFade = transitionDuration > 0 && (!layers.isEmpty || !restoredLayers.isEmpty || !audioTracks.isEmpty)
        if shouldFade {
            for track in audioTracks {
                track.source.restoreAudio(isMuted: false, volume: track.start)
            }
        } else {
            for track in audioTracks {
                track.source.restoreAudio(isMuted: track.targetMuted, volume: track.targetVolume)
            }
        }
        for saved in scene.layers {
            guard let source = sourcesByPath[saved.sourcePath] else { continue }
            source.restorePlayback(isPlaying: saved.isPlaying, at: saved.playbackTime)
            if let delay = saved.audioDelayMilliseconds { source.setAudioDelayMilliseconds(delay) }
        }
        for state in scene.surfaces {
            guard let path = state.sourcePath, let source = sourcesByPath[path] else { continue }
            if let delay = state.audioDelayMilliseconds { source.setAudioDelayMilliseconds(delay) }
        }
        guard shouldFade else {
            commit(layers: restoredLayers, surfaces: restoredSurfaces, blackout: targetBlackout)
            return
        }

        let previousHasSoloLayers = layers.contains { $0.isEnabled && $0.isSolo }
        let targetHasSoloLayers = restoredLayers.contains { $0.isEnabled && $0.isSolo }
        let previousVisibleLayerIDs = Set(layers.compactMap { layer -> UUID? in
            guard layer.isEnabled, !previousHasSoloLayers || layer.isSolo else { return nil }
            return layer.id
        })
        let targetVisibleLayerIDs = Set(restoredLayers.compactMap { layer -> UUID? in
            guard layer.isEnabled, !targetHasSoloLayers || layer.isSolo else { return nil }
            return layer.id
        })
        let transitionSoloLayerIDs = previousVisibleLayerIDs.union(targetVisibleLayerIDs)
        let transitionUsesSolo = previousHasSoloLayers || targetHasSoloLayers
        var targetByID = Dictionary(uniqueKeysWithValues: restoredLayers.map { ($0.id, $0) })
        var tracks: [(layer: RenderLayer, start: Double, end: Double, transitionEnabled: Bool)] = []
        var matchedTargetIDs = Set<UUID>()
        for oldLayer in layers {
            if let target = targetByID.removeValue(forKey: oldLayer.id),
               target.source.reference == oldLayer.source.reference {
                matchedTargetIDs.insert(target.id)
                tracks.append((
                    target,
                    oldLayer.isEnabled ? oldLayer.opacity : 0,
                    target.isEnabled ? target.opacity : 0,
                    oldLayer.isEnabled || target.isEnabled
                ))
            } else {
                var fadingLayer = oldLayer
                fadingLayer.isEnabled = oldLayer.isEnabled
                tracks.append((fadingLayer, oldLayer.opacity, 0, oldLayer.isEnabled))
            }
        }
        for target in restoredLayers where !matchedTargetIDs.contains(target.id) {
            var appearingLayer = target
            appearingLayer.opacity = 0
            appearingLayer.isEnabled = true
            tracks.append((appearingLayer, 0, target.isEnabled ? target.opacity : 0, target.isEnabled))
        }

        let frameCount = 18
        for frame in 0...frameCount {
            let progress = Double(frame) / Double(frameCount)
            DispatchQueue.main.asyncAfter(deadline: .now() + transitionDuration * progress) { [weak self] in
                guard let self, self.sceneTransitionID == transitionID else { return }
                if frame == frameCount {
                    for track in audioTracks {
                        track.source.restoreAudio(isMuted: track.targetMuted, volume: track.targetVolume)
                    }
                    self.commit(layers: restoredLayers, surfaces: restoredSurfaces, blackout: targetBlackout)
                    let activePaths = Set(restoredLayers.map { $0.source.reference })
                    for layer in previousLayers where !activePaths.contains(layer.source.reference) {
                        layer.source.restorePlayback(isPlaying: false, at: layer.source.player?.currentTime().seconds ?? 0)
                    }
                    return
                }
                for track in audioTracks {
                    let volume = track.start + (track.end - track.start) * progress
                    track.source.setAudioVolume(volume)
                }
                let transitioningLayers = tracks.map { track -> RenderLayer in
                    var layer = track.layer
                    layer.opacity = track.start + (track.end - track.start) * progress
                    layer.isEnabled = track.transitionEnabled
                    layer.isSolo = transitionUsesSolo && transitionSoloLayerIDs.contains(layer.id)
                    return layer
                }
                self.commit(layers: transitioningLayers, surfaces: restoredSurfaces)
            }
        }
    }

    func copyContent(from other: RenderSession) {
        stopStagedPreviewSources()
        let snapshot = other.snapshot()
        setSourceCatalog(snapshot.sourceCatalog)
        let copiedLayers = snapshot.layers.map {
            RenderLayer(
                id: $0.id,
                source: $0.source,
                name: $0.name,
                isEnabled: $0.isEnabled,
                isSolo: $0.isSolo,
                isLocked: $0.isLocked,
                opacity: $0.opacity,
                contentTransform: $0.contentTransform,
                effectStack: $0.effectStack
            )
        }
        commit(
            layers: copiedLayers,
            surfaces: snapshot.surfaces,
            blackout: snapshot.isBlackout,
            calibration: snapshot.calibrationPattern
        )
        setOutputs(other.outputs)
        scenes = other.scenes
        currentSceneID = other.currentSceneID
    }

    func stageScene(_ scene: ScenePreset, sources: [MediaSource]) {
        stopStagedPreviewSources()
        let savedLayerByPath = Dictionary(scene.layers.map { ($0.sourcePath, $0) }, uniquingKeysWith: { first, _ in first })
        let referencedPaths = Set(scene.layers.map(\.sourcePath) + scene.surfaces.compactMap(\.sourcePath))
        let stagedSourceEntries = sources.map { source -> (String, MediaSource) in
            guard referencedPaths.contains(source.reference) else { return (source.reference, source) }
            let savedLayer = savedLayerByPath[source.reference]
            let isPlaying = savedLayer?.isPlaying ?? source.isPlaying
            let playbackTime = savedLayer?.playbackTime ?? source.player?.currentTime().seconds ?? 0
            guard let stagedSource = source.makeSilentPreviewCopy(isPlaying: isPlaying, at: playbackTime) else {
                return (source.reference, source)
            }
            stagedPreviewSources.append(stagedSource)
            return (source.reference, stagedSource)
        }
        let sourcesByPath = Dictionary(stagedSourceEntries, uniquingKeysWith: { first, _ in first })
        setSourceCatalog(Array(sourcesByPath.values))
        let stagedLayers = scene.layers.compactMap { saved -> RenderLayer? in
            guard let source = sourcesByPath[saved.sourcePath] else { return nil }
            return RenderLayer(
                id: saved.id,
                source: source,
                name: saved.layerName,
                isEnabled: saved.isEnabled,
                isSolo: false,
                isLocked: false,
                opacity: saved.opacity,
                contentTransform: saved.contentTransform,
                effectStack: saved.effectStack
            )
        }
        var stagedSurfaces = surfaces
        for state in scene.surfaces {
            guard let index = stagedSurfaces.firstIndex(where: { $0.id == state.surfaceID }) else { continue }
            stagedSurfaces[index].sourcePath = state.sourcePath
            stagedSurfaces[index].usesLayerStack = state.usesLayerStack
            stagedSurfaces[index].isVisible = state.isVisible
            stagedSurfaces[index].isBlackout = state.isBlackout
            stagedSurfaces[index].isMaskInverted = state.isMaskInverted
            stagedSurfaces[index].brightness = min(max(state.brightness, 0), 1)
            stagedSurfaces[index].opacity = min(max(state.opacity, 0), 1)
            stagedSurfaces[index].colorCorrection = state.colorCorrection?.sanitized()
            stagedSurfaces[index].effectStack = state.effectStack?
                .prefix(SurfaceEffect.maximumStackSize)
                .map { $0.sanitized() }
        }
        commit(layers: stagedLayers, surfaces: stagedSurfaces)
    }

    private func stopStagedPreviewSources() {
        stagedPreviewSources.forEach { $0.stop() }
        stagedPreviewSources.removeAll()
    }

    func replaceShow(with document: ShowDocument, sources: [MediaSource]) {
        setSourceCatalog(sources)
        clearGeometryHistory()
        setOutputs(document.outputs ?? [.main])
        let validSurfaces = sanitizedSurfaces(document.surfaces)
        let sourcesByPath = Dictionary(sources.map { ($0.reference, $0) }, uniquingKeysWith: { first, _ in first })
        let restoredLayers = document.layers.compactMap { saved -> RenderLayer? in
            guard let source = sourcesByPath[saved.sourcePath] else { return nil }
            source.restoreAudio(isMuted: saved.isAudioMuted ?? true, volume: saved.audioVolume ?? 1)
            if let delay = saved.audioDelayMilliseconds { source.setAudioDelayMilliseconds(delay) }
            source.restorePlayback(isPlaying: saved.isPlaying, at: saved.playbackTime)
            return RenderLayer(
                id: saved.id,
                source: source,
                name: saved.layerName,
                isEnabled: saved.isEnabled,
                isSolo: saved.isSolo ?? false,
                isLocked: saved.isLocked ?? false,
                opacity: saved.opacity,
                contentTransform: saved.contentTransform,
                effectStack: saved.effectStack
            )
        }
        for saved in document.sourceAudio ?? [] {
            guard let source = sourcesByPath[saved.sourcePath] else { continue }
            source.restoreAudio(isMuted: saved.audioMuted, volume: saved.audioVolume)
            source.setAudioDelayMilliseconds(saved.audioDelayMilliseconds)
        }
        commit(layers: restoredLayers, surfaces: validSurfaces.isEmpty ? [.main] : validSurfaces)
        scenes = document.scenes
        currentSceneID = nil
    }

    func hasLayer(sourcePath: String) -> Bool {
        layers.contains { $0.source.reference == sourcePath }
    }

    private func sanitizedSurfaces(_ input: [ProjectionSurface]) -> [ProjectionSurface] {
        input.compactMap { original in
            var surface = original
            guard surface.corners.count == 4, (3...32).contains(surface.maskPoints.count) else { return nil }
            if let outputID = surface.outputID, !outputs.contains(where: { $0.id == outputID }) {
                surface.outputID = nil
            }
            surface.corners = surface.corners.map { $0.clamped() }
            surface.maskPoints = surface.maskPoints.map { $0.clamped() }
            let maskPaths = (surface.additionalMaskPaths ?? []).prefix(7).compactMap { path -> ProjectionMaskPath? in
                guard (3...32).contains(path.points.count) else { return nil }
                return ProjectionMaskPath(
                    id: path.id,
                    name: path.name.isEmpty ? "Mask Path" : path.name,
                    operation: path.operation,
                    points: path.points
                )
            }
            surface.additionalMaskPaths = maskPaths.isEmpty ? nil : maskPaths
            surface.contentTransform = surface.contentTransform?.sanitized()
            surface.maskFeather = min(max(surface.maskFeather ?? 0, 0), 0.05)
            surface.meshWarp = surface.meshWarp?.sanitized()
            guard surface.hasUsableGeometry else { return nil }
            surface.brightness = min(max(surface.brightness, 0), 1)
            surface.opacity = min(max(surface.opacity, 0), 1)
            surface.colorCorrection = surface.colorCorrection?.sanitized()
            surface.effectStack = surface.effectStack?
                .prefix(SurfaceEffect.maximumStackSize)
                .map { $0.sanitized() }
            return surface
        }
    }

    func snapshot() -> RenderSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return RenderSnapshot(
            layers: renderLayers,
            sourceCatalog: renderSourceCatalog,
            surfaces: renderSurfaces,
            outputs: renderOutputs,
            isBlackout: renderBlackout,
            outputIntensity: renderOutputIntensity,
            calibrationPattern: renderCalibrationPattern
        )
    }

    private func applyTransformedCorners(_ corners: [NormalizedPoint], to original: ProjectionSurface) {
        guard var surface = surfaces.first(where: { $0.id == original.id }) else { return }
        let fittedCorners = fitCornersToCanvas(corners)
        guard ProjectiveTransform.isConvexQuad(fittedCorners), surface.corners != fittedCorners else { return }
        surface.corners = fittedCorners
        if let oldGrid = original.meshGridPoints, let existingWarp = original.meshWarp?.sanitized() {
            var meshWarp = existingWarp
            let divisions = meshWarp.subdivisionCount
            let side = divisions + 1
            let interior = divisions - 1
            for index in meshWarp.controlOffsets.indices {
                let row = index / interior + 1
                let column = index % interior + 1
                let sourcePoint = NormalizedPoint(Double(column) / Double(divisions), Double(row) / Double(divisions))
                let gridIndex = row * side + column
                guard let newBase = ProjectiveTransform.sourceToOutput(sourcePoint, corners: fittedCorners),
                      oldGrid.indices.contains(gridIndex),
                      let oldWarpedSource = ProjectiveTransform.outputToSource(oldGrid[gridIndex], corners: original.corners),
                      let newWarped = ProjectiveTransform.sourceToOutput(oldWarpedSource, corners: fittedCorners) else { return }
                meshWarp.controlOffsets[index] = NormalizedPoint(newWarped.x - newBase.x, newWarped.y - newBase.y)
            }
            surface.meshWarp = meshWarp.sanitized()
        }
        guard surface.hasUsableGeometry else { return }
        recordGeometryChange()
        updateSurface(surface)
    }

    private func fitCornersToCanvas(_ corners: [NormalizedPoint]) -> [NormalizedPoint] {
        guard !corners.isEmpty else { return corners }
        let minX = corners.map(\.x).min() ?? 0
        let maxX = corners.map(\.x).max() ?? 1
        let minY = corners.map(\.y).min() ?? 0
        let maxY = corners.map(\.y).max() ?? 1
        let width = maxX - minX
        let height = maxY - minY
        let scale = min(1, 1 / max(width, 1), 1 / max(height, 1))
        let centerX = (minX + maxX) * 0.5
        let centerY = (minY + maxY) * 0.5
        let scaled = corners.map {
            NormalizedPoint(centerX + ($0.x - centerX) * scale, centerY + ($0.y - centerY) * scale)
        }
        let scaledMinX = scaled.map(\.x).min() ?? 0
        let scaledMaxX = scaled.map(\.x).max() ?? 1
        let scaledMinY = scaled.map(\.y).min() ?? 0
        let scaledMaxY = scaled.map(\.y).max() ?? 1
        let offsetX = scaledMinX < 0 ? -scaledMinX : (scaledMaxX > 1 ? 1 - scaledMaxX : 0)
        let offsetY = scaledMinY < 0 ? -scaledMinY : (scaledMaxY > 1 ? 1 - scaledMaxY : 0)
        return scaled.map { NormalizedPoint($0.x + offsetX, $0.y + offsetY) }
    }

    private func geometryCenter(_ points: [NormalizedPoint]) -> NormalizedPoint {
        guard !points.isEmpty else { return NormalizedPoint(0.5, 0.5) }
        return NormalizedPoint(
            points.reduce(0) { $0 + $1.x } / Double(points.count),
            points.reduce(0) { $0 + $1.y } / Double(points.count)
        )
    }

    private func geometrySnapshot() -> [SurfaceGeometrySnapshot] {
        surfaces.map { SurfaceGeometrySnapshot($0, outputs: outputs) }
    }

    private func recordGeometryChange() {
        guard geometryEditSnapshot == nil else { return }
        geometryUndoHistory.append(geometrySnapshot())
        trimGeometryHistory()
        geometryRedoHistory.removeAll()
        updateGeometryHistoryAvailability()
    }

    private func trimGeometryHistory() {
        let maximumHistoryCount = 100
        if geometryUndoHistory.count > maximumHistoryCount {
            geometryUndoHistory.removeFirst(geometryUndoHistory.count - maximumHistoryCount)
        }
    }

    private func restoreGeometry(_ snapshot: [SurfaceGeometrySnapshot]) {
        let geometryByID = Dictionary(uniqueKeysWithValues: snapshot.map { ($0.id, $0) })
        if let savedOutputs = snapshot.first?.outputs {
            setOutputs(savedOutputs)
        }
        let restoredSurfaces = surfaces.map { current -> ProjectionSurface in
            guard let geometry = geometryByID[current.id] else { return current }
            var restored = current
            restored.corners = geometry.corners
            restored.maskPoints = geometry.maskPoints
            restored.additionalMaskPaths = geometry.additionalMaskPaths.isEmpty ? nil : geometry.additionalMaskPaths
            restored.meshWarp = geometry.meshWarp
            restored.contentTransform = geometry.contentTransform
            return restored
        }
        commit(layers: layers, surfaces: restoredSurfaces)
    }

    private func updateGeometryHistoryAvailability() {
        canUndoGeometry = !geometryUndoHistory.isEmpty
        canRedoGeometry = !geometryRedoHistory.isEmpty
    }

    private func clearGeometryHistory() {
        geometryUndoHistory.removeAll()
        geometryRedoHistory.removeAll()
        geometryEditSnapshot = nil
        updateGeometryHistoryAvailability()
    }

    private func commit(
        layers: [RenderLayer],
        surfaces: [ProjectionSurface],
        blackout: Bool? = nil,
        calibration: CalibrationPattern? = nil
    ) {
        lock.lock()
        renderLayers = layers
        renderSurfaces = surfaces
        if let blackout { renderBlackout = blackout }
        if let calibration { renderCalibrationPattern = calibration }
        let currentBlackout = renderBlackout
        let currentCalibration = renderCalibrationPattern
        lock.unlock()

        self.layers = layers
        self.surfaces = surfaces
        isBlackout = currentBlackout
        calibrationPattern = currentCalibration
    }
}
