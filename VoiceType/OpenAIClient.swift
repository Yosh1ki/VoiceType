import Foundation

struct OpenAIClient {
    private let baseURL = URL(string: "https://api.openai.com/v1")!

    func transcribe(audioURL: URL) async throws -> String {
        guard let apiKey = KeychainStore.loadAPIKey(), !apiKey.isEmpty else {
            throw VoiceTypeError.message("OpenAI APIキーが設定されていません")
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var request = URLRequest(url: baseURL.appendingPathComponent("audio/transcriptions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: audioURL)
        request.httpBody = makeMultipartBody(
            boundary: boundary,
            fields: [
                "model": "gpt-transcribe",
                "response_format": "json"
            ],
            fileField: "file",
            filename: audioURL.lastPathComponent,
            mimeType: "audio/mp4",
            fileData: audioData
        )

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)

        let decoded = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return decoded.text
    }

    func polish(transcript: String, dictionary: String) async throws -> String {
        guard let apiKey = KeychainStore.loadAPIKey(), !apiKey.isEmpty else {
            throw VoiceTypeError.message("OpenAI APIキーが設定されていません")
        }

        var instructions = """
        あなたは音声入力された文字起こしを整えるエンジンです。
        最終的に整形された文章のみを出力してください。説明、注釈、引用符などは付けないでください。
        以下のルールに従ってください。
        - 話者が意図した意味と言語をそのまま維持する
        - 翻訳しない。英語は英語、日本語は日本語のまま出力し、混在している場合も各部分の言語を維持する
        - 「えー」「あのー」「そのー」「なんか」など、意味のないフィラーを削除する
        - 言い淀みや途中で言い直した部分を整理する
        - 自己訂正があった場合は、最後に話した意図を採用する
        - 不自然な重複を削除する
        - 自然な句読点と改行を追加する
        - 話者が言っていない情報を追加しない
        - 入力にない挨拶、お礼、締めの言葉（「ありがとうございます」など）を補完しない
        - 必要以上に文章を丁寧・フォーマルにしない
        - 元の話し方やトーンをできるだけ維持する
        - 日本語と英語、固有名詞、技術用語が混在している場合も、その表記をできるだけ維持する
        - 「改行」「次の行」「new line」などの書式指示は文字として出力せず、実際に改行する
        - 「箇条書き」「bullet points」などの指示があった場合は、実際に箇条書きへ整形する
        - 「句点」「読点」「ビックリマーク」「クエスチョンマーク」など明らかな句読点の指示は、可能な限り対応する
        - 内容を要約したり、別の表現へ積極的に書き換えたりせず、あくまで音声入力を読みやすく整える
        """

        let cleanDictionary = dictionary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanDictionary.isEmpty {
            instructions += "\n\nPrefer these spellings for names, products, and technical terms when they match the audio:\n\(cleanDictionary)"
        }

        let payload = ResponsesRequest(
            model: "gpt-6-luna",
            reasoning: .init(effort: "none"),
            instructions: instructions,
            input: transcript
        )

        var request = URLRequest(url: baseURL.appendingPathComponent("responses"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)

        let decoded = try JSONDecoder().decode(ResponsesResponse.self, from: data)
        guard let text = decoded.output
            .flatMap({ $0.content ?? [] })
            .compactMap({ $0.text })
            .first(where: { !$0.isEmpty }) else {
            throw VoiceTypeError.message("AI整形結果を読み取れませんでした")
        }
        return text
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw VoiceTypeError.message("APIレスポンスを確認できませんでした")
        }
        guard (200..<300).contains(http.statusCode) else {
            if let apiError = try? JSONDecoder().decode(OpenAIErrorEnvelope.self, from: data) {
                throw VoiceTypeError.message("OpenAI API: \(apiError.error.message)")
            }
            let raw = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw VoiceTypeError.message("OpenAI API (HTTP \(http.statusCode)): \(raw)")
        }
    }

    private func makeMultipartBody(
        boundary: String,
        fields: [String: String],
        fileField: String,
        filename: String,
        mimeType: String,
        fileData: Data
    ) -> Data {
        var body = Data()
        let crlf = "\r\n"

        for (name, value) in fields {
            body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\(crlf)\(crlf)".data(using: .utf8)!)
            body.append("\(value)\(crlf)".data(using: .utf8)!)
        }

        body.append("--\(boundary)\(crlf)".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(filename)\"\(crlf)".data(using: .utf8)!)
        body.append("Content-Type: \(mimeType)\(crlf)\(crlf)".data(using: .utf8)!)
        body.append(fileData)
        body.append(crlf.data(using: .utf8)!)
        body.append("--\(boundary)--\(crlf)".data(using: .utf8)!)
        return body
    }
}

private struct TranscriptionResponse: Decodable {
    let text: String
}

private struct ResponsesRequest: Encodable {
    let model: String
    let reasoning: Reasoning
    let instructions: String
    let input: String

    struct Reasoning: Encodable {
        let effort: String
    }
}

private struct ResponsesResponse: Decodable {
    let output: [OutputItem]

    struct OutputItem: Decodable {
        let content: [ContentItem]?
    }

    struct ContentItem: Decodable {
        let text: String?
    }
}

private struct OpenAIErrorEnvelope: Decodable {
    let error: APIError

    struct APIError: Decodable {
        let message: String
    }
}
