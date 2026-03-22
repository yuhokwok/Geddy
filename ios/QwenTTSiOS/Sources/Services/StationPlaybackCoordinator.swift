import AVFoundation
@preconcurrency import Combine
import Foundation
@preconcurrency import MediaPlayer

@MainActor
final class StationPlaybackCoordinator: NSObject, ObservableObject {
    @Published private(set) var currentItem: StationPlaybackItem?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentIndex: Int = 0
    @Published private(set) var currentPlaybackTime: TimeInterval = 0
    @Published private(set) var currentPlaybackDuration: TimeInterval = 0

    private let musicPlayer = MPMusicPlayerController.applicationQueuePlayer
    private let speechPlayer = AVQueuePlayer()
    private var playbackItems: [StationPlaybackItem] = []
    private var songItems: [StationPlaybackItem] = []
    private var speechItems: [StationPlaybackItem] = []
    private var songQueueIndexByQueueKey: [String: Int] = [:]
    private var speechQueueIndexByQueueKey: [String: Int] = [:]
    private var speechQueueKeyByPlayerItemID: [ObjectIdentifier: String] = [:]
    private var lastMusicStatus: MPMusicPlaybackState = .stopped
    private var playbackStateCancellable: AnyCancellable?
    private var nowPlayingCancellable: AnyCancellable?
    private var progressTimerCancellable: AnyCancellable?
    private var speechCompletionObserver: NSObjectProtocol?
    private var isTransitioning = false
    private var hasObservedActiveSongPlayback = false
    private var isUserPausingSong = false

    override init() {
        super.init()
        configureAudioSession()
        speechPlayer.actionAtItemEnd = .pause
        observeMusicPlayerState()
        observeSpeechQueueCompletion()
        configureRemoteCommands()
        startProgressUpdates()
        musicPlayer.beginGeneratingPlaybackNotifications()
    }

    func loadAndPlay(_ items: [StationPlaybackItem]) async throws {
        guard !items.isEmpty else { return }
        playbackItems = items
        rebuildQueueMetadata()
        currentIndex = 0
        try await playCurrentItem()
    }

    func updatePlaybackItems(_ items: [StationPlaybackItem]) {
        guard !items.isEmpty else { return }

        let currentQueueKey = currentItem?.queueKey
        playbackItems = items
        rebuildQueueMetadata()

        if let currentQueueKey,
           let updatedIndex = playbackItems.firstIndex(where: { $0.queueKey == currentQueueKey }) {
            currentIndex = updatedIndex
            currentItem = playbackItems[updatedIndex]
        } else {
            currentIndex = min(currentIndex, max(playbackItems.count - 1, 0))
            currentItem = playbackItems[currentIndex]
        }

        refreshPlaybackProgress()
    }

    func playItem(withID itemID: StationPlaybackItem.ID) async throws {
        guard let index = playbackItems.firstIndex(where: { $0.id == itemID }) else { return }
        currentIndex = index
        try await playCurrentItem()
    }

    func togglePlayback() async {
        guard let currentItem else { return }

        switch currentItem.payload {
        case .speech:
            if speechPlayer.timeControlStatus == .playing {
                speechPlayer.pause()
                isPlaying = false
            } else {
                speechPlayer.play()
                isPlaying = true
            }
        case .song:
            switch musicPlayer.playbackState {
            case .playing:
                isUserPausingSong = true
                musicPlayer.pause()
                isPlaying = false
            default:
                isUserPausingSong = false
                musicPlayer.play()
                isPlaying = true
            }
        }

        refreshPlaybackProgress()
    }

