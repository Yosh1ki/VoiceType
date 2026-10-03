import SwiftUI

struct MainView: View {
    @ObservedObject var appState: AppState
    @ObservedObject var history: HistoryStore
    @State private var page = "history"
    @State private var query = ""
    @State private var selected: HistoryEntry?

    private var filtered: [HistoryEntry] {
        history.entries.filter {
            query.isEmpty || $0.output.localizedStandardContains(query) ||
            $0.transcript.localizedStandardContains(query) || $0.application.localizedStandardContains(query)
        }
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 24) {
                Label("VoiceType", systemImage: "waveform.circle.fill")
                    .font(.title2.bold()).padding(.top, 18)
                VStack(spacing: 8) {
                    navigation("履歴", icon: "clock.arrow.circlepath", tag: "history")
                    navigation("設定", icon: "slider.horizontal.3", tag: "settings")
                }
                Spacer()
                Label(appState.statusText, systemImage: "mic")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(20)
                .navigationSplitViewColumnWidth(210)
        } detail: {
            if page == "settings" {
                SettingsView(appState: appState)
                    .navigationTitle("設定")
            } else {
                historyPage.navigationTitle("履歴")
            }
        }
        .frame(minWidth: 820, minHeight: 580)
        .sheet(item: $selected) { entry in
            HistoryDetail(entry: entry, history: history, onDelete: {
                history.delete(entry.id)
                selected = nil
            })
        }
    }

    private func navigation(_ title: String, icon: String, tag: String) -> some View {
        Button { page = tag } label: {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading).padding(10)
                .background(page == tag ? Color.accentColor.opacity(0.12) : .clear,
                            in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain)
    }

    private var historyPage: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("今日の入力").font(.largeTitle.bold())
                }
                Spacer()
                if appState.phase == .recording {
                    Button("録音を確定") { appState.requestStopAndProcess() }
                }
            }
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let today = history.today(at: context.date)
                HStack(spacing: 12) {
                    metric("文字", value: today.reduce(0) { $0 + $1.characterCount }.formatted(), icon: "textformat")
                    metric("回", value: today.count.formatted(), icon: "mic")
                    metric("録音時間", value: Self.duration(today.reduce(0) { $0 + $1.duration }), icon: "timer")
                }
            }
            Text("確定した文章を集計します（空白・改行を除く）。履歴を削除すると集計からも除かれます。")
                .font(.caption).foregroundStyle(.secondary)
            if let error = history.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
            if appState.hasFailedRecording {
                HStack {
                    Text("前の録音を認識できませんでした。")
                    Button("再試行") { Task { await appState.retryFailedRecording() } }
                    Button("破棄") { Task { await appState.discardFailedRecording() } }
                }.disabled(appState.phase == .processing)
            }
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("文章やアプリ名で履歴を検索", text: $query).textFieldStyle(.plain)
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain) }
            }.padding(12).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
            if filtered.isEmpty {
                ContentUnavailableView(query.isEmpty ? "まだ履歴がありません" : "一致する履歴がありません",
                                       systemImage: query.isEmpty ? "waveform" : "magnifyingglass",
                                       description: Text(query.isEmpty ? "入力先のアプリで \(appState.recordingShortcut.label) を押して話してください。" : "別の言葉で検索してください。"))
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(filtered) { entry in
                            Button { selected = entry } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    HStack {
                                        Text(entry.date, format: .dateTime.month().day().hour().minute())
                                        Text("· \(entry.application)")
                                        Spacer()
                                        Text("\(entry.characterCount)文字")
                                    }.font(.caption).foregroundStyle(.secondary)
                                    Text(entry.output).lineLimit(3).multilineTextAlignment(.leading)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    HStack {
                                        Text(entry.delivery).font(.caption).foregroundStyle(.secondary)
                                        Spacer()
                                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                    }
                                }.padding(16).background(.background, in: RoundedRectangle(cornerRadius: 12))
                                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }
        }.padding(28)
    }

    private func metric(_ label: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: icon).foregroundStyle(Color.accentColor)
            Text(value).font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds))
        return "\(value / 60):\(String(format: "%02d", value % 60))"
    }
}

private struct HistoryDetail: View {
    @State var entry: HistoryEntry
    @ObservedObject var history: HistoryStore
    let onDelete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var confirmDelete = false
    @State private var isPolishing = false
    @State private var polishError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                VStack(alignment: .leading) {
                    Text(entry.application).font(.title2.bold())
                    Text(entry.date, format: .dateTime).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("閉じる") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isPolishing)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("確定した文章").font(.headline)
                    Text(entry.output).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                    Text("整形前の原文").font(.headline)
                    Text(entry.transcript).textSelection(.enabled).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if let polishError { Text(polishError).font(.caption).foregroundStyle(.red) }
            HStack {
                Button(isPolishing ? "整形中…" : "再整形") {
                    isPolishing = true
                    polishError = nil
                    Task { @MainActor in
                        defer { isPolishing = false }
                        do {
                            let output = try await OpenAIClient().polish(transcript: entry.transcript,
                                dictionary: UserDefaults.standard.string(forKey: PreferenceKeys.dictionary) ?? "")
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !output.isEmpty else { throw VoiceTypeError.message("整形結果が空でした") }
                            entry.output = output
                            entry.delivery = "履歴内で再整形（未入力）"
                            copied = false
                            history.replace(entry)
                        } catch { polishError = error.localizedDescription }
                    }
                }.disabled(isPolishing)
                Button("削除", role: .destructive) { confirmDelete = true }.disabled(isPolishing)
                Spacer()
                Text("\(entry.characterCount)文字 · \(MainView.duration(entry.duration))").foregroundStyle(.secondary)
                Button(copied ? "コピーしました" : "コピー") {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(entry.output, forType: .string)
                }.buttonStyle(.borderedProminent)
            }
        }.padding(24).frame(width: 660, height: 520)
            .interactiveDismissDisabled(isPolishing)
            .alert("この履歴を削除しますか？", isPresented: $confirmDelete) {
                Button("削除", role: .destructive, action: onDelete)
                Button("キャンセル", role: .cancel) { }
            } message: { Text("削除すると、今日の集計からも除かれます。") }
    }
}
