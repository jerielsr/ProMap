import Foundation

struct RecoverySessionMarker {
    private let fileURL: URL

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    @discardableResult
    func beginSession() -> Bool {
        let previousSessionWasUnclean = FileManager.default.fileExists(atPath: fileURL.path)
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let timestamp = Data(String(Date().timeIntervalSince1970).utf8)
            try timestamp.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("ProMap could not create its recovery session marker: %@", error.localizedDescription)
        }
        return previousSessionWasUnclean
    }

    func endSession() {
        do {
            if FileManager.default.fileExists(atPath: fileURL.path) {
                try FileManager.default.removeItem(at: fileURL)
            }
        } catch {
            NSLog("ProMap could not clear its recovery session marker: %@", error.localizedDescription)
        }
    }

    static func applicationSupportMarker() -> RecoverySessionMarker? {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else { return nil }
        let folder = applicationSupport.appendingPathComponent("ProMap", isDirectory: true)
        return RecoverySessionMarker(fileURL: folder.appendingPathComponent("SessionInProgress"))
    }
}