    func stop() {
        speechPlayer.pause()
        speechPlayer.removeAllItems()
        speechQueueKeyByPlayerItemID.removeAll()
        musicPlayer.stop()
        currentItem = nil
        currentIndex = 0
        isPlaying = false
        hasObservedActiveSongPlayback = false
        isUserPausingSong = false
        currentPlaybackTime = 0
        currentPlaybackDuration = 0
        MPNowPlayingInfoCenter.default().playbackState = .stopped
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func skipToNextSegment() async {
        await playSegment(at: currentIndex + 1)
    }

    func skipToPreviousSegment() async {
        await playSegment(at: currentIndex - 1)
    }

    private func rebuildQueueMetadata() {
        songItems = playbackItems.filter { $0.kind == .song }
        speechItems = playbackItems.filter { $0.kind != .song }
        songQueueIndexByQueueKey = Dictionary(
            uniqueKeysWithValues: songItems.enumerated().map { ($0.element.queueKey, $0.offset) }
        )
        speechQueueIndexByQueueKey = Dictionary(
            uniqueKeysWithValues: speechItems.enumerated().map { ($0.element.queueKey, $0.offset) }
        )
    }

    private func playCurrentItem() async throws {
        guard playbackItems.indices.contains(currentIndex) else { return }

        isTransitioning = true
        defer { isTransitioning = false }

        let item = playbackItems[currentIndex]
        currentItem = item
        currentPlaybackTime = 0
        currentPlaybackDuration = item.durationSeconds
        hasObservedActiveSongPlayback = false
        isUserPausingSong = false

        switch item.payload {
        case .speech:
            musicPlayer.pause()
            musicPlayer.stop()
            try prepareSpeechQueue(startingAt: item.queueKey)
            await speechPlayer.seek(to: .zero)
            speechPlayer.play()
            isPlaying = true
            currentPlaybackDuration = item.durationSeconds
        case .song:
            speechPlayer.pause()
            speechPlayer.removeAllItems()
            speechQueueKeyByPlayerItemID.removeAll()
            try await prepareMusicQueue(startingAt: item.queueKey)
            musicPlayer.play()
            lastMusicStatus = musicPlayer.playbackState
            isPlaying = true
            currentPlaybackDuration = item.durationSeconds
        }

        refreshPlaybackProgress()
    }

    private func prepareSpeechQueue(startingAt queueKey: String) throws {
        guard let targetIndex = speechQueueIndexByQueueKey[queueKey] else {
            throw PlaybackError.missingQueueKey(queueKey)
        }

        speechPlayer.pause()
        speechPlayer.removeAllItems()
        speechQueueKeyByPlayerItemID.removeAll()

        var previousItem: AVPlayerItem?
        for playbackItem in speechItems {
            guard let clip = playbackItem.spokenClip else {
                throw PlaybackError.invalidSpeechItem(playbackItem.title)
            }
            let playerItem = AVPlayerItem(url: clip.localFileURL)
            speechQueueKeyByPlayerItemID[ObjectIdentifier(playerItem)] = playbackItem.queueKey
            speechPlayer.insert(playerItem, after: previousItem)
            previousItem = playerItem
        }

        if targetIndex > 0 {
            for _ in 0..<targetIndex {
                speechPlayer.advanceToNextItem()
            }
        }
    }

    private func prepareMusicQueue(startingAt queueKey: String) async throws {
        guard let targetIndex = songQueueIndexByQueueKey[queueKey] else {
            throw PlaybackError.missingQueueKey(queueKey)
        }

        let storeIDs = songItems.compactMap { $0.resolvedSong?.id.rawValue }
        guard storeIDs.indices.contains(targetIndex) else {
            throw PlaybackError.invalidSongQueue
        }

        let descriptor = MPMusicPlayerStoreQueueDescriptor(storeIDs: storeIDs)
        descriptor.startItemID = storeIDs[targetIndex]
        musicPlayer.setQueue(with: descriptor)
        try await musicPlayer.prepareToPlay()
    }

    private func playNextSequentialItem() async {
        let nextIndex = currentIndex + 1
        guard playbackItems.indices.contains(nextIndex) else {
            stop()
            return
        }

        currentIndex = nextIndex
        try? await playCurrentItem()
    }

    private func playSegment(at index: Int) async {
        guard playbackItems.indices.contains(index) else { return }
        currentIndex = index
        try? await playCurrentItem()
    }

    private func observeMusicPlayerState() {
        let center = NotificationCenter.default

        playbackStateCancellable = center.publisher(
            for: .MPMusicPlayerControllerPlaybackStateDidChange,
            object: musicPlayer
        )
        .sink { [weak self] _ in
            self?.handleMusicStateChange()
        }

        nowPlayingCancellable = center.publisher(
            for: .MPMusicPlayerControllerNowPlayingItemDidChange,
            object: musicPlayer
        )
        .sink { [weak self] _ in
            self?.handleMusicNowPlayingItemChange()
        }
    }

    private func observeSpeechQueueCompletion() {
        speechCompletionObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self, let playerItem = notification.object as? AVPlayerItem else { return }
            let playerItemID = ObjectIdentifier(playerItem)
            Task { @MainActor in
                self.handleSpeechItemDidFinish(playerItemID: playerItemID)
            }
        }
    }

    private func handleMusicStateChange() {
        let newStatus = musicPlayer.playbackState
        defer { lastMusicStatus = newStatus }

        guard let currentItem, currentItem.kind == .song else {
            refreshPlaybackProgress()
            return
        }

        switch newStatus {
        case .playing:
            isPlaying = true
            hasObservedActiveSongPlayback = true
        case .paused, .interrupted, .stopped:
            isPlaying = false
            if shouldAdvanceAfterSongQueueStopped(for: newStatus) {
                Task { @MainActor in
                    await self.playNextSequentialItem()
                }
            }
        case .seekingForward, .seekingBackward:
            break
        @unknown default:
            isPlaying = false
        }

        updateNowPlaying(for: currentItem)
        refreshPlaybackProgress()
    }

    private func shouldAdvanceAfterSongQueueStopped(
        for newStatus: MPMusicPlaybackState
    ) -> Bool {
        guard !isTransitioning else { return false }
        guard hasObservedActiveSongPlayback else { return false }
        guard currentItem?.kind == .song else { return false }
        guard musicPlayer.nowPlayingItem == nil else { return false }

        if isUserPausingSong {
            isUserPausingSong = false
            return false
        }

        switch newStatus {
        case .paused, .stopped:
            return true
        default:
            return false
        }
    }

