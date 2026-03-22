import AVFAudio
import Foundation
import Speech

enum SpeechCaptureError: LocalizedError {
    case microphoneDenied
    case speechDenied
    case recorderUnavailable
    case transcriptionUnavailable
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .microphoneDenied:
            return "未獲得咪高峰權限。"
        case .speechDenied:
            return "未獲得語音辨識權限。"
        case .recorderUnavailable:
            return "無法啟動錄音。"
        case .transcriptionUnavailable:
            return "Speech Analyzer 暫時未可用。"
        case .emptyTranscript:
            return "錄音已完成，但暫時未能辨識到文字。"
        }
    }
}

@MainActor
final class SpeechCaptureService: NSObject {
    private var recorder: AVAudioRecorder?
    private var activeRecordingURL: URL?

    func startRecording() async throws {
        try await requestPermissions()
        try configureSessionForRecording()

        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ai-dj-\(UUID().uuidString).caf"
        )
        activeRecordingURL = fileURL

        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        let recorder = try AVAudioRecorder(url: fileURL, settings: settings)
        recorder.isMeteringEnabled = true
        recorder.prepareToRecord()
        guard recorder.record() else {
            throw SpeechCaptureError.recorderUnavailable
        }

        self.recorder = recorder
    }

    func stopRecordingAndTranscribe(locale: Locale = Locale(identifier: "zh-HK")) async throws -> String {
        recorder?.stop()
        recorder = nil

        guard let fileURL = activeRecordingURL else {
            throw SpeechCaptureError.recorderUnavailable
        }

        try configureSessionForPlayback()
        let transcript = try await transcribe(fileURL: fileURL, locale: locale)
        guard !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SpeechCaptureError.emptyTranscript
        }
        return transcript
    }

    private func requestPermissions() async throws {
        let microphoneGranted = await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }

        guard microphoneGranted else {
            throw SpeechCaptureError.microphoneDenied
        }

        let speechStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }

        guard speechStatus == .authorized else {
            throw SpeechCaptureError.speechDenied
        }
    }

    private func transcribe(fileURL: URL, locale: Locale) async throws -> String {
        if #available(iOS 26.0, *), SpeechTranscriber.isAvailable {
            return try await transcribeWithSpeechAnalyzer(fileURL: fileURL, locale: locale)
        }

        return try await transcribeWithSpeechRecognizer(fileURL: fileURL, locale: locale)
    }

    @available(iOS 26.0, *)
    private func transcribeWithSpeechAnalyzer(fileURL: URL, locale: Locale) async throws -> String {
        let selectedLocale = await SpeechTranscriber.supportedLocale(equivalentTo: locale) ?? locale
        let transcriber = SpeechTranscriber(locale: selectedLocale, preset: .transcription)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let audioFile = try AVAudioFile(forReading: fileURL)

        let collector = Task { () throws -> String in
            var transcript = ""
            for try await result in transcriber.results {
                let latest = String(result.text.characters)
                if !latest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    transcript = latest
                }
            }
            return transcript
        }

        try await analyzer.prepareToAnalyze(in: audioFile.processingFormat)
        try await analyzer.start(inputAudioFile: audioFile, finishAfterFile: true)
        return try await collector.value
    }

    private func transcribeWithSpeechRecognizer(fileURL: URL, locale: Locale) async throws -> String {
        guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
            throw SpeechCaptureError.transcriptionUnavailable
        }

        let request = SFSpeechURLRecognitionRequest(url: fileURL)
        request.requiresOnDeviceRecognition = false
        request.shouldReportPartialResults = false

        return try await withCheckedThrowingContinuation { continuation in
            var task: SFSpeechRecognitionTask?
            task = recognizer.recognitionTask(with: request) { result, error in
                if let error {
                    task?.cancel()
                    continuation.resume(throwing: error)
                    return
                }

                guard let result else { return }
                if result.isFinal {
                    task?.cancel()
                    continuation.resume(returning: result.bestTranscription.formattedString)
                }
            }
        }
    }

    private func configureSessionForRecording() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
    }

    private func configureSessionForPlayback() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .spokenAudio, options: [])
        try session.setActive(true)
    }
}
