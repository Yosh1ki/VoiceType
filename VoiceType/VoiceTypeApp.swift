import SwiftUI

@main
struct VoiceTypeApp: App {
    @StateObject private var appState = AppState()

    init() {
        // Xcode can launch a second copy while a previously run menu-bar copy is
        // still alive. Both copies would otherwise handle the same shortcut.
        if let identifier = Bundle.main.bundleIdentifier {
            for application in NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            where application.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                application.terminate()
            }
        }
    }

    var body: some Scene {
        Window("VoiceType", id: "main") {
            MainView(appState: appState, history: appState.history)
        }
        .defaultSize(width: 1000, height: 720)

        MenuBarExtra {
            MenuBarView(appState: appState)
        } label: {
            Image(systemName: appState.phase == .recording ? "waveform.circle.fill" : "mic.circle")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(appState: appState)
                .frame(width: 620, height: 700)
        }
    }
}
