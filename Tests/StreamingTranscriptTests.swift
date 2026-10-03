import Foundation

// swiftc VoiceType/StreamingTranscript.swift Tests/StreamingTranscriptTests.swift -o /tmp/voicetype-streaming-tests
@main
struct StreamingTranscriptTests {
    typealias Segment = StreamingTranscript.Segment

    static func main() {
        var transcript = StreamingTranscript()
        let first = Segment(start: 0, end: 2, text: "最初の文章。")
        let second = Segment(start: 2, end: 4, text: "次の文章。")
        let tentative = Segment(start: 4, end: 6, text: "明日の、")
        let tail = Segment(start: 6, end: 8, text: "いや今日の予定。")

        // Short recordings stay fully revisable, including self-corrections.
        transcript.confirm([first, tentative], audioDuration: 6)
        assert(transcript.confirmedEnd == 0)
        transcript.confirm([first, second, tentative, tail], audioDuration: 8)
        assert(transcript.confirmedEnd == 4)
        let corrected = Segment(start: 4, end: 9, text: "今日の予定です。")
        assert(transcript.finalText(with: [corrected]) == "最初の文章。 次の文章。 今日の予定です。")

        let preview = transcript.preview(with: [corrected])
        assert(preview.confirmed == "最初の文章。 次の文章。")
        assert(preview.confirmed + preview.tentative == transcript.finalText(with: [corrected]))
        assert(preview.tentative == " 今日の予定です。")
        let unconfirmed = StreamingTranscript().preview(with: [first])
        assert(unconfirmed.confirmed.isEmpty && unconfirmed.tentative == first.text)

        // Repeated snapshots must not append the same confirmed prefix twice.
        transcript.confirm([first, second, tentative, tail], audioDuration: 8)
        assert(transcript.finalText(with: [corrected]) == "最初の文章。 次の文章。 今日の予定です。")

        // Segment boundaries too close to the current audio end remain tentative.
        var nearEnd = StreamingTranscript()
        nearEnd.confirm([first, second, tentative, tail], audioDuration: 2.5)
        assert(nearEnd.confirmedEnd == 0)

        // Long recordings can advance across successive recognition windows.
        let following = Segment(start: 8, end: 12, text: "追加の文章。")
        transcript.confirm([tentative, tail, following], audioDuration: 13)
        assert(transcript.confirmedEnd == 6)
        assert(transcript.finalText(with: [tail, following]) == "最初の文章。 次の文章。 明日の、 いや今日の予定。 追加の文章。")

        var invalid = StreamingTranscript()
        invalid.confirm([Segment(start: 0, end: .nan, text: "不正"), second, tentative], audioDuration: 8)
        assert(invalid.confirmedEnd == 0)
        assert(StreamingTranscript().finalText(with: []) == "")

        // A final decoding window can return already-confirmed text again.
        var overlapping = StreamingTranscript()
        overlapping.confirm([first, second, tentative, tail], audioDuration: 8)
        assert(overlapping.finalText(with: [
            Segment(start: 1.9, end: 3.9, text: "次の文章。"),
            Segment(start: 3.9, end: 6, text: "次の文章。 新しい文章。")
        ]) == "最初の文章。 次の文章。 新しい文章。")

        // A phrase spoken again later is intentional and must remain.
        assert(overlapping.finalText(with: [
            Segment(start: 5, end: 6, text: "次の文章。")
        ]) == "最初の文章。 次の文章。 次の文章。")
        assert(overlapping.finalText(with: [
            Segment(start: 4, end: 5, text: "次の文章。")
        ]) == "最初の文章。 次の文章。 次の文章。")
        print("StreamingTranscriptTests: all checks passed")
    }
}
