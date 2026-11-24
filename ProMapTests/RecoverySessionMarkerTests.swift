import Foundation
import XCTest
@testable import ProMap

final class RecoverySessionMarkerTests: XCTestCase {
    func testMarkerDetectsUncleanExitAndClearsAfterCleanExit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProMapRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let marker = RecoverySessionMarker(fileURL: directory.appendingPathComponent("SessionInProgress"))

        XCTAssertFalse(marker.beginSession(), "A first launch should not be treated as a crash recovery.")
        XCTAssertTrue(marker.beginSession(), "A marker left by an earlier process indicates an unclean exit.")

        marker.endSession()
        XCTAssertFalse(marker.beginSession(), "Removing the marker on clean shutdown should clear the unclean-exit state.")
        marker.endSession()
    }
}
