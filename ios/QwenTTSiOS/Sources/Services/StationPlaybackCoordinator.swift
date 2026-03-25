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
    private var currentSpeechPlayerItemID: ObjectIdentifier?
    private var lastMusicStatus: MPMusicPlaybackState = .stopped
    private var playbackStateCancellable: AnyCancellable?
    private var nowPlayingCancellable: AnyCancellable?
    private var progressTimerCancellable: AnyCancellable?
    private var speechCompletionObserver: NSObjectProtocol?
    private var isTransitioning = false
    private var hasObservedActiveSongPlayback = false
    private var isUserPausingSong = false
    private var isAdvancingAfterSongCompletion = false

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
        currentIndex = 0
        try await playCurrentItem()
    }

    func updatePlaybackItems(_ items: [StationPlaybackItem]) {
        guard !items.isEmpty else { return }

        let currentQueueKey = currentItem?.queueKey
        playbackItems = items

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
        currentSpeechPlayerItemID = nil
        musicPlayer.stop()
        currentItem = nil
        currentIndex = 0
        isPlaying = false
        hasObservedActiveSongPlayback = false
        isUserPausingSong = false
        isAdvancingAfterSongCompletion = false
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
        isAdvancingAfterSongCompletion = false

        switch item.payload {
        case .speech:
            musicPlayer.pause()
            musicPlayer.stop()
            try prepareSpeechPlayer(for: item)
            await speechPlayer.seek(to: .zero)
            speechPlayer.play()
            isPlaying = true
            currentPlaybackDuration = item.durationSeconds
        case .song:
            speechPlayer.pause()
            speechPlayer.removeAllItems()
            currentSpeechPlayerItemID = nil
            try await prepareMusicQueue(for: item)
            musicPlayer.play()
            lastMusicStatus = musicPlayer.playbackState
            isPlaying = true
            currentPlaybackDuration = item.durationSeconds
        }

        refreshPlaybackProgress()
    }

    private func prepareSpeechPlayer(for item: StationPlaybackItem) throws {
        guard let clip = item.spokenClip else {
            throw PlaybackError.invalidSpeechItem(item.title)
        }
        speechPlayer.pause()
        speechPlayer.removeAllItems()
        let playerItem = AVPlayerItem(url: clip.localFileURL)
        currentSpeechPlayerItemID = ObjectIdentifier(playerItem)
        speechPlayer.insert(playerItem, after: nil)
    }

    private func prepareMusicQueue(for item: StationPlaybackItem) async throws {
        guard let resolvedSong = item.resolvedSong else {
            throw PlaybackError.invalidSongQueue
        }

        let descriptor = MPMusicPlayerStoreQueueDescriptor(storeIDs: [resolvedSong.id.rawValue])
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
            self?.refreshPlaybackProgress()
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
            isAdvancingAfterSongCompletion = false
        case .paused, .interrupted, .stopped:
            isPlaying = false
            advanceToNextSegmentAfterSongIfNeeded(for: newStatus)
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
        guard !isAdvancingAfterSongCompletion else { return false }
        guard hasObservedActiveSongPlayback else { return false }
        guard currentItem?.kind == .song else { return false }

        if isUserPausingSong {
            isUserPausingSong = false
            return false
        }

        switch newStatus {
        case .paused, .stopped:
            return songPlaybackReachedEnd()
        default:
            return false
        }
    }

    private func songPlaybackReachedEnd() -> Bool {
        guard let currentItem, let resolvedSong = currentItem.resolvedSong else { return false }
        let duration = resolvedSong.song.duration ?? currentPlaybackDuration
        guard duration > 0 else { return false }

        let playbackTime = max(currentMusicPlaybackTime(), currentPlaybackTime)
        return (duration - playbackTime) <= 1.0
    }

    private func advanceToNextSegmentAfterSongIfNeeded(for newStatus: MPMusicPlaybackState) {
        guard shouldAdvanceAfterSongQueueStopped(for: newStatus) else { return }
        isAdvancingAfterSongCompletion = true
        Task { @MainActor in
            await self.playNextSequentialItem()
        }
    }

    private func handleSpeechItemDidFinish(playerItemID: ObjectIdentifier) {
        guard !isTransitioning else { return }
        guard currentSpeechPlayerItemID == playerItemID else { return }

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
            guard let self else { return .commandFailed }
            Task { @MainActor in
                await self.skipToNextSegment()
            }
            return .success
        }

        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
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
            if musicPlayer.playbackState != .playing {
                advanceToNextSegmentAfterSongIfNeeded(for: musicPlayer.playbackState)
            }
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