    private func handleMusicNowPlayingItemChange() {
        defer { refreshPlaybackProgress() }

        guard !isTransitioning else { return }
        guard let currentItem, currentItem.kind == .song else { return }
        guard let currentSongIndex = songQueueIndexByQueueKey[currentItem.queueKey] else { return }
        guard let nowPlayingStoreID = musicPlayer.nowPlayingItem?.playbackStoreID else { return }

        guard let newSongIndex = songItems.firstIndex(where: {
            $0.resolvedSong?.id.rawValue == nowPlayingStoreID
        }) else {
            return
        }

        guard newSongIndex != currentSongIndex else { return }

        let direction = newSongIndex > currentSongIndex ? 1 : -1
        let targetIndex = currentIndex + direction

        guard playbackItems.indices.contains(targetIndex) else { return }

        let targetItem = playbackItems[targetIndex]
        if targetItem.kind == .song {
            currentIndex = targetIndex
            self.currentItem = targetItem
            isPlaying = musicPlayer.playbackState == .playing
            currentPlaybackDuration = targetItem.durationSeconds
            updateNowPlaying(for: targetItem)
            return
        }

        Task { @MainActor in
            await self.playSegment(at: targetIndex)
        }
    }

    private func handleSpeechItemDidFinish(playerItemID: ObjectIdentifier) {
        guard !isTransitioning else { return }
        guard let finishedQueueKey = speechQueueKeyByPlayerItemID[playerItemID] else { return }
        guard currentItem?.queueKey == finishedQueueKey else { return }

        Task { @MainActor in
            await self.playNextSequentialItem()
        }
    }

    private func configureRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

        commandCenter.playCommand.removeTarget(nil)
        commandCenter.pauseCommand.removeTarget(nil)
        commandCenter.nextTrackCommand.removeTarget(nil)
        commandCenter.previousTrackCommand.removeTarget(nil)

        commandCenter.playCommand.isEnabled = true
        commandCenter.pauseCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true

        commandCenter.playCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                await self.togglePlayback()
            }
            return .success
        }

        commandCenter.pauseCommand.addTarget { [weak self] _ in
            
            guard let self else { return .commandFailed }
            Task { @MainActor in
                await self.togglePlayback()
            }
            return .success
        }

        commandCenter.nextTrackCommand.addTarget { [weak self] _ in
            print("geddy::command::next")
            guard let self else { return .commandFailed }
            Task { @MainActor in
                await self.skipToNextSegment()
            }
            return .success
        }

        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            print("geddy::command::prev")
            guard let self else { return .commandFailed }
            Task { @MainActor in
                await self.skipToPreviousSegment()
            }
            return .success
        }
    }

    private func configureAudioSession() {
        AppAudioSessionConfigurator.configureForAppLaunch()
    }

    private func startProgressUpdates() {
        progressTimerCancellable = Timer
            .publish(every: 0.4, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                self?.refreshPlaybackProgress()
            }
    }

    private func refreshPlaybackProgress() {
        guard let currentItem else {
            currentPlaybackTime = 0
            currentPlaybackDuration = 0
            return
        }

        switch currentItem.payload {
        case .speech(let clip):
            let duration = clip.response.durationSeconds
            currentPlaybackDuration = duration
            let currentTime = speechPlayer.currentTime().seconds
            if currentTime.isFinite {
                currentPlaybackTime = min(max(currentTime, 0), max(duration, 0))
            } else {
                currentPlaybackTime = 0
            }
            isPlaying = speechPlayer.timeControlStatus == .playing
        case .song(let resolvedSong):
            currentPlaybackDuration = resolvedSong.song.duration ?? currentPlaybackDuration
            currentPlaybackTime = min(currentMusicPlaybackTime(), max(currentPlaybackDuration, 0))
            isPlaying = musicPlayer.playbackState == .playing
        }

        updateNowPlaying(for: currentItem)
    }

    private func currentMusicPlaybackTime() -> TimeInterval {
        let playbackTime = musicPlayer.currentPlaybackTime
        guard playbackTime.isFinite else { return 0 }
        return max(playbackTime, 0)
    }

    private func updateNowPlaying(for item: StationPlaybackItem) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.subtitle,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentPlaybackTime
        ]

        switch item.payload {
        case .speech(let clip):
            info[MPMediaItemPropertyAlbumTitle] = "Geddy"
            info[MPMediaItemPropertyPlaybackDuration] = clip.response.durationSeconds
        case .song(let resolvedSong):
            if let duration = resolvedSong.song.duration {
                info[MPMediaItemPropertyPlaybackDuration] = duration
            }
        }

        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

private enum PlaybackError: LocalizedError {
    case missingQueueKey(String)
    case invalidSpeechItem(String)
    case invalidSongQueue

    var errorDescription: String? {
        switch self {
        case .missingQueueKey(let queueKey):
            return "搵唔返播放段落：\(queueKey)"
        case .invalidSpeechItem(let title):
            return "獨白音檔未準備好：\(title)"
        case .invalidSongQueue:
            return "Apple Music 播放清單未準備好。"
        }
    }
}
