import Foundation
import Combine

struct HistoryEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    let date: Date
    let transcript: String
    var output: String
    let duration: TimeInterval
    let application: String
    var delivery: String
    var characterCount: Int { output.filter { !$0.isWhitespace }.count }
}

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []
    @Published private(set) var error: String?
    private let url: URL
    private var loadFailed = false

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceType/history.json")
        do {
            if FileManager.default.fileExists(atPath: self.url.path) {
                entries = try JSONDecoder().decode([HistoryEntry].self, from: Data(contentsOf: self.url))
                    .sorted { $0.date > $1.date }
            }
        } catch {
            loadFailed = true
            self.error = "履歴を読み込めませんでした。保存ファイルを確認してください。"
        }
    }

    func add(_ entry: HistoryEntry) {
        // Do not overwrite an unreadable history file.
        guard !loadFailed else { return }
        commit([entry] + entries)
    }

    func delete(_ id: UUID) { commit(entries.filter { $0.id != id }) }

    func replace(_ entry: HistoryEntry) {
        commit(entries.map { $0.id == entry.id ? entry : $0 })
    }

    private func commit(_ updated: [HistoryEntry]) {
        guard !loadFailed else { return }
        entries = updated
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(updated).write(to: url, options: .atomic)
            entries = updated
            error = nil
        } catch {
            self.error = "履歴を保存できませんでした: \(error.localizedDescription)"
        }
    }

    func today(at date: Date = Date(), calendar: Calendar = .current) -> [HistoryEntry] {
        entries.filter { calendar.isDate($0.date, inSameDayAs: date) }
    }
}
