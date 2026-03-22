import Foundation

enum DJBackendError: LocalizedError {
    case invalidBaseURL(String)
    case invalidAudioURL(String)
    case invalidResponse
    case plannerUnavailable
    case badStatusCode(Int, String)
    case missingAudioData

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let value):
            return "Backend URL 無效：\(value)"
        case .invalidAudioURL(let value):
            return "後端回傳咗無效音檔網址：\(value)"
        case .invalidResponse:
            return "後端回應格式有問題。"
        case .plannerUnavailable:
            return "後端未提供 DJ 節目規劃 API。"
        case .badStatusCode(let code, let message):
            return "後端回傳 \(code)：\(message)"
        case .missingAudioData:
            return "後端冇回傳音檔資料。"
        }
    }
}

struct DJBackendClient {
    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 900
        session = URLSession(configuration: configuration)

        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    func fetchConfig(baseURLString: String) async throws -> BackendConfig {
        let baseURL = try normalizedBaseURL(from: baseURLString)
        let configURL = baseURL.appending(path: "api/v1/config")
        let (data, response) = try await session.data(from: configURL)
        try validate(response: response, data: data)
        return try decoder.decode(BackendConfig.self, from: data)
    }

    func fetchProgramDraft(
        baseURLString: String,
        transcript: String,
        hostStyle: String,
        desiredSongCount: Int
    ) async throws -> RadioShowDraft {
        let baseURL = try normalizedBaseURL(from: baseURLString)
        let endpoint = baseURL.appending(path: "api/v1/dj-program")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(
            DJProgramRequestBody(
                transcript: transcript,
                hostStyle: hostStyle,
                desiredSongCount: desiredSongCount
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DJBackendError.invalidResponse
        }

        if httpResponse.statusCode == 404 {
            throw DJBackendError.plannerUnavailable
        }

        try validate(response: response, data: data)
        let decoded = try decoder.decode(DJProgramResponse.self, from: data)
        return RadioShowDraft(
            showTitle: decoded.showTitle,
            moodSummary: decoded.moodSummary,
            openingMonologue: decoded.openingMonologue,
            songSuggestions: decoded.songSuggestions,
            bridgeMonologues: decoded.bridgeMonologues,
            closingMonologue: decoded.closingMonologue,
            voiceDescription: decoded.voiceDescription
        )
    }

    func synthesizeSpeech(
        baseURLString: String,
        requestBody: SpeechSynthesisRequestBody
    ) async throws -> (SpeechSynthesisResponse, URL) {
        let baseURL = try normalizedBaseURL(from: baseURLString)
        let endpoint = baseURL.appending(path: "api/v1/speech")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(requestBody)

        let (data, response) = try await session.data(for: request)
        try validate(response: response, data: data)

        let synthesized = try decoder.decode(SpeechSynthesisResponse.self, from: data)
        let audioURL = try synthesized.resolvedAudioURL(relativeTo: baseURL)
        let localFileURL = try await downloadAudio(from: audioURL, suggestedName: synthesized.filename)
        return (synthesized, localFileURL)
    }

    private func downloadAudio(from url: URL, suggestedName: String) async throws -> URL {
        let (data, response) = try await session.data(from: url)
        try validate(response: response, data: data)

        guard !data.isEmpty else {
            throw DJBackendError.missingAudioData
        }

        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(UUID().uuidString)-\(suggestedName)"
        )
        try data.write(to: tempURL, options: .atomic)
        return tempURL
    }

    private func normalizedBaseURL(from value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw DJBackendError.invalidBaseURL(value)
        }

        let candidate = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let url = URL(string: candidate) else {
            throw DJBackendError.invalidBaseURL(value)
        }

        return url.hasDirectoryPath ? url : url.appending(path: "")
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw DJBackendError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            let message = (try? decoder.decode(BackendErrorEnvelope.self, from: data).error)
                ?? HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            throw DJBackendError.badStatusCode(httpResponse.statusCode, message)
        }
    }
}
