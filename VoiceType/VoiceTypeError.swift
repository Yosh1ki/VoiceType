import Foundation

enum VoiceTypeError: LocalizedError {
    case noSpeech
    case message(String)

    var errorDescription: String? {
        switch self {
        case .noSpeech:
            return "発話を認識できませんでした"
        case .message(let value):
            return value
        }
    }
}
