import AppKit
import Foundation

// swiftc VoiceType/AppState.swift VoiceType/VoiceTypeError.swift Tests/AppStateRecordingTests.swift -o /tmp/voicetype-app-state-tests
// Compile the real AppState with isolated substitutes below: no microphone,
// model, network, preferences, clipboard, history, or filesystem side effects.
@main
struct AppStateRecordingTests {
    @MainActor
    static func main() async {
        await localNoSpeech()
        await localFailure()
        await cloudEmptyResult()
        await cloudFailure()
        await cancelledTranscription()
        await recognizedSpeech()
        print("AppStateRecordingTests: all checks passed")
    }

    @MainActor
    static func makeState(provider: TranscriptionProvider = .local) async -> AppState {
        UserDefaults.standard.reset()
        UserDefaults.standard.set(provider.rawValue, forKey: PreferenceKeys.transcriptionProvider)
        FileManager.default.removedURLs = []
        NSPasteboard.general.writeCount = 0
        NSPasteboard.general.strings = []
        let state = AppState()
        if provider == .local {
            for _ in 0..<1_000 {
                if state.localModelStatus == "準備完了" && !state.isPreparingLocalModel { break }
                await Task.yield()
            }
            assert(state.localModelStatus == "準備完了" && !state.isPreparingLocalModel,
                "Startup model preparation did not finish")
        }
        return state
    }

    @MainActor
    static func localNoSpeech() async {
        let state = await makeState()
        let local = LocalWhisperService.latest!
        let hud = HUDController.latest!
        local.result = .failure(VoiceTypeError.noSpeech)
        await state.toggleRecording()
        assert(state.phase == .recording)
        await state.toggleRecording()
        assert(state.phase == .idle)
        assert(local.discardCount == 1)
        assert(hud.hideCount == 1 && !hud.isVisible)
        assert(!hud.messages.contains(where: { $0.contains("再試行") }))
        assert(state.localModelStatus != "エラー")
        assertNoDelivery(state)
        await state.toggleRecording()
        assert(state.phase == .recording && local.startCount == 2)
        await state.cancelRecording()
    }

    @MainActor
    static func localFailure() async {
        let state = await makeState()
        let local = LocalWhisperService.latest!
        let hud = HUDController.latest!
        local.result = .failure(VoiceTypeError.message("モデルの読み込みに失敗しました"))
        await state.toggleRecording()
        await state.toggleRecording()
        assert(local.discardCount == 1)
        assert(state.phase == .error("モデルの読み込みに失敗しました"))
        assert(hud.messages.last == "モデルの読み込みに失敗しました")
        assertNoDelivery(state)
        await state.toggleRecording()
        assert(state.phase == .recording && local.startCount == 2)
        await state.cancelRecording()
    }

    @MainActor
    static func cloudEmptyResult() async {
        let state = await makeState(provider: .openAI)
        let client = OpenAIClient.latest!
        let recorder = AudioRecorder.latest!
        let hud = HUDController.latest!
        client.result = .success(" \n\t　")
        await state.toggleRecording()
        await state.toggleRecording()
        assert(state.phase == .idle)
        assert(hud.hideCount == 1 && !hud.isVisible)
        assert(FileManager.default.removedURLs == [recorder.url])
        assertNoDelivery(state)
        await state.toggleRecording()
        assert(state.phase == .recording && recorder.startCount == 2)
        await state.cancelRecording()
    }

    @MainActor
    static func cloudFailure() async {
        let state = await makeState(provider: .openAI)
        let client = OpenAIClient.latest!
        let recorder = AudioRecorder.latest!
        client.result = .failure(VoiceTypeError.message("ネットワークに接続できません"))
        await state.toggleRecording()
        await state.toggleRecording()
        assert(state.phase == .error("ネットワークに接続できません"))
        assert(FileManager.default.removedURLs == [recorder.url])
        assert(HUDController.latest!.messages.last == "ネットワークに接続できません")
        assertNoDelivery(state)
        await state.toggleRecording()
        assert(state.phase == .recording && recorder.startCount == 2)
        await state.cancelRecording()
    }

    @MainActor
    static func cancelledTranscription() async {
        let state = await makeState()
        let local = LocalWhisperService.latest!
        local.suspendFinish = true
        await state.toggleRecording()
        let stopping = Task { await state.toggleRecording() }
        for _ in 0..<1_000 {
            if local.finishContinuation != nil { break }
            await Task.yield()
        }
        assert(local.finishContinuation != nil, "Transcription did not start")
        assert(state.phase == .processing)
        state.cancelProcessing()
        // Simulate an in-flight decoder that completes despite cancellation.
        local.finishContinuation?.resume(returning: "入力してはいけない結果")
        local.finishContinuation = nil
        await stopping.value
        assert(state.phase == .idle && !state.isCancelling)
        assert(local.discardCount == 1)
        assertNoDelivery(state)
        await state.toggleRecording()
        assert(state.phase == .recording && local.startCount == 2)
        await state.cancelRecording()
    }

