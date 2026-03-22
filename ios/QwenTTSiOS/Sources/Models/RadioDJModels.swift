import Foundation
import MusicKit

enum SongCategoryOption: String, Codable, CaseIterable, Identifiable {
    case cantonese
    case mandarin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cantonese:
            return "廣東歌"
        case .mandarin:
            return "華語歌"
        }
    }

    var detail: String {
        switch self {
        case .cantonese:
            return "以廣東話流行曲為主"
        case .mandarin:
            return "以普通話流行曲為主"
        }
    }
}

enum SongEraOption: Int, Codable, CaseIterable, Identifiable {
    case seventies = 1970
    case eighties = 1980
    case nineties = 1990
    case twoThousands = 2000
    case modern = 2010

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .seventies:
            return "70年代"
        case .eighties:
            return "80年代"
        case .nineties:
            return "90年代"
        case .twoThousands:
            return "00年代"
        case .modern:
            return "現代"
        }
    }

    var shortTitle: String {
        switch self {
        case .seventies:
            return "70s"
        case .eighties:
            return "80s"
        case .nineties:
            return "90s"
        case .twoThousands:
            return "00s"
        case .modern:
            return "Now"
        }
    }
}

struct ProgramSongPreferences: Codable, Hashable {
    let songCategory: SongCategoryOption
    let eraRangeStart: SongEraOption
    let eraRangeEnd: SongEraOption

    var eraSummary: String {
        if eraRangeStart == eraRangeEnd {
            return eraRangeStart.title
        }
        return "\(eraRangeStart.title) - \(eraRangeEnd.title)"
    }
}

struct VoicePreset: Decodable, Hashable, Identifiable {
    let id: String
    let label: String
    let voiceDescription: String

    enum CodingKeys: String, CodingKey {
        case id
        case label
        case voiceDescription = "description"
    }
}

extension VoicePreset {
    static let defaultPresetID = "ai_zhengziseng"

    static let fallbackPresets: [VoicePreset] = [
        VoicePreset(
            id: "ai_zhengziseng",
            label: "AI 鄭子誠",
            voiceDescription: "一把成熟、溫柔、帶少少磁性嘅香港深夜男 DJ 聲線，說話節奏從容，情感細膩，像在凌晨電台陪伴失眠聽眾，廣東話口吻自然，帶感性而不誇張的陪伴感。"
        ),
        VoicePreset(
            id: "warm_cantonese_male",
            label: "溫柔廣東話男聲",
            voiceDescription: "一把溫暖、自然、親切嘅廣東話男聲，咬字清楚，語氣放鬆，像深夜節目主持同你慢慢傾偈。"
        ),
        VoicePreset(
            id: "gentle_cantonese_female",
            label: "細膩廣東話女聲",
            voiceDescription: "一把柔和、細膩、帶陪伴感嘅廣東話女聲，聲線清新但唔幼嫩，語氣溫柔而穩定。"
        ),
        VoicePreset(
            id: "studio_putonghua_female",
            label: "普通話女主持",
            voiceDescription: "A polished Mandarin female host voice with a warm broadcast tone, clear articulation, and a calm late-night radio presence."
        ),
        VoicePreset(
            id: "bright_english_male",
            label: "English Presenter",
            voiceDescription: "A bright, trustworthy male presenter voice with polished studio diction, steady pacing, and an approachable radio feel."
        ),
    ]
}

struct BackendConfig: Decodable {
    let model: String
    let languages: [String]
    let outputFormat: String
    let voicePresets: [VoicePreset]

    enum CodingKeys: String, CodingKey {
        case model
        case languages
        case outputFormat = "output_format"
        case voicePresets = "voice_presets"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        model = try container.decode(String.self, forKey: .model)
        languages = try container.decode([String].self, forKey: .languages)
        outputFormat = try container.decode(String.self, forKey: .outputFormat)
        voicePresets = try container.decodeIfPresent([VoicePreset].self, forKey: .voicePresets) ?? []
    }
}

struct SpeechSynthesisRequestBody: Codable {
    let text: String
    let voiceDescription: String
    let language: String
    let temperature: Double
    let topK: Int
    let topP: Double
    let repetitionPenalty: Double
    let maxTokens: Int

    enum CodingKeys: String, CodingKey {
        case text
        case voiceDescription = "voice_description"
        case language
        case temperature
        case topK = "top_k"
        case topP = "top_p"
        case repetitionPenalty = "repetition_penalty"
        case maxTokens = "max_tokens"
    }
}

struct SpeechSynthesisResponse: Codable, Identifiable {
    let id: String
    let filename: String
    let sampleRate: Int
    let sampleCount: Int
    let durationSeconds: Double
    let createdAt: String
    let model: String
    let request: SpeechSynthesisRequestBody
    let audioURL: String
    let downloadURL: String

    enum CodingKeys: String, CodingKey {
        case id
        case filename
        case sampleRate = "sample_rate"
        case sampleCount = "sample_count"
        case durationSeconds = "duration_seconds"
        case createdAt = "created_at"
        case model
        case request
        case audioURL = "audio_url"
        case downloadURL = "download_url"
    }

    func resolvedAudioURL(relativeTo baseURL: URL) throws -> URL {
        if let absoluteURL = URL(string: audioURL), absoluteURL.scheme != nil {
            return absoluteURL
        }

        guard let resolvedURL = URL(string: audioURL, relativeTo: baseURL)?.absoluteURL else {
            throw DJBackendError.invalidAudioURL(audioURL)
        }
        return resolvedURL
    }
}

