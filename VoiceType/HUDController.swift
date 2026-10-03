import AppKit
import SwiftUI

@MainActor
final class HUDController {
    enum Mode {
        case recording(RecordingShortcut)
        case processing
        case done(String)
        case error(String)
    }

    var onConfirm: () -> Void = {}
    var onCancel: () -> Void = {}

    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ mode: Mode) {
        hideTask?.cancel()

        let size = panelSize(for: mode)
        let view = HUDView(mode: mode, onConfirm: onConfirm, onCancel: onCancel, contentWidth: size.width - 12)
        if panel == nil {
            let newPanel = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 260, height: 44),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            newPanel.level = .floating
            newPanel.isOpaque = false
            newPanel.backgroundColor = .clear
            newPanel.hasShadow = true
            newPanel.ignoresMouseEvents = true
            newPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            newPanel.hidesOnDeactivate = false
            panel = newPanel
        }

        if case .recording = mode {
            panel?.ignoresMouseEvents = false
        } else {
            panel?.ignoresMouseEvents = true
        }
        panel?.setContentSize(size)
        panel?.contentView = NSHostingView(rootView: view)
        positionPanel()
        panel?.orderFrontRegardless()

        switch mode {
        case .done, .error:
            hideTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(2.4))
                guard !Task.isCancelled else { return }
                panel?.orderOut(nil)
            }
        case .recording, .processing:
            break
        }
    }

    private func panelSize(for mode: Mode) -> NSSize {
        let width: CGFloat
        switch mode {
        case .recording, .processing:
            width = 260
        case .done(let text), .error(let text):
            let font = NSFont.systemFont(ofSize: 13, weight: .medium)
            let textWidth = ceil((text as NSString).size(withAttributes: [.font: font]).width)
            width = min(max(260, textWidth + 72), 400)
        }
        return NSSize(width: width, height: 44)
    }

    private func positionPanel() {
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let x = visible.midX - panel.frame.width / 2
        let y = visible.minY + 80
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private struct HUDView: View {
    let mode: HUDController.Mode
    let onConfirm: () -> Void
    let onCancel: () -> Void
    let contentWidth: CGFloat

    private var isRecording: Bool {
        if case .recording = mode { return true }
        return false
    }

    var body: some View {
        HStack(spacing: 8) {
            icon
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
            if isRecording {
                Divider().frame(height: 14).padding(.horizontal, 4)
                Button("確定", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .help("録音を終了して入力します")
                Button("中止", action: onCancel)
                    .buttonStyle(.bordered)
                    .help("録音を破棄します")
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 14)
        .frame(width: contentWidth, height: 32)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: isRecording ? 16 : 18))
        .padding(6)
    }

    @ViewBuilder
    private var icon: some View {
        switch mode {
        case .recording:
            Circle().fill(.red).frame(width: 6, height: 6)
        case .processing:
            ProgressView().controlSize(.small)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    private var message: String {
        switch mode {
        case .recording: return "録音中"
        case .processing: return "文字起こし・整形中…"
        case .done(let text), .error(let text): return text
        }
    }

}
