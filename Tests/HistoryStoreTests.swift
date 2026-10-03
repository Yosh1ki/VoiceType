import Foundation

@main
struct HistoryStoreTests {
    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.json")
        let store = HistoryStore(url: url)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 9 * 3600)!
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 0, minute: 1))!
        var entry = HistoryEntry(date: date, transcript: "やまだたろう", output: "山田太郎 👨‍👩‍👧‍👦\nです", duration: 12,
                                 application: "テスト", delivery: "コピー")
        store.add(entry)
        store.add(HistoryEntry(date: date.addingTimeInterval(-120), transcript: "昨日", output: "昨日", duration: 8,
                               application: "メモ", delivery: "コピー"))
        assert(store.today(at: date, calendar: calendar).count == 1)
        assert(entry.characterCount == 7)
        assert(store.error == nil)
        let restored = HistoryStore(url: url)
        assert(restored.entries.count == 2)
        assert(restored.entries[0].transcript == "やまだたろう")
        entry.output = "山田太郎です。"
        restored.replace(entry)
        assert(restored.entries.count == 2)
        assert(restored.entries[0].duration == 12)
        restored.delete(entry.id)
        assert(HistoryStore(url: url).entries.count == 1)
        assert(restored.today(at: date, calendar: calendar).isEmpty)
        let invalid = Data("invalid history".utf8)
        try invalid.write(to: url)
        let broken = HistoryStore(url: url)
        broken.add(entry)
        assert(broken.error != nil)
        let preserved = try Data(contentsOf: url)
        assert(preserved == invalid)
        print("HistoryStoreTests: all checks passed")
    }
}
