import Combine
import Foundation

@MainActor
final class RadioDJViewModel: ObservableObject {
    @Published var serverURL: String
    @Published var transcriptText: String
    @Published var shouldCachePrograms: Bool {
        didSet {
            defaults.set(shouldCachePrograms, forKey: DefaultsKey.shouldCachePrograms)
        }
    }
    @Published var hostStyleDescription: String {
        didSet {
            defaults.set(hostStyleDescription, forKey: DefaultsKey.hostStyleDescription)
        }
    }
    @Published var selectedVoicePresetID: String {
        didSet {
            guard oldValue != selectedVoicePresetID else { return }
            applySelectedVoicePreset()
        }
    }
    @Published private(set) var availableLanguages: [String]
    @Published private(set) var availableVoicePresets: [VoicePreset]
    @Published private(set) var backendModelName: String
    @Published private(set) var currentShow: RadioShow?
    @Published private(set) var isRefreshingConfig = false
    @Published private(set) var isRecording = false
    @Published private(set) var isPreparingShow = false
    @Published private(set) var isGeneratingRemainingSpeech = false
    @Published private(set) var isPlaying = false
    @Published private(set) var currentPlaybackItem: StationPlaybackItem?
    @Published private(set) var statusMessage = "準備好之後，你可以錄音、編排節目，再一路聽住 intro、歌同獨白播出。"
    @Published var alertMessage: String?

    private let backendClient: DJBackendClient
    private let planner: RadioShowPlanning
    private let musicCatalogService: AppleMusicCatalogService
    private let speechCaptureService: SpeechCaptureService
    private let playbackCoordinator: StationPlaybackCoordinator
    private let cacheStore: DJProgramCacheStore
    private let defaults: UserDefaults
    private var didBootstrap = false
    private var cancellables = Set<AnyCancellable>()
    private var backgroundSpeechTask: Task<Void, Never>?

    private enum DraftSource {
        case backend
        case foundationModels
        case ruleBased
    }

    private struct SelectedDraftBundle {
        let draft: RadioShowDraft
        let resolvedSongs: [ResolvedSong]
        let source: DraftSource
    }

    private struct SpeechPlanItem {
        let cacheKey: String
        let title: String
        let kind: SpokenClip.Kind
        let text: String
        let subtitle: String
    }

    private enum DefaultsKey {
        static let serverURL = "ai.dj.serverURL"
        static let shouldCachePrograms = "ai.dj.shouldCachePrograms"
        static let selectedVoicePresetID = "ai.dj.selectedVoicePresetID"
        static let hostStyleDescription = "ai.dj.hostStyleDescription"
    }

