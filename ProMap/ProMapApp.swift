import SwiftUI

@main
struct ProMapApp: App {
    var body: some Scene {
        WindowGroup {
            MainWorkspaceView()
        }
        .windowStyle(.hiddenTitleBar)
    }
}
