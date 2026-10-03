import Foundation

// swiftc VoiceType/StreamingTranscript.swift Tests/RecognitionAudioTests.swift -o /tmp/voicetype-recognition-tests
@main
struct RecognitionAudioTests {
    static func main() {
        let rate = 16_000
        let silence = [Float](repeating: 0, count: rate * 4)
        let nearSilence = [Float](repeating: 0.0001, count: rate)
        assert(RecognitionAudio.activeRange(in: silence, sampleRate: rate) == nil)
        assert(RecognitionAudio.activeRange(in: nearSilence, sampleRate: rate) == nil)
        assert(RecognitionAudio.activeRange(in: [], sampleRate: rate) == nil)

        // One second of quiet speech surrounded by silence.
        var audio = silence
        for index in rate..<(rate * 2) {
            audio[index] = 0.003 * Float(sin(Double(index) * 0.1))
        }
        let range = RecognitionAudio.activeRange(in: audio, sampleRate: rate)!
        assert(abs(range.lowerBound - 0.8) < 0.001)
        assert(abs(range.upperBound - 2.2) < 0.001)
        assert(RecognitionAudio.activeRange(in: audio, sampleRate: rate, from: 2.5) == nil)
        assert(RecognitionAudio.activeRange(in: audio, sampleRate: rate, from: 5) == nil)
        assert(RecognitionAudio.activeRange(in: audio, sampleRate: rate, from: .nan) == nil)
        assert(RecognitionAudio.activeRange(in: audio, sampleRate: 0) == nil)

        func accepts(_ start: Double, _ end: Double, noSpeech: Float = 0.1, logProbability: Float = -0.2, compression: Float = 1) -> Bool {
            RecognitionAudio.accepts(start: start, end: end, noSpeechProbability: noSpeech,
                averageLogProbability: logProbability, compressionRatio: compression,
                audio: audio, sampleRate: rate)
        }
        assert(accepts(1, 2))
        assert(!accepts(2.5, 3.5)) // A confident hallucination in silence is rejected.
        assert(!accepts(1, 2, noSpeech: 0.9, logProbability: -1.5))
        assert(accepts(1, 2, noSpeech: 0.9)) // Keep speech when decoder confidence is high.
        assert(!accepts(1, 2, compression: 3))
        assert(!accepts(.nan, 2))
        assert(!accepts(2, 1))

        // English, Japanese, and a genuinely spoken thank-you are preserved verbatim.
        let segments = [
            StreamingTranscript.Segment(start: 0, end: 1, text: "Hello, how are you?"),
            StreamingTranscript.Segment(start: 1, end: 2, text: "明日は meeting があります。"),
            StreamingTranscript.Segment(start: 2, end: 3, text: "ありがとうございます。")
        ]
        var transcript = StreamingTranscript()
        transcript.confirm(segments, audioDuration: 4)
        assert(transcript.finalText(with: Array(segments.dropFirst())) == "Hello, how are you? 明日は meeting があります。 ありがとうございます。")
        print("RecognitionAudioTests: all checks passed")
    }
}
