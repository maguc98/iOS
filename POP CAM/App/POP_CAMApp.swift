import SwiftUI

@main
struct POP_CAMApp: App {
    var body: some Scene {
        WindowGroup {
            CameraScreen()
                .preferredColorScheme(.light)
        }
    }
}