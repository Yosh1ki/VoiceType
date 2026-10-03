import SwiftUI

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var apiKey = ""
    @State private var savedMessage = ""
    @AppStorage(PreferenceKeys.transcriptionProvider) private var transcriptionProviderRaw = TranscriptionProvider.local.rawValue
    @AppStorage(PreferenceKeys.polishText) private var polishText = true
    @AppStorage(PreferenceKeys.autoPaste) private var autoPaste = true
    @State private var dictionary = ""
    @State private var dictionaryMessage = ""
    @AppStorage(PreferenceKeys.saveHistory) private var saveHistory = true

    private var transcriptionProviderBinding: Binding<TranscriptionProvider> {
        Binding(
            get: { TranscriptionProvider(rawValue: transcriptionProviderRaw) ?? .local },
            set: { transcriptionProviderRaw = $0.rawValue }
        )
    }

    var body: some View {
        Form {
            Section("音声認識") {
                Picker("文字起こし方法", selection: transcriptionProviderBinding) {
                    ForEach(TranscriptionProvider.allCases) { provider in
                        Text(provider.label).tag(provider)
                    }
                }
                .pickerStyle(.segmented)

                if transcriptionProviderBinding.wrappedValue == .local {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("WhisperKit")
                            Spacer()
                            Text(appState.localModelStatus)
                                .foregroundStyle(.secondary)
                        }

                        Text("モデル: \(LocalWhisperService.recommendedModel)")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Text("起動時にモデルを準備し、録音中から文字起こしを進めます。初回のみ約626MBをダウンロードします。音声はMac内で処理され、文字起こしAPI料金はかかりません。")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button(appState.isPreparingLocalModel ? "準備中…" : "ローカルモデルを今すぐ準備") {
                            Task {
                                await appState.prepareLocalModel()
                            }
                        }
                        .disabled(appState.isPreparingLocalModel)
                    }
                } else {
                    Text("OpenAIのgpt-transcribeへ録音データを送信して文字起こしします。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("OpenAI / AI整形") {
                Text("ご自身のOpenAI APIキーを入力してください。キーはこのMacのKeychainに保存され、APIの利用料金はご自身のOpenAIアカウントに請求されます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Link("OpenAI APIキーを作成", destination: URL(string: "https://platform.openai.com/api-keys")!)

                SecureField("sk-...", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Button("APIキーを保存") {
                        saveKey()
                    }
                    Button("削除", role: .destructive) {
                        KeychainStore.deleteAPIKey()
                        apiKey = ""
                        savedMessage = "削除しました"
                    }
                    Spacer()
                    Text(savedMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Toggle("文字起こし後にAIで自然な文章へ整形", isOn: $polishText)

                Text("ローカル文字起こしだけならAPIキーは不要です。AI整形がONでキーを設定すると、次の音声入力から文字起こし済みテキストとユーザー辞書をOpenAIへ送信します。APIキーが未設定なら整形をスキップして生の文字起こし結果を使います。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("動作") {
                Toggle("処理後にカーソル位置へ自動入力", isOn: $autoPaste)

                Picker("音声入力の開始・終了キー", selection: $appState.recordingShortcut) {
                    ForEach(RecordingShortcut.allCases) { shortcut in
                        Text(shortcut.label).tag(shortcut)
                    }
                }

                Text("入力先のアプリで同じキーを押すと録音を開始・終了します。VoiceTypeの画面を操作中は、日本語入力を優先してショートカットを停止します。fn・Shiftは単独で押して離すと切り替わります。ほかのキーとの組み合わせでは切り替わりません。録音は最長5分で自動確定します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if appState.recordingShortcut == .fn {
                    Text("fnで絵文字や音声入力も開く場合は、macOSの「システム設定 > キーボード」で「🌐キーを押して」を「何もしない」に設定してください。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("ユーザー辞書") {
                Text("日本語・英語の固有名詞を1行ずつ登録できます（例：山田太郎、株式会社音声、Supabase）。AI整形時に表記を優先します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                DictionaryEditor(text: $dictionary)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 140)
                    .accessibilityLabel("ユーザー辞書。日本語と英語に対応")
                HStack {
                    Button("辞書を保存") {
                        // End marked-text composition before persisting the draft.
                        NSApp.keyWindow?.makeFirstResponder(nil)
                        DispatchQueue.main.async {
                            UserDefaults.standard.set(dictionary, forKey: PreferenceKeys.dictionary)
                            dictionaryMessage = "保存しました"
                        }
                    }
                    Text(dictionaryMessage).font(.caption).foregroundStyle(.secondary)
                }
                Text("入力・変換を確定してから保存してください。辞書の適用にはAI整形とAPIキーが必要です。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("履歴") {
                Toggle("入力履歴をこのMacに保存", isOn: $saveHistory)
                Text("原文・確定した文章・日時・録音時間・アプリ名を保存します。音声は履歴に保存しません。OFFにしても既存の履歴は残り、メイン画面から削除できます。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("権限") {
                Button("アクセシビリティ設定を開く") {
                    appState.requestAccessibilityPermission()
                }
                Text("自動入力にはmacOSのアクセシビリティ権限が必要です。マイク権限は初回録音時にmacOSが確認します。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            apiKey = KeychainStore.loadAPIKey() ?? ""
            dictionary = UserDefaults.standard.string(forKey: PreferenceKeys.dictionary) ?? ""
        }
        .task(id: transcriptionProviderRaw) {
            if transcriptionProviderBinding.wrappedValue == .local {
                await appState.prepareLocalModel(showCompletion: false)
            }
        }
    }

    private func saveKey() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            savedMessage = "APIキーを入力してください"
            return
        }

        do {
            try KeychainStore.saveAPIKey(trimmed)
            savedMessage = "保存しました"
        } catch {
            savedMessage = error.localizedDescription
        }
    }
}
