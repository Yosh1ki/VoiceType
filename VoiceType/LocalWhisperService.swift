import Foundation
import WhisperKit

@MainActor
final class LocalWhisperService {
    static let recommendedModel = "large-v3-v20240930_626MB"

    private var whisperKit: WhisperKit?
    private var preparationTask: Task<WhisperKit, Error>?
    private var recordingProcessor: AudioProcessor?
    private var samples: RecordingSamples?
    private var streamingTask: Task<Void, Never>?
    private var pollingDelay: Task<Void, Error>?
    private var transcript = StreamingTranscript()
    private var lastDecodedSampleCount = 0
    private var lastDecodedSegments: [StreamingTranscript.Segment] = []

    var inputLevel: Double { samples?.inputLevel ?? 0 }

    func prepare() async throws {
        if whisperKit != nil { return }
        // Startup, settings, and recording share the same loading operation.
        let task: Task<WhisperKit, Error>
        if let preparationTask {
            task = preparationTask
        } else {
            task = Task { try await WhisperKit(WhisperKitConfig(model: Self.recommendedModel)) }
            preparationTask = task
        }
        do {
            whisperKit = try await task.value
            preparationTask = nil
        } catch {
            preparationTask = nil
            throw error
        }
    }

    func startRecording() throws {
        guard recordingProcessor == nil, streamingTask == nil else {
            throw VoiceTypeError.message("音声認識はすでに実行中です")
        }
        let buffer = RecordingSamples()
        let processor = AudioProcessor()
        try processor.startRecordingLive { buffer.append($0) }
        samples = buffer
        transcript = StreamingTranscript()
        lastDecodedSampleCount = 0
        lastDecodedSegments = []
        recordingProcessor = processor
        streamingTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await prepare()
                try Task.checkCancellation()
                var lastSampleCount = 0
                while recordingProcessor != nil {
                    let pollingSeconds = lastSampleCount == 0 ? 4.0 : 2.0
                    let delay = Task { try await Task.sleep(for: .seconds(pollingSeconds)) }
                    pollingDelay = delay
                    try? await delay.value
                    pollingDelay = nil
                    guard recordingProcessor != nil else { break }
                    let snapshot = buffer.snapshot()
                    guard snapshot.count - lastSampleCount >= WhisperKit.sampleRate else { continue }
                    lastSampleCount = snapshot.count
                    let segments = try await recognize(snapshot, from: transcript.confirmedEnd)
                    try Task.checkCancellation()
                    lastDecodedSampleCount = snapshot.count
                    lastDecodedSegments = segments
                    transcript.confirm(segments, audioDuration: Double(snapshot.count) / Double(WhisperKit.sampleRate))

                }
            } catch {
                // Retry the complete recording at finalization if partial recognition failed.
                if !Task.isCancelled { transcript = StreamingTranscript() }
            }
        }
    }

    func stopRecording() {
        recordingProcessor?.stopRecording()
        recordingProcessor = nil
        pollingDelay?.cancel()
    }

    func finishTranscription() async throws -> String {
        // An immediate stop can leave no samples. Silent recordings do not need
        // to wait for the model download or an in-flight recognition operation.
        guard let audio = samples?.snapshot(),
              RecognitionAudio.activeRange(in: audio, sampleRate: WhisperKit.sampleRate) != nil else {
            throw VoiceTypeError.noSpeech
        }
        // Finish the in-flight decoder before using the same model again.
        await streamingTask?.value
        streamingTask = nil
        try Task.checkCancellation()
        try await prepare()
        let decodedTailSeconds = Double(lastDecodedSampleCount) / Double(WhisperKit.sampleRate)
        let quietTail = lastDecodedSampleCount > 0 &&
            audio.count - lastDecodedSampleCount <= WhisperKit.sampleRate / 2 &&
            RecognitionAudio.activeRange(in: audio, sampleRate: WhisperKit.sampleRate, from: decodedTailSeconds) == nil
        let remaining = quietTail
            ? lastDecodedSegments
            : try await recognize(audio, from: transcript.confirmedEnd)
        let text = transcript.finalText(with: remaining)
        guard !text.isEmpty else {
            throw VoiceTypeError.noSpeech
        }

        return text
    }

    func discardRecording() async {
        stopRecording()
        streamingTask?.cancel()
        // Model downloads can continue in the shared preparation task. A cancelled
        // recording need not wait for that download before the next recording.
        if whisperKit != nil { await streamingTask?.value }
        streamingTask = nil
        samples = nil
        transcript = StreamingTranscript()
        lastDecodedSampleCount = 0
        lastDecodedSegments = []
    }

    private func recognize(_ audio: [Float], from seconds: Double) async throws -> [StreamingTranscript.Segment] {
        guard let whisperKit else {
            throw VoiceTypeError.message("ローカル音声認識モデルを読み込めませんでした")
        }
        // Do not decode silent tails: Whisper can invent polite closing phrases there.
        guard let range = RecognitionAudio.activeRange(in: audio, sampleRate: WhisperKit.sampleRate, from: seconds) else {
            return []
        }
        let options = DecodingOptions(
            task: .transcribe,
            language: nil,
            detectLanguage: true,
            skipSpecialTokens: true,
            clipTimestamps: [Float(range.lowerBound), Float(range.upperBound)],
            suppressBlank: true
        )
        let results = try await whisperKit.transcribe(audioArray: audio, decodeOptions: options)
        return results.flatMap(\.segments).filter {
            RecognitionAudio.accepts(
                start: Double($0.start), end: Double($0.end),
                noSpeechProbability: $0.noSpeechProb,
                averageLogProbability: $0.avgLogprob, compressionRatio: $0.compressionRatio,
                audio: audio, sampleRate: WhisperKit.sampleRate
            )
        }.map {
            StreamingTranscript.Segment(start: Double($0.start), end: Double($0.end), text: $0.text)
        }
    }
}

// The audio callback and recognition task run on different threads.
private final class RecordingSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Float] = []

    func append(_ buffer: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        samples.append(contentsOf: buffer)
    }

    var inputLevel: Double {
        lock.lock()
        defer { lock.unlock() }
        let tail = samples.suffix(1600)
        guard !tail.isEmpty else { return 0 }
        let energy = tail.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(tail.count)
        let decibels = 10 * log10(max(energy, 0.000001))
        return min(1, max(0, (decibels + 60) / 60))
    }

    func snapshot() -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        return samples
    }
}