    @MainActor
    static func recognizedSpeech() async {
        let state = await makeState()
        let local = LocalWhisperService.latest!
        local.result = .success("明日の予定を確認します。")
        await state.toggleRecording()
        await state.toggleRecording()
        assert(state.phase == .idle)
        assert(local.discardCount == 1)
        assert(state.lastTranscript == "明日の予定を確認します。")
        assert(state.lastOutput == state.lastTranscript)
        assert(OpenAIClient.latest!.polishCount == 1)
        assert(NSPasteboard.general.writeCount == 2)
        assert(NSPasteboard.general.strings == [state.lastOutput])
        assert(TextInserter.latest!.pasteCount == 1)
        assert(state.history.entries.count == 1)
        assert(state.history.entries.first?.output == state.lastOutput)
        await state.toggleRecording()
        assert(state.phase == .recording && local.startCount == 2)
        await state.cancelRecording()
    }

    @MainActor
    static func assertNoDelivery(_ state: AppState) {
        assert(state.lastTranscript.isEmpty && state.lastOutput.isEmpty)
        assert(OpenAIClient.latest!.polishCount == 0)
        assert(state.history.entries.isEmpty)
        assert(TextInserter.latest!.pasteCount == 0)
        assert(NSPasteboard.general.writeCount == 0)
    }
}

@MainActor
final class UserDefaults {
    static let standard = UserDefaults()
    private var values: [String: Any] = [:]
    func reset() { values = [:] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func string(forKey key: String) -> String? { values[key] as? String }
    func object(forKey key: String) -> Any? { values[key] }
    func register(defaults: [String: Any]) {
        for (key, value) in defaults where values[key] == nil { values[key] = value }
    }
}

@MainActor
final class FileManager {
    static let `default` = FileManager()
    var removedURLs: [URL] = []
    func removeItem(at url: URL) throws { removedURLs.append(url) }
}

@MainActor
final class NSPasteboard {
    enum PasteboardType { case string }
    static let general = NSPasteboard()
    var writeCount = 0
    var strings: [String] = []
    func clearContents() { writeCount += 1 }
    @discardableResult
    func setString(_ string: String, forType type: PasteboardType) -> Bool {
        writeCount += 1
        strings.append(string)
        return true
    }
}

@MainActor
final class AudioRecorder {
    static var latest: AudioRecorder?
    let url = URL(fileURLWithPath: "/isolated-test/recording.m4a")
    var startCount = 0
    init() { Self.latest = self }
    func requestMicrophonePermission() async -> Bool { true }
    func start() throws { startCount += 1 }
    func stop() -> URL? { url }
}

@MainActor
final class LocalWhisperService {
    static var latest: LocalWhisperService?
    var result: Result<String, Error> = .failure(VoiceTypeError.noSpeech)
    var startCount = 0
    var discardCount = 0
    var suspendFinish = false
    var finishContinuation: CheckedContinuation<String, Error>?
    init() { Self.latest = self }
    func prepare() async throws {}
    func startRecording() throws { startCount += 1 }
    func stopRecording() {}
    func finishTranscription() async throws -> String {
        if suspendFinish {
            return try await withCheckedThrowingContinuation { finishContinuation = $0 }
        }
        return try result.get()
    }
    func discardRecording() async { discardCount += 1 }
}

@MainActor
final class OpenAIClient {
    static var latest: OpenAIClient?
    var result: Result<String, Error> = .success("")
    var polishCount = 0
    init() { Self.latest = self }
    func transcribe(audioURL: URL) async throws -> String { try result.get() }
    func polish(transcript: String, dictionary: String) async throws -> String {
        polishCount += 1
        return transcript
    }
}

enum KeychainStore {
    static func loadAPIKey() -> String? { "isolated-test-key" }
}

enum RecordingShortcut: String {
    case capsLock
    var label: String { "Caps Lock" }
}

@MainActor
final class HotKeyManager {
    var isAvailable = true
    init(shortcut: RecordingShortcut, onToggle: @escaping () -> Void) {}
    func setShortcut(_ shortcut: RecordingShortcut) {}
    func retryInstall() {}
}

@MainActor
final class TextInserter {
    struct Target { let processID: pid_t }
    static var latest: TextInserter?
    var pasteCount = 0
    init() { Self.latest = self }
    func captureTarget() -> Target? { nil }
    func pasteFromClipboard(into target: Target?) async -> Bool {
        pasteCount += 1
        return true
    }
    func requestAccessibilityPermission() {}
}

struct HistoryEntry {
    let date: Date
    let transcript: String
    let output: String
    let duration: TimeInterval
    let application: String
    let delivery: String
}

@MainActor
final class HistoryStore {
    var entries: [HistoryEntry] = []
    func add(_ entry: HistoryEntry) { entries.append(entry) }
}

@MainActor
final class HUDController {
    enum Mode {
        case recording(RecordingShortcut)
        case processing
        case done(String)
        case error(String)
    }
    static var latest: HUDController?
    var onConfirm: () -> Void = {}
    var onCancel: () -> Void = {}
    var messages: [String] = []
    var hideCount = 0
    var isVisible = false
    init() { Self.latest = self }
    func hide() {
        hideCount += 1
        isVisible = false
    }
    func show(_ mode: Mode) {
        isVisible = true
        switch mode {
        case .done(let message), .error(let message): messages.append(message)
        case .recording, .processing: break
        }
    }
}
