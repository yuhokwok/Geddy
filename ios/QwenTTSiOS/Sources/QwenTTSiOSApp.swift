import SwiftUI

@main
struct QwenTTSiOSApp: App {
    init() {
        AppAudioSessionConfigurator.configureForAppLaunch()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