    init(
        backendClient: DJBackendClient = DJBackendClient(),
        planner: RadioShowPlanning = LocalFallbackRadioShowPlanner(),
        musicCatalogService: AppleMusicCatalogService = AppleMusicCatalogService(),
        speechCaptureService: SpeechCaptureService = SpeechCaptureService(),
        playbackCoordinator: StationPlaybackCoordinator = StationPlaybackCoordinator(),
        cacheStore: DJProgramCacheStore = DJProgramCacheStore()
    ) {
        self.backendClient = backendClient
        self.planner = planner
        self.musicCatalogService = musicCatalogService
        self.speechCaptureService = speechCaptureService
        self.playbackCoordinator = playbackCoordinator
        self.cacheStore = cacheStore
        self.defaults = UserDefaults.standard
        self.serverURL = defaults.string(forKey: DefaultsKey.serverURL) ?? "http://127.0.0.1:8000"
        self.transcriptText = "最近好掛住以前拍拖嗰陣，明知唔應該回頭，但仲係會諗起對方。"
        if defaults.object(forKey: DefaultsKey.shouldCachePrograms) == nil {
            self.shouldCachePrograms = true
        } else {
            self.shouldCachePrograms = defaults.bool(forKey: DefaultsKey.shouldCachePrograms)
        }
        self.availableVoicePresets = VoicePreset.fallbackPresets
        let savedPresetID = defaults.string(forKey: DefaultsKey.selectedVoicePresetID) ?? VoicePreset.defaultPresetID
        self.selectedVoicePresetID = savedPresetID
        let savedStyle = defaults.string(forKey: DefaultsKey.hostStyleDescription)
        self.hostStyleDescription = savedStyle ?? Self.voiceDescription(for: savedPresetID, in: VoicePreset.fallbackPresets)
        self.availableLanguages = ["Chinese", "English"]
        self.backendModelName = "mlx-community/Qwen3-TTS-12Hz-1.7B-VoiceDesign-bf16"

        playbackCoordinator.$currentItem
            .receive(on: RunLoop.main)
            .sink { [weak self] item in
                self?.currentPlaybackItem = item
            }
            .store(in: &cancellables)

        playbackCoordinator.$isPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] playing in
                self?.isPlaying = playing
            }
            .store(in: &cancellables)
    }

    func bootstrapIfNeeded() async {
        guard !didBootstrap else { return }
        didBootstrap = true
        await refreshBackendConfig()
    }

    func refreshBackendConfig() async {
        isRefreshingConfig = true
        defer { isRefreshingConfig = false }

        do {
            persistServerURL()
            let config = try await backendClient.fetchConfig(baseURLString: serverURL)
            backendModelName = config.model
            if !config.languages.isEmpty {
                availableLanguages = config.languages
            }
            syncVoicePresets(from: config)
            statusMessage = "已連線到 Qwen TTS backend，可以開始製作節目。"
        } catch {
            alertMessage = error.localizedDescription
            statusMessage = "未能連接 backend，但仍可用本地原型 planner 編排節目。"
        }
    }

    func toggleRecording() async {
        if isRecording {
            await finishRecording()
        } else {
            await beginRecording()
        }
    }

    func prepareShow() async {
        let trimmedTranscript = transcriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTranscript.isEmpty else {
            alertMessage = "請先輸入內容，或者按住錄音講幾句。"
            return
        }

        backgroundSpeechTask?.cancel()
        backgroundSpeechTask = nil
        isGeneratingRemainingSpeech = false
        isPreparingShow = true
        statusMessage = "正在為你整理歌單同節目內容。"
        defer { isPreparingShow = false }

        do {
            persistServerURL()
            let cacheSignature = shouldCachePrograms
                ? cacheStore.signature(
                    transcript: trimmedTranscript,
                    hostStyleDescription: hostStyleDescription,
                    desiredSongCount: 8,
                    serverURL: serverURL,
                    modelName: backendModelName
                )
                : nil

            let cachedBundle: CachedShowBundle?
            if let cacheSignature {
                cachedBundle = try cacheStore.loadBundle(signature: cacheSignature)
            } else {
                cachedBundle = nil
            }
            var draft: RadioShowDraft
            var cachedClips: [String: SpokenClip]
            let resolvedSongs: [ResolvedSong]

            if let cachedBundle {
                draft = cachedBundle.draft
                cachedClips = cachedBundle.clipsByKey
                statusMessage = "已找到上次保存嘅節目稿同聲音，直接重用。"

                do {
                    resolvedSongs = try await musicCatalogService.resolveSuggestions(draft.songSuggestions)
                } catch {
                    let selectedDraft = try await selectDraftBundle(
                        transcript: trimmedTranscript,
                        hostStyleDescription: hostStyleDescription
                    )
                    draft = selectedDraft.draft
                    cachedClips = [:]
                    resolvedSongs = selectedDraft.resolvedSongs
                    statusMessage = message(for: selectedDraft.source)
                }
            } else {
                let selectedDraft = try await selectDraftBundle(
                    transcript: trimmedTranscript,
                    hostStyleDescription: hostStyleDescription
                )
                draft = selectedDraft.draft
                cachedClips = [:]
                resolvedSongs = selectedDraft.resolvedSongs
                statusMessage = message(for: selectedDraft.source)
            }

            statusMessage = cachedClips.isEmpty
                ? "已找到 \(resolvedSongs.count) 首 Apple Music 歌曲，先準備可即時播放嘅獨白。"
                : "已找到 \(resolvedSongs.count) 首 Apple Music 歌曲，先檢查可重用嘅獨白。"

            let speechPlan = speechPlanItems(draft: draft, resolvedSongs: resolvedSongs)
            let initialSpeechPlan = Array(speechPlan.prefix(3))
            var generatedNewClip = false

            for item in initialSpeechPlan {
                let clip = try await clip(
                    for: item.cacheKey,
                    title: item.title,
                    kind: item.kind,
                    text: item.text,
                    voiceDescription: draft.voiceDescription,
                    clipsByKey: &cachedClips,
                    generatedNewClip: &generatedNewClip
                )
                cachedClips[item.cacheKey] = clip
            }

            let initialShow = buildShow(
                draft: draft,
                resolvedSongs: resolvedSongs,
                transcript: trimmedTranscript,
                clipsByKey: cachedClips
            )
            currentShow = initialShow

            if shouldCachePrograms, let cacheSignature {
                _ = try cacheStore.saveBundle(
                    signature: cacheSignature,
                    draft: draft,
                    clipsByKey: cachedClips
                )
            }

            try await playbackCoordinator.loadAndPlay(initialShow.playbackItems)

            let remainingSpeechPlan = Array(speechPlan.dropFirst(initialSpeechPlan.count)).filter {
                !isUsableCachedClip(
                    cachedClips[$0.cacheKey],
                    title: $0.title,
                    kind: $0.kind,
                    text: $0.text
                )
            }

            if !remainingSpeechPlan.isEmpty {
                isGeneratingRemainingSpeech = true
                statusMessage = "節目已開始播放，餘下獨白會繼續生成。"
                backgroundSpeechTask = Task { [weak self] in
                    guard let self else { return }
                    await self.generateRemainingSpeech(
                        remainingSpeechPlan,
                        draft: draft,
                        resolvedSongs: resolvedSongs,
                        transcript: trimmedTranscript,
                        cacheSignature: cacheSignature,
                        clipsByKey: cachedClips
                    )
                }
            } else {
                statusMessage = generatedNewClip
                    ? "節目已準備完成，開始播放。"
                    : "節目已從本地保存內容載入，開始播放。"
            }
        } catch {
            alertMessage = error.localizedDescription
            statusMessage = "未能完成今集節目。"
        }
    }

    private func selectDraftBundle(
        transcript: String,
        hostStyleDescription: String
    ) async throws -> SelectedDraftBundle {
        do {
            print("try backend program")
            let backendDraft = try await backendClient.fetchProgramDraft(
                baseURLString: serverURL,
                transcript: transcript,
                hostStyle: hostStyleDescription,
                desiredSongCount: 8
            )
            let songs = try await musicCatalogService.resolveSuggestions(backendDraft.songSuggestions)
            return SelectedDraftBundle(
                draft: backendDraft,
                resolvedSongs: songs,
                source: .backend
            )
        } catch {
            print("try fallback program")
            var lastError: Error = error

            for plannedDraft in await planner.fallbackDrafts(
                from: transcript,
                voiceDescription: hostStyleDescription
            ) {
                do {
                    let songs = try await musicCatalogService.resolveSuggestions(
                        plannedDraft.draft.songSuggestions
                    )
                    return SelectedDraftBundle(
                        draft: plannedDraft.draft,
                        resolvedSongs: songs,
                        source: plannedDraft.source == .foundationModels
                            ? .foundationModels
                            : .ruleBased
                    )
                } catch {
                    lastError = error
                }
            }

            throw lastError
        }
    }

    private func message(for source: DraftSource) -> String {
        switch source {
        case .backend:
            return "已由 backend 生成節目文案同歌曲 hints，並成功由 iOS 搜尋 Apple Music。"
        case .foundationModels:
            return "backend 節目稿未能生成可播歌單，已改用 Apple Foundation Models 生成節目。"
        case .ruleBased:
            return "backend 同 Foundation Models 都未能生成可播歌單，已改用 app 內建 rule-based 節目。"
        }
    }

    func togglePlayback() async {
        await playbackCoordinator.togglePlayback()
    }

    func skipToNextSong() async {
        await playbackCoordinator.skipToNextSong()
    }

    func skipToPreviousSong() async {
        await playbackCoordinator.skipToPreviousSong()
    }

    func playPlaybackItem(_ item: StationPlaybackItem) async {
        do {
            try await playbackCoordinator.playItem(withID: item.id)
            statusMessage = "正在播放：\(item.title)"
        } catch {
            alertMessage = error.localizedDescription
            statusMessage = "未能播放所選段落。"
        }
    }

    func stopPlayback() {
        backgroundSpeechTask?.cancel()
        backgroundSpeechTask = nil
        isGeneratingRemainingSpeech = false
        playbackCoordinator.stop()
        statusMessage = "已停止播放。"
    }

    private func beginRecording() async {
        do {
            statusMessage = "錄音中，講完再按一次停止。"
            try await speechCaptureService.startRecording()
            isRecording = true
        } catch {
            alertMessage = error.localizedDescription
            statusMessage = "未能開始錄音。"
        }
    }

    private func finishRecording() async {
        do {
            statusMessage = "錄音完成，正用 Speech Analyzer 轉成文字。"
            let transcript = try await speechCaptureService.stopRecordingAndTranscribe()
            transcriptText = transcript
            isRecording = false
            statusMessage = "已將語音轉成文字，你可以再修改內容後編排節目。"
        } catch {
            isRecording = false
            alertMessage = error.localizedDescription
            statusMessage = "錄音已停止，但未能轉成文字。"
        }
    }

    private func clip(
        for cacheKey: String,
        title: String,
        kind: SpokenClip.Kind,
        text: String,
        voiceDescription: String,
        clipsByKey: inout [String: SpokenClip],
        generatedNewClip: inout Bool
    ) async throws -> SpokenClip {
        if let cached = clipsByKey[cacheKey],
           cached.text == text,
           cached.kind == kind,
           cached.title == title {
            return cached
        }

        let generated = try await generateClip(
            text: text,
            title: title,
            kind: kind,
            voiceDescription: voiceDescription
        )
        clipsByKey[cacheKey] = generated
        generatedNewClip = true
        return generated
    }

    private func generateClip(
        text: String,
        title: String,
        kind: SpokenClip.Kind,
        voiceDescription: String
    ) async throws -> SpokenClip {
        let request = SpeechSynthesisRequestBody(
            text: text,
            voiceDescription: voiceDescription,
            language: "Chinese",
            temperature: 0.7,
            topK: 50,
            topP: 1.0,
            repetitionPenalty: 1.05,
            maxTokens: 2048
        )

        let (response, localFileURL) = try await backendClient.synthesizeSpeech(
            baseURLString: serverURL,
            requestBody: request
        )

        return SpokenClip(
            kind: kind,
            title: title,
            text: text,
            localFileURL: localFileURL,
            response: response
        )
    }

    private func speechPlanItems(
        draft: RadioShowDraft,
        resolvedSongs: [ResolvedSong]
    ) -> [SpeechPlanItem] {
        var items = [
            SpeechPlanItem(
                cacheKey: "opening",
                title: "開場白",
                kind: .opening,
                text: draft.openingMonologue,
                subtitle: draft.showTitle
            )
        ]

        let bridgeLookup = Dictionary(
            uniqueKeysWithValues: draft.bridgeMonologues.map { ($0.afterSongIndex, $0) }
        )

        for index in resolvedSongs.indices {
            if let bridge = bridgeLookup[index] {
                items.append(
                    SpeechPlanItem(
                        cacheKey: "bridge-\(index)",
                        title: "感性獨白 \(index + 1)",
                        kind: .bridge,
                        text: bridge.text,
                        subtitle: "AI 鄭子誠"
                    )
                )
            }
        }

        items.append(
            SpeechPlanItem(
                cacheKey: "closing",
                title: "收場白",
                kind: .closing,
                text: draft.closingMonologue,
                subtitle: "AI 鄭子誠"
            )
        )

        return items
    }

    private func buildShow(
        draft: RadioShowDraft,
        resolvedSongs: [ResolvedSong],
        transcript: String,
        clipsByKey: [String: SpokenClip]
    ) -> RadioShow {
        let bridgeLookup = Dictionary(
            uniqueKeysWithValues: draft.bridgeMonologues.map { ($0.afterSongIndex, $0) }
        )

        var items: [StationPlaybackItem] = []

        if let openingClip = clipsByKey["opening"] {
            items.append(
                StationPlaybackItem(
                    queueKey: "opening",
                    kind: .opening,
                    title: openingClip.title,
                    subtitle: draft.showTitle,
                    payload: .speech(openingClip)
                )
            )
        }

        for (index, song) in resolvedSongs.enumerated() {
            items.append(
                StationPlaybackItem(
                    queueKey: "song-\(String(describing: song.id))",
                    kind: .song,
                    title: song.title,
                    subtitle: song.artistName,
                    payload: .song(song)
                )
            )

            if bridgeLookup[index] != nil, let clip = clipsByKey["bridge-\(index)"] {
                items.append(
                    StationPlaybackItem(
                        queueKey: "bridge-\(index)",
                        kind: .bridge,
                        title: clip.title,
                        subtitle: "AI 鄭子誠",
                        payload: .speech(clip)
                    )
                )
            }
        }

        if let closingClip = clipsByKey["closing"] {
            items.append(
                StationPlaybackItem(
                    queueKey: "closing",
                    kind: .closing,
                    title: closingClip.title,
                    subtitle: "AI 鄭子誠",
                    payload: .speech(closingClip)
                )
            )
        }

        return RadioShow(
            title: draft.showTitle,
            moodSummary: draft.moodSummary,
            transcript: transcript,
            voiceDescription: draft.voiceDescription,
            songs: resolvedSongs,
            playbackItems: items
        )
    }

    private func generateRemainingSpeech(
        _ remainingSpeechPlan: [SpeechPlanItem],
        draft: RadioShowDraft,
        resolvedSongs: [ResolvedSong],
        transcript: String,
        cacheSignature: String?,
        clipsByKey initialClipsByKey: [String: SpokenClip]
    ) async {
        var clipsByKey = initialClipsByKey
        var generatedNewClip = false
        var failedCount = 0

        for item in remainingSpeechPlan {
            guard !Task.isCancelled else { return }

            do {
                let clip = try await clip(
                    for: item.cacheKey,
                    title: item.title,
                    kind: item.kind,
                    text: item.text,
                    voiceDescription: draft.voiceDescription,
                    clipsByKey: &clipsByKey,
                    generatedNewClip: &generatedNewClip
                )
                clipsByKey[item.cacheKey] = clip

                let updatedShow = buildShow(
                    draft: draft,
                    resolvedSongs: resolvedSongs,
                    transcript: transcript,
                    clipsByKey: clipsByKey
                )
                currentShow = updatedShow
                playbackCoordinator.updatePlaybackItems(updatedShow.playbackItems)
            } catch {
                failedCount += 1
            }
        }

        if generatedNewClip, shouldCachePrograms, let cacheSignature {
            do {
                _ = try cacheStore.saveBundle(
                    signature: cacheSignature,
                    draft: draft,
                    clipsByKey: clipsByKey
                )
            } catch {
                alertMessage = error.localizedDescription
            }
        }

        isGeneratingRemainingSpeech = false
        backgroundSpeechTask = nil
        if failedCount > 0 {
            statusMessage = "節目已播放中，部分獨白未能及時生成。"
        } else {
            statusMessage = "節目所有獨白已準備完成。"
        }
    }

    private func isUsableCachedClip(
        _ cachedClip: SpokenClip?,
        title: String,
        kind: SpokenClip.Kind,
        text: String
    ) -> Bool {
        guard let cachedClip else { return false }
        return cachedClip.text == text
            && cachedClip.kind == kind
            && cachedClip.title == title
    }

    private func persistServerURL() {
        defaults.set(serverURL.trimmingCharacters(in: .whitespacesAndNewlines), forKey: DefaultsKey.serverURL)
    }

    private func syncVoicePresets(from config: BackendConfig) {
        let previousDescription = selectedVoicePreset?.voiceDescription
        if !config.voicePresets.isEmpty {
            availableVoicePresets = config.voicePresets
        }

        if !availableVoicePresets.contains(where: { $0.id == selectedVoicePresetID }) {
            selectedVoicePresetID = availableVoicePresets.first?.id ?? VoicePreset.defaultPresetID
            return
        }

        if let updatedDescription = selectedVoicePreset?.voiceDescription,
           hostStyleDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hostStyleDescription == previousDescription {
            hostStyleDescription = updatedDescription
        }
    }

    private func applySelectedVoicePreset() {
        defaults.set(selectedVoicePresetID, forKey: DefaultsKey.selectedVoicePresetID)
        guard let preset = selectedVoicePreset else { return }
        hostStyleDescription = preset.voiceDescription
    }

    private var selectedVoicePreset: VoicePreset? {
        availableVoicePresets.first(where: { $0.id == selectedVoicePresetID })
    }

    private static func voiceDescription(for presetID: String, in presets: [VoicePreset]) -> String {
        presets.first(where: { $0.id == presetID })?.voiceDescription
            ?? PrototypeShowPlanner.defaultVoiceDescription
    }
}