struct DJProgramRequestBody: Codable {
    let transcript: String
    let hostStyle: String
    let desiredSongCount: Int
    let songCategory: SongCategoryOption
    let eraRangeStart: Int
    let eraRangeEnd: Int

    enum CodingKeys: String, CodingKey {
        case transcript
        case hostStyle = "host_style"
        case desiredSongCount = "desired_song_count"
        case songCategory = "song_category"
        case eraRangeStart = "era_range_start"
        case eraRangeEnd = "era_range_end"
    }
}

struct DJProgramResponse: Codable {
    let showTitle: String
    let moodSummary: String
    let openingMonologue: String
    let songSuggestions: [SongSuggestion]
    let bridgeMonologues: [BridgeMonologue]
    let closingMonologue: String
    let voiceDescription: String
}

struct SongSuggestion: Codable, Hashable, Identifiable {
    let id: UUID
    let titleHint: String
    let artistHint: String
    let searchQuery: String
    let reason: String

    init(
        id: UUID = UUID(),
        titleHint: String,
        artistHint: String,
        searchQuery: String,
        reason: String
    ) {
        self.id = id
        self.titleHint = titleHint
        self.artistHint = artistHint
        self.searchQuery = searchQuery
        self.reason = reason
    }

    enum CodingKeys: String, CodingKey {
        case id
        case titleHint
        case artistHint
        case searchQuery
        case reason
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        titleHint = try container.decode(String.self, forKey: .titleHint)
        artistHint = try container.decode(String.self, forKey: .artistHint)
        searchQuery = try container.decode(String.self, forKey: .searchQuery)
        reason = try container.decode(String.self, forKey: .reason)
    }
}

struct BridgeMonologue: Codable, Hashable, Identifiable {
    let id: UUID
    let afterSongIndex: Int
    let text: String

    init(id: UUID = UUID(), afterSongIndex: Int, text: String) {
        self.id = id
        self.afterSongIndex = afterSongIndex
        self.text = text
    }

    enum CodingKeys: String, CodingKey {
        case id
        case afterSongIndex
        case text
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        afterSongIndex = try container.decode(Int.self, forKey: .afterSongIndex)
        text = try container.decode(String.self, forKey: .text)
    }
}

struct RadioShowDraft: Codable, Hashable {
    let showTitle: String
    let moodSummary: String
    let openingMonologue: String
    let songSuggestions: [SongSuggestion]
    let bridgeMonologues: [BridgeMonologue]
    let closingMonologue: String
    let voiceDescription: String
}

struct ResolvedSong: Identifiable, Hashable {
    let id: MusicItemID
    let suggestion: SongSuggestion
    let song: Song

    var title: String { song.title }
    var artistName: String { song.artistName }
    var albumTitle: String { song.albumTitle ?? "Apple Music" }
    var durationText: String {
        guard let duration = song.duration else { return "--:--" }
        let total = Int(duration.rounded())
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

struct SpokenClip: Identifiable, Hashable {
    enum Kind: String, Codable, Hashable {
        case opening
        case bridge
        case closing
    }

    let id: UUID
    let kind: Kind
    let title: String
    let text: String
    let localFileURL: URL
    let response: SpeechSynthesisResponse

    init(
        id: UUID = UUID(),
        kind: Kind,
        title: String,
        text: String,
        localFileURL: URL,
        response: SpeechSynthesisResponse
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.text = text
        self.localFileURL = localFileURL
        self.response = response
    }

    static func == (lhs: SpokenClip, rhs: SpokenClip) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

struct RadioShow: Hashable {
    let title: String
    let moodSummary: String
    let transcript: String
    let voiceDescription: String
    let songs: [ResolvedSong]
    let playbackItems: [StationPlaybackItem]

    var openingItem: StationPlaybackItem? {
        playbackItems.first(where: { $0.kind == .opening })
    }

    var playlistItems: [StationPlaybackItem] {
        playbackItems.filter { $0.kind == .song || $0.kind == .bridge }
    }

    var closingItem: StationPlaybackItem? {
        playbackItems.first(where: { $0.kind == .closing })
    }
}

struct StationPlaybackItem: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case opening
        case song
        case bridge
        case closing
    }

    enum Payload: Hashable {
        case speech(SpokenClip)
        case song(ResolvedSong)
    }

    let id: UUID
    let queueKey: String
    let kind: Kind
    let title: String
    let subtitle: String
    let payload: Payload

    init(
        id: UUID = UUID(),
        queueKey: String,
        kind: Kind,
        title: String,
        subtitle: String,
        payload: Payload
    ) {
        self.id = id
        self.queueKey = queueKey
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.payload = payload
    }

    var spokenClip: SpokenClip? {
        if case .speech(let clip) = payload { return clip }
        return nil
    }

    var resolvedSong: ResolvedSong? {
        if case .song(let song) = payload { return song }
        return nil
    }

    var bridgeText: String? {
        guard kind == .bridge else { return nil }
        return spokenClip?.text
    }

    var durationSeconds: Double {
        switch payload {
        case .speech(let clip):
            return clip.response.durationSeconds
        case .song(let song):
            return song.song.duration ?? 0
        }
    }
}

struct BackendErrorEnvelope: Decodable {
    let error: String
}
