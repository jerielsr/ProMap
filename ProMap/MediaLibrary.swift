import AVFoundation
import Combine
import CoreGraphics
import Foundation
import ImageIO

enum MediaImportError: LocalizedError {
    case unsupportedFile(URL)
    case unreadableImage(URL)

    var errorDescription: String? {
        switch self {
        case .unsupportedFile(let url):
            return "\(url.lastPathComponent) is not a supported image or video file."
        case .unreadableImage(let url):
            return "ProMap could not decode \(url.lastPathComponent)."
        }
    }
}

final class MediaSource: ObservableObject, Identifiable {
    enum Kind {
        case image
        case video
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

    @Published private(set) var isPlaying = false

    var title: String { url.deletingPathExtension().lastPathComponent }
    var fileExtension: String { url.pathExtension.uppercased() }

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
        } else if Self.videoExtensions.contains(fileExtension) {
            let item = AVPlayerItem(url: url)
            let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ])
            item.add(output)

            kind = .video
            image = nil
            player = AVPlayer(playerItem: item)
            videoOutput = output
        } else {
            throw MediaImportError.unsupportedFile(url)
        }
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
}

final class MediaLibrary: ObservableObject {
    @Published private(set) var sources: [MediaSource] = []
    @Published private(set) var importMessage: String?
    @Published private(set) var isImporting = false

    func importFiles(_ urls: [URL]) {
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
                self.sources.append(contentsOf: imported)
                if failures.isEmpty {
                    self.importMessage = "Imported \(imported.count) item\(imported.count == 1 ? "" : "s")."
                } else {
                    self.importMessage = failures.joined(separator: "\n")
                }
                self.isImporting = false
            }
        }
    }

    func remove(_ source: MediaSource) {
        sources.removeAll { $0.id == source.id }
    }
}

struct RenderLayer: Identifiable {
    let id: UUID
    let source: MediaSource
    var isEnabled: Bool
    var opacity: Double

    init(source: MediaSource) {
        id = UUID()
        self.source = source
        isEnabled = true
        opacity = 1
    }
}

struct RenderSnapshot {
    let layers: [RenderLayer]
    let isBlackout: Bool
}

final class RenderSession: ObservableObject {
    @Published private(set) var layers: [RenderLayer] = []
    @Published private(set) var isBlackout = false

    private let lock = NSLock()
    private var renderLayers: [RenderLayer] = []
    private var renderBlackout = false

    func addLayer(source: MediaSource) {
        var updated = layers
        updated.append(RenderLayer(source: source))
        commit(layers: updated)
    }

    func removeLayer(_ layer: RenderLayer) {
        commit(layers: layers.filter { $0.id != layer.id })
    }

    func setEnabled(_ enabled: Bool, for layerID: UUID) {
        var updated = layers
        guard let index = updated.firstIndex(where: { $0.id == layerID }) else { return }
        updated[index].isEnabled = enabled
        commit(layers: updated)
    }

    func setOpacity(_ opacity: Double, for layerID: UUID) {
        var updated = layers
        guard let index = updated.firstIndex(where: { $0.id == layerID }) else { return }
        updated[index].opacity = min(max(opacity, 0), 1)
        commit(layers: updated)
    }

    func toggleBlackout() {
        commit(layers: layers, blackout: !isBlackout)
    }

    func snapshot() -> RenderSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return RenderSnapshot(layers: renderLayers, isBlackout: renderBlackout)
    }

    private func commit(layers: [RenderLayer], blackout: Bool? = nil) {
        lock.lock()
        renderLayers = layers
        if let blackout { renderBlackout = blackout }
        let currentBlackout = renderBlackout
        lock.unlock()

        self.layers = layers
        isBlackout = currentBlackout
    }
}
