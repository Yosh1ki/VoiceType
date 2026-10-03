import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("VoiceType")
                        .font(.headline)
                    Text(appState.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: appState.phase == .recording ? "waveform.circle.fill" : "mic.circle.fill")
                    .font(.system(size: 28))
            }

            if appState.phase == .recording {
                Button("録音を止めて入力") {
                    appState.requestStopAndProcess()
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
            } else if appState.phase != .processing {
                Button("音声入力を開始") {
                    Task { await appState.startRecording() }
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
            }

            if appState.phase == .recording {
                Button("録音を中止") {
                    Task { await appState.cancelRecording() }
                }
            }
            if appState.phase == .processing {
                Button(appState.isCancelling ? "中止中…" : "処理を中止") {
                    appState.cancelProcessing()
                }
                .disabled(appState.isCancelling)
            }
            if !appState.lastOutput.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("直前の入力")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(appState.lastOutput)
                        .font(.caption)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Button("コピー") {
                        appState.copyLastOutput()
                    }
                    .font(.caption)
                }
                .padding(10)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            }

            Divider()

            if !appState.lastTimingSummary.isEmpty {
                Text(appState.lastTimingSummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Button {
                openWindow(id: "main")
                NSApplication.shared.activate(ignoringOtherApps: true)
            } label: {
                Label("履歴・メイン画面を開く", systemImage: "macwindow")
            }

            SettingsLink {
                Label("設定", systemImage: "gear")
            }

            Button {
                appState.requestAccessibilityPermission()
            } label: {
                Label("アクセシビリティ権限を許可", systemImage: "hand.raised")
            }

            if !appState.hotKeyAvailable {
                Text("ショートカットを使用できません。アクセシビリティ権限をご確認ください。")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            Divider()

            Button("VoiceTypeを終了") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}
