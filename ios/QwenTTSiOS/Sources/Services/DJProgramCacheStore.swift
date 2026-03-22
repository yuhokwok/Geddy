import CryptoKit
import Foundation

struct CachedShowBundle {
    let signature: String
    let transcript: String
    let draft: RadioShowDraft
    let clipsByKey: [String: SpokenClip]
}

struct SavedProgramSummary: Identifiable, Hashable {
    let signature: String
    let title: String
    let moodSummary: String
    let transcriptPreview: String
    let savedAt: Date
    let songCount: Int

    var id: String { signature }
}

final class DJProgramCacheStore {
    private let fileManager: FileManager
    private let baseDirectoryURL: URL

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
        let appSupport = try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = appSupport ?? fileManager.temporaryDirectory
        baseDirectoryURL = root.appendingPathComponent("AIZhengZiSeng/ProgramCache", isDirectory: true)
        try? fileManager.createDirectory(at: baseDirectoryURL, withIntermediateDirectories: true)
    }

    func signature(
        transcript: String,
        hostStyleDescription: String,
        desiredSongCount: Int,
        serverURL: String,
        modelName: String,
        songPreferences: ProgramSongPreferences
    ) -> String {
        let payload = [
            transcript.trimmingCharacters(in: .whitespacesAndNewlines),
            hostStyleDescription.trimmingCharacters(in: .whitespacesAndNewlines),
            String(desiredSongCount),
            serverURL.trimmingCharacters(in: .whitespacesAndNewlines),
            modelName.trimmingCharacters(in: .whitespacesAndNewlines),
            songPreferences.songCategory.rawValue,
            String(songPreferences.eraRangeStart.rawValue),
            String(songPreferences.eraRangeEnd.rawValue),
            songPreferences.preferObscureSongs ? "prefer-obscure" : "standard-mix",
        ].joined(separator: "\n---\n")

        let digest = SHA256.hash(data: Data(payload.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func loadBundle(signature: String) throws -> CachedShowBundle? {
        let directoryURL = directoryURL(for: signature)
        let manifestURL = directoryURL.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else { return nil }

        let data = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder.cacheStoreDecoder.decode(CachedShowManifest.self, from: data)

        var clipsByKey: [String: SpokenClip] = [:]
        for clipRecord in manifest.clips {
            let fileURL = directoryURL.appendingPathComponent(clipRecord.filename)
            guard fileManager.fileExists(atPath: fileURL.path) else {
                return nil
            }

            clipsByKey[clipRecord.cacheKey] = SpokenClip(
                kind: clipRecord.kind,
                title: clipRecord.title,
                text: clipRecord.text,
                localFileURL: fileURL,
                response: clipRecord.response
            )
        }

        return CachedShowBundle(
            signature: manifest.signature ?? signature,
            transcript: manifest.transcript,
            draft: manifest.draft,
            clipsByKey: clipsByKey
        )
    }

    func saveBundle(
        signature: String,
        transcript: String,
        draft: RadioShowDraft,
        clipsByKey: [String: SpokenClip]
    ) throws -> CachedShowBundle {
        let directoryURL = directoryURL(for: signature)
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let clipRecords = try clipsByKey
            .sorted(by: { $0.key < $1.key })
            .map { cacheKey, clip in
                let destinationURL = directoryURL.appendingPathComponent(clip.response.filename)
                if clip.localFileURL.standardizedFileURL != destinationURL.standardizedFileURL {
                    if fileManager.fileExists(atPath: destinationURL.path) {
                        try fileManager.removeItem(at: destinationURL)
                    }
                    try fileManager.copyItem(at: clip.localFileURL, to: destinationURL)
                }

                return CachedClipRecord(
                    cacheKey: cacheKey,
                    kind: clip.kind,
                    title: clip.title,
                    text: clip.text,
                    filename: clip.response.filename,
                    response: clip.response
                )
            }

        let manifest = CachedShowManifest(
            signature: signature,
            transcript: transcript,
            savedAt: Date(),
            draft: draft,
            clips: clipRecords
        )
        let manifestURL = directoryURL.appendingPathComponent("manifest.json")
        let manifestData = try JSONEncoder.prettyPrinted.encode(manifest)
        try manifestData.write(to: manifestURL, options: .atomic)

        guard let bundle = try loadBundle(signature: signature) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return bundle
    }

    func listSavedPrograms() throws -> [SavedProgramSummary] {
        let directoryURLs = try fileManager.contentsOfDirectory(
            at: baseDirectoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        var summaries: [SavedProgramSummary] = []
        for directoryURL in directoryURLs {
            let manifestURL = directoryURL.appendingPathComponent("manifest.json")
            guard fileManager.fileExists(atPath: manifestURL.path) else { continue }
            guard let data = try? Data(contentsOf: manifestURL) else { continue }
            guard let manifest = try? JSONDecoder.cacheStoreDecoder.decode(CachedShowManifest.self, from: data) else { continue }

            let transcriptPreview = manifest.transcript
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\n", with: " ")
            let fallbackDate = (try? directoryURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? Date.distantPast

            summaries.append(
                SavedProgramSummary(
                    signature: manifest.signature ?? directoryURL.lastPathComponent,
                    title: manifest.draft.showTitle,
                    moodSummary: manifest.draft.moodSummary,
                    transcriptPreview: String(transcriptPreview.prefix(80)),
                    savedAt: manifest.savedAt ?? fallbackDate,
                    songCount: manifest.draft.songSuggestions.count
                )
            )
        }

        return summaries.sorted { $0.savedAt > $1.savedAt }
    }

    func deleteSavedProgram(signature: String) throws {
        let directoryURL = directoryURL(for: signature)
        guard fileManager.fileExists(atPath: directoryURL.path) else { return }
        try fileManager.removeItem(at: directoryURL)
    }

    private func directoryURL(for signature: String) -> URL {
        baseDirectoryURL.appendingPathComponent(signature, isDirectory: true)
    }
}

private struct CachedShowManifest: Codable {
    let signature: String?
    let transcript: String
    let savedAt: Date?
    let draft: RadioShowDraft
    let clips: [CachedClipRecord]

    init(
        signature: String?,
        transcript: String,
        savedAt: Date?,
        draft: RadioShowDraft,
        clips: [CachedClipRecord]
    ) {
        self.signature = signature
        self.transcript = transcript
        self.savedAt = savedAt
        self.draft = draft
        self.clips = clips
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        signature = try container.decodeIfPresent(String.self, forKey: .signature)
        transcript = try container.decodeIfPresent(String.self, forKey: .transcript) ?? ""
        savedAt = try container.decodeIfPresent(Date.self, forKey: .savedAt)
        draft = try container.decode(RadioShowDraft.self, forKey: .draft)
        clips = try container.decode([CachedClipRecord].self, forKey: .clips)
    }
}

private struct CachedClipRecord: Codable {
    let cacheKey: String
    let kind: SpokenClip.Kind
    let title: String
    let text: String
    let filename: String
    let response: SpeechSynthesisResponse
}

private extension JSONEncoder {
    static var prettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var cacheStoreDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
