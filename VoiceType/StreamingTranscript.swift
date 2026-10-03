import Foundation

// A conservative energy gate, not a language or phrase blacklist. The -60 dBFS
// floor keeps quiet speech while excluding digital silence and near-silent tails.
enum RecognitionAudio {
    static func activeRange(in audio: [Float], sampleRate: Int, from start: Double = 0, to end: Double? = nil) -> Range<Double>? {
        guard sampleRate > 0, start.isFinite, start >= 0 else { return nil }
        let duration = Double(audio.count) / Double(sampleRate)
        let upper = min(end ?? duration, duration)
        guard upper.isFinite, start < upper else { return nil }
        let lowerIndex = Int(start * Double(sampleRate))
        let upperIndex = Int(upper * Double(sampleRate))
        let frameSize = max(1, sampleRate / 50) // 20 ms
        var first: Int?
        var last = 0
        for offset in stride(from: lowerIndex, to: upperIndex, by: frameSize) {
            let frameEnd = min(offset + frameSize, upperIndex)
            let energy = audio[offset..<frameEnd].reduce(0.0) { $0 + Double($1) * Double($1) }
            if energy / Double(frameEnd - offset) >= 0.000001 {
                if first == nil { first = offset }
                last = frameEnd
            }
        }
        guard let first else { return nil }
        // Preserve word boundaries and model context without decoding long silence.
        return max(start, Double(first) / Double(sampleRate) - 0.2)..<min(upper, Double(last) / Double(sampleRate) + 0.2)
    }

    static func accepts(start: Double, end: Double, noSpeechProbability: Float, averageLogProbability: Float, compressionRatio: Float, audio: [Float], sampleRate: Int) -> Bool {
        guard start.isFinite, end.isFinite, end > start,
              noSpeechProbability.isFinite, averageLogProbability.isFinite, compressionRatio.isFinite,
              !(noSpeechProbability > 0.6 && averageLogProbability < -1),
              compressionRatio <= 2.4 else { return false }
        return activeRange(in: audio, sampleRate: sampleRate, from: max(0, start), to: end) != nil
    }
}

struct StreamingTranscript {
    struct Segment {
        let start: Double
        let end: Double
        let text: String
    }

    private(set) var confirmedEnd: Double = 0
    private var confirmed: [Segment] = []

    var confirmedText: String {
        confirmed.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func preview(with remaining: [Segment]) -> (confirmed: String, tentative: String) {
        let full = finalText(with: remaining)
        let prefix = confirmedText
        return (prefix, String(full.dropFirst(prefix.count)))
    }

    mutating func confirm(_ segments: [Segment], audioDuration: Double) {
        // Keep two trailing segments and at least one second of context revisable.
        for segment in segments.dropLast(2) {
            guard segment.start.isFinite, segment.end.isFinite,
                  segment.start >= 0, segment.end > segment.start,
                  segment.start >= confirmedEnd - 0.02,
                  segment.end > confirmedEnd,
                  segment.end <= audioDuration - 1 else { break }
            confirmed.append(segment)
            confirmedEnd = segment.end
        }
    }

    func finalText(with remaining: [Segment]) -> String {
        var parts = confirmed.map(\.text)
        var lastEnd = confirmed.last?.end ?? 0
        for segment in remaining {
            guard segment.start.isFinite, segment.end.isFinite, segment.end > segment.start else { continue }
            // The final decoder may return segments already committed by a live pass.
            guard segment.end > confirmedEnd + 0.05 else { continue }
            var text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if segment.start < lastEnd - 0.05 {
                let prior = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
                let maximum = min(prior.count, text.count, 200)
                if maximum >= 2 {
                    for count in stride(from: maximum, through: 2, by: -1) {
                        if prior.suffix(count) == text.prefix(count) {
                            text.removeFirst(count)
                            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                            break
                        }
                    }
                }
            }
            if !text.isEmpty { parts.append(text) }
            lastEnd = max(lastEnd, segment.end)
        }
        return parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
