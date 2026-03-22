import AVFAudio
import Foundation

enum AppAudioSessionConfigurator {
    static func configureForAppLaunch() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
            try session.setActive(true)
        } catch {
            print("Launch audio session setup failed: \(error.localizedDescription)")
        }
    }
}
