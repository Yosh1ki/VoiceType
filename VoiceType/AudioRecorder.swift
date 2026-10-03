import AVFoundation
import Foundation

final class AudioRecorder: NSObject {
    private var recorder: AVAudioRecorder?
    private var currentURL: URL?

    func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }

    func start() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("voicetype-\(UUID().uuidString)")
            .appendingPathExtension("m4a")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            AVEncoderBitRateKey: 128_000
        ]

        let newRecorder = try AVAudioRecorder(url: url, settings: settings)
        newRecorder.isMeteringEnabled = true
        newRecorder.prepareToRecord()
        guard newRecorder.record() else {
            throw VoiceTypeError.message("マイク録音を開始できませんでした")
        }

        recorder = newRecorder
        currentURL = url
    }

    var inputLevel: Double {
        recorder?.updateMeters()
        let decibels = Double(recorder?.averagePower(forChannel: 0) ?? -60)
        return min(1, max(0, (decibels + 60) / 60))
    }

    func stop() -> URL? {
        recorder?.stop()
        recorder = nil
        defer { currentURL = nil }
        return currentURL
    }
}
