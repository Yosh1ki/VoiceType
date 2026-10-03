import AppKit
import AVFoundation
import Foundation
import OSLog

enum TranscriptionProvider: String, CaseIterable, Identifiable {
    case local
    case openAI

    var id: String { rawValue }

    var label: String {
        switch self {
        case .local:
            return "ローカル（WhisperKit）"
        case .openAI:
            return "OpenAI Cloud"
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording
        case processing
        case error(String)
    }

    @Published var phase: Phase = .idle
    @Published var lastTranscript: String = ""
    @Published var lastOutput: String = ""
    @Published var localModelStatus: String = "未読み込み"
    @Published var isPreparingLocalModel = false
    @Published var hotKeyAvailable = false
    @Published var isCancelling = false
    @Published var lastTimingSummary = ""
    @Published var recordingShortcut: RecordingShortcut = .capsLock {
        didSet {
            UserDefaults.standard.set(recordingShortcut.rawValue, forKey: PreferenceKeys.recordingShortcut)
            hotKeyManager?.setShortcut(recordingShortcut)
            if phase == .recording {
                hud.show(.recording(recordingShortcut))
            }
        }
    }

    let history = HistoryStore()
    private var recordingBegan: Date?
    private var recordingDuration: TimeInterval = 0
    private var recordingApplication = "不明なアプリ"

    private let recorder = AudioRecorder()
    private let client = OpenAIClient()
    private let localWhisper = LocalWhisperService()
    private let inserter = TextInserter()
    private let hud = HUDController()
    private var hotKeyManager: HotKeyManager?
    private var activeProvider: TranscriptionProvider?
    private struct PendingRecording {
        let provider: TranscriptionProvider
        let audioURL: URL?
    }
    private var insertionTarget: TextInserter.Target?
    private var processingTask: Task<Void, Never>?
    private var recordingTimeoutTask: Task<Void, Never>?
    private var errorID = UUID()
    private var isStartingRecording = false
    private let performanceLog = Logger(subsystem: "VoiceType", category: "Performance")
    private var recordingStartSeconds: Double = 0

    init() {
        registerDefaults()
        hud.onConfirm = { [weak self] in self?.requestStopAndProcess() }
        hud.onCancel = { [weak self] in
            Task { @MainActor in await self?.cancelRecording() }
        }
        recordingShortcut = RecordingShortcut(rawValue: UserDefaults.standard.string(forKey: PreferenceKeys.recordingShortcut) ?? "") ?? .capsLock
        hotKeyManager = HotKeyManager(shortcut: recordingShortcut) { [weak self] in
            Task { @MainActor in
                await self?.toggleRecording()
            }
        }
        hotKeyAvailable = hotKeyManager?.isAvailable == true
        Task { [weak self] in
            while let self, !Task.isCancelled {
                if !self.hotKeyAvailable {
                    self.hotKeyManager?.retryInstall()
                    self.hotKeyAvailable = self.hotKeyManager?.isAvailable == true
                }
                try? await Task.sleep(for: .seconds(3))
            }
        }
        Task { [weak self] in
            guard let self, transcriptionProvider == .local else { return }
            await prepareLocalModel(showCompletion: false)
        }
    }

    var statusText: String {
        switch phase {
        case .idle:
            return "\(recordingShortcut.label) で音声入力"
        case .recording:
            return "録音中… もう一度 \(recordingShortcut.label) で確定"
        case .processing:
            return isCancelling ? "処理を中止しています…" : "文字起こし・整形中…"
        case .error(let message):
            return message
        }
    }

    var transcriptionProvider: TranscriptionProvider {
        let raw = UserDefaults.standard.string(forKey: PreferenceKeys.transcriptionProvider)
        return TranscriptionProvider(rawValue: raw ?? "") ?? .local
    }

    func toggleRecording() async {
        switch phase {
        case .idle, .error:
            await startRecording()
        case .recording:
            await stopAndProcess()
        case .processing:
            break
        }
    }

    func startRecording() async {
        guard !isStartingRecording, processingTask == nil, activeProvider == nil else { return }
        isStartingRecording = true
        defer { isStartingRecording = false }
        let start = ProcessInfo.processInfo.systemUptime
        let provider = transcriptionProvider
        let target = inserter.captureTarget()
        if provider == .openAI,
           KeychainStore.loadAPIKey()?.isEmpty != false {
            showError("OpenAI Cloudを使うにはAPIキーを設定してください")
            return
        }

        let granted = await recorder.requestMicrophonePermission()
        guard granted else {
            showError("マイク権限が必要です")
            return
        }

        do {
            switch provider {
            case .local: try localWhisper.startRecording()
            case .openAI: try recorder.start()
            }
            activeProvider = provider
            insertionTarget = target
            lastTranscript = ""
            lastOutput = ""
            recordingStartSeconds = ProcessInfo.processInfo.systemUptime - start
            recordingBegan = Date()
            recordingDuration = 0
            recordingApplication = target.flatMap { NSRunningApplication(processIdentifier: $0.processID)?.localizedName } ?? "不明なアプリ"
            phase = .recording
            hud.show(.recording(recordingShortcut))
            recordingTimeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(300))
                guard let self, !Task.isCancelled, self.phase == .recording else { return }
                await self.stopAndProcess()
            }
        } catch {
            showError("録音開始に失敗: \(error.localizedDescription)")
        }
    }

    func stopAndProcess() async {
        guard let provider = activeProvider else { return }
        let stoppedAt = ProcessInfo.processInfo.systemUptime
        recordingDuration = recordingBegan.map { Date().timeIntervalSince($0) } ?? 0
        recordingBegan = nil
        recordingTimeoutTask?.cancel()
        recordingTimeoutTask = nil
        phase = .processing
        hud.show(.processing)
        let audioURL: URL?
        switch provider {
        case .local:
            localWhisper.stopRecording()
            audioURL = nil
        case .openAI:
            audioURL = recorder.stop()
        }
        activeProvider = nil
        let recording = PendingRecording(provider: provider, audioURL: audioURL)
        processingTask = Task { [weak self] in
            await self?.process(recording, stoppedAt: stoppedAt)
        }
        await processingTask?.value
    }

    func requestStopAndProcess() {
        guard activeProvider != nil, phase == .recording else { return }
        phase = .processing
        hud.show(.processing)
        Task {
            await Task.yield()
            await stopAndProcess()
        }
    }

    func cancelRecording() async {
        guard let provider = activeProvider else { return }
        recordingTimeoutTask?.cancel()
        recordingTimeoutTask = nil
        activeProvider = nil
        phase = .processing
        isCancelling = true
        switch provider {
        case .local:
            await localWhisper.discardRecording()
        case .openAI:
            if let url = recorder.stop() { try? FileManager.default.removeItem(at: url) }
        }
        isCancelling = false
        insertionTarget = nil
        phase = .idle
        hud.show(.done("録音を中止しました"))
    }

    func cancelProcessing() {
        guard processingTask != nil else { return }
        isCancelling = true
        processingTask?.cancel()
    }

    private func process(_ recording: PendingRecording, stoppedAt: Double) async {
        defer {
            processingTask = nil
            isCancelling = false
        }
        var transcriptionComplete = false
        do {
            let transcript: String
            let transcriptionStarted = ProcessInfo.processInfo.systemUptime
            switch recording.provider {
            case .local:
                transcript = try await localWhisper.finishTranscription()
                localModelStatus = "準備完了"
            case .openAI:
                guard let audioURL = recording.audioURL else {
                    throw VoiceTypeError.message("録音データを取得できませんでした")
                }
                transcript = try await client.transcribe(audioURL: audioURL)
            }
            try Task.checkCancellation()
            guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw VoiceTypeError.noSpeech
            }
            let transcriptionSeconds = ProcessInfo.processInfo.systemUptime - transcriptionStarted
            lastTranscript = transcript
            await discard(recording)
            transcriptionComplete = true

            let shouldPolish = UserDefaults.standard.object(forKey: PreferenceKeys.polishText) as? Bool ?? true
            let hasAPIKey = KeychainStore.loadAPIKey()?.isEmpty == false
            let output: String
            var polishFailed = false
            let polishStarted = ProcessInfo.processInfo.systemUptime

            if shouldPolish && hasAPIKey {
                let dictionary = UserDefaults.standard.string(forKey: PreferenceKeys.dictionary) ?? ""
                do {
                    output = try await client.polish(transcript: transcript, dictionary: dictionary)
                } catch {
                    try Task.checkCancellation()
                    output = transcript
                    polishFailed = true
                }
            } else {
                output = transcript
            }
            let polishSeconds = ProcessInfo.processInfo.systemUptime - polishStarted
            try Task.checkCancellation()

            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                showError("文字起こし結果が空でした")
                return
            }

            lastOutput = trimmed
            let insertionStarted = ProcessInfo.processInfo.systemUptime
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(trimmed, forType: .string) else {
                throw VoiceTypeError.message("クリップボードへのコピーに失敗しました。メニューから再度コピーできます")
            }

            let autoPaste = UserDefaults.standard.object(forKey: PreferenceKeys.autoPaste) as? Bool ?? true
            var delivery = "クリップボードにコピー"
            if autoPaste {
                let pasted = await inserter.pasteFromClipboard(into: insertionTarget)
                delivery = pasted ? "入力要求を送信" : "クリップボードにコピー"
                phase = .idle
                if polishFailed {
                    hud.show(.done(pasted ? "AI整形に失敗したため、認識結果を入力しました" : "AI整形に失敗したため、認識結果をコピーしました"))
                } else {
                    hud.show(.done(pasted ? "入力しました" : "入力先を確認できないため、クリップボードにコピーしました"))
                }
            } else {
                phase = .idle
                hud.show(.done(polishFailed ? "AI整形に失敗したため、認識結果をコピーしました" : "クリップボードにコピーしました"))
            }
            if UserDefaults.standard.object(forKey: PreferenceKeys.saveHistory) as? Bool ?? true {
                history.add(HistoryEntry(date: Date(), transcript: transcript, output: trimmed,
                    duration: recordingDuration, application: recordingApplication, delivery: delivery))
            }
            let now = ProcessInfo.processInfo.systemUptime
            lastTimingSummary = String(format: "終了後 %.2f秒（認識 %.2f / 整形 %.2f / 入力要求 %.2f）・開始 %.2f秒",
                now - stoppedAt, transcriptionSeconds, polishSeconds, now - insertionStarted, recordingStartSeconds)
            insertionTarget = nil
            performanceLog.info("\(recording.provider.rawValue, privacy: .public): \(self.lastTimingSummary, privacy: .public)")
        } catch {
            if !transcriptionComplete { await discard(recording) }
            insertionTarget = nil
            if Task.isCancelled {
                phase = .idle
                hud.show(.done("処理を中止しました"))
            } else if case VoiceTypeError.noSpeech = error {
                phase = .idle
                hud.hide()
            } else {
                if !transcriptionComplete, recording.provider == .local { localModelStatus = "エラー" }
                showError(error.localizedDescription)
            }
        }
    }

    private func discard(_ recording: PendingRecording) async {
        switch recording.provider {
        case .local: await localWhisper.discardRecording()
        case .openAI:
            if let url = recording.audioURL { try? FileManager.default.removeItem(at: url) }
        }
    }

    func prepareLocalModel(showCompletion: Bool = true) async {
        guard !isPreparingLocalModel else { return }
        isPreparingLocalModel = true
        localModelStatus = "ダウンロード・読み込み中…"
        defer { isPreparingLocalModel = false }

        do {
            let start = ProcessInfo.processInfo.systemUptime
            try await localWhisper.prepare()
            localModelStatus = "準備完了"
            performanceLog.info("モデル準備: \(ProcessInfo.processInfo.systemUptime - start, privacy: .public)秒")
            if showCompletion, phase != .recording, phase != .processing {
                hud.show(.done("ローカルWhisperの準備ができました"))
            }
        } catch {
            localModelStatus = "エラー"
            if showCompletion {
                if phase == .recording || phase == .processing {
                    performanceLog.error("ローカルモデルの準備に失敗: \(error.localizedDescription, privacy: .public)")
                } else {
                    showError("ローカルモデルの準備に失敗: \(error.localizedDescription)")
                }
            }
        }
    }

    func requestAccessibilityPermission() {
        inserter.requestAccessibilityPermission()
        hotKeyManager?.retryInstall()
        hotKeyAvailable = hotKeyManager?.isAvailable == true
    }

    func copyLastOutput() {
        guard !lastOutput.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastOutput, forType: .string)
        hud.show(.done("コピーしました"))
    }

    private func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            PreferenceKeys.recordingShortcut: RecordingShortcut.capsLock.rawValue,
            PreferenceKeys.transcriptionProvider: TranscriptionProvider.local.rawValue,
            PreferenceKeys.saveHistory: true,
            PreferenceKeys.polishText: true,
            PreferenceKeys.autoPaste: true,
            PreferenceKeys.dictionary: "Supabase\nRevenueCat\nPetaMoney\nMoteMatch\nCodex"
        ])
    }

    private func showError(_ message: String) {
        let id = UUID()
        errorID = id
        phase = .error(message)
        hud.show(.error(message))
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if errorID == id, case .error = phase {
                phase = .idle
            }
        }
    }
}

enum PreferenceKeys {
    static let saveHistory = "saveHistory"
    static let recordingShortcut = "recordingShortcut"
    static let transcriptionProvider = "transcriptionProvider"
    static let polishText = "polishText"
    static let autoPaste = "autoPaste"
    static let dictionary = "dictionary"
}
