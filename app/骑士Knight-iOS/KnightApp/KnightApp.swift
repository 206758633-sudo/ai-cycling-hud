import SwiftUI
import AVFoundation

@main
struct KnightApp: App {
    init() {
        configureAudioSession()
    }

    var body: some Scene {
        WindowGroup {
            KnightRootView()
                .preferredColorScheme(.light)
        }
    }

    private func configureAudioSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
    }
}

struct KnightRootView: View {
    var body: some View {
        KnightWebContainer()
            .ignoresSafeArea()
            .background(Color(red: 250.0 / 255.0, green: 246.0 / 255.0, blue: 240.0 / 255.0))
    }
}
