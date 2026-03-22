import AVFAudio
import Combine
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
    private var speechPlayer: AVAudioPlayer?
    private var playbackItems: [StationPlaybackItem] = []
    private var lastMusicStatus: MPMusicPlaybackState = .stopped
    private var playbackStateCancellable: AnyCancellable?
    private var nowPlayingCancellable: AnyCancellable?
    private var isTransitioning = false
    private var isAwaitingSongCompletion = false
    private var hasObservedActiveSongPlayback = false
    private var isUserPausingSong = false
    private var progressTimerCancellable: AnyCancellable?

    override init() {
        super.init()
        configureAudioSession()
        observeMusicPlayerState()
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
           let newIndex = playbackItems.firstIndex(where: { $0.queueKey == currentQueueKey }) {
            currentIndex = newIndex
            currentItem = playbackItems[newIndex]
            refreshPlaybackProgress()
            return
        }

        if playbackItems.indices.contains(currentIndex) {
            currentItem = playbackItems[currentIndex]
            refreshPlaybackProgress()
            return
        }

        currentIndex = min(currentIndex, max(playbackItems.count - 1, 0))
        currentItem = playbackItems[currentIndex]
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
            if let speechPlayer {
                if speechPlayer.isPlaying {
                    speechPlayer.pause()
                    isPlaying = false
                    refreshPlaybackProgress()
                } else {
                    speechPlayer.play()
                    isPlaying = true
                    updateNowPlaying(for: currentItem)
                    refreshPlaybackProgress()
                }
            }
        case .song:
            switch musicPlayer.playbackState {
            case .playing:
                isUserPausingSong = true
                musicPlayer.pause()
                isPlaying = false
                refreshPlaybackProgress()
            default:
                musicPlayer.play()
                isUserPausingSong = false
                isPlaying = true
                refreshPlaybackProgress()
            }
        }
    }

    func stop() {
        speechPlayer?.stop()
        speechPlayer = nil
        musicPlayer.stop()
        currentItem = nil
        isPlaying = false
        isAwaitingSongCompletion = false
        hasObservedActiveSongPlayback = false
        isUserPausingSong = false
        currentPlaybackTime = 0
        currentPlaybackDuration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func skipToNextSegment() async {
        print("geddy::skipToNextSegement")
        await playSegment(at: currentIndex + 1)
    }

    func skipToPreviousSegment() async {
        print("geddy::skipToPreviousSegment")
        await playSegment(at: currentIndex - 1)
    }

    private func playCurrentItem() async throws {
        guard playbackItems.indices.contains(currentIndex) else { return }

        isTransitioning = true
        defer { isTransitioning = false }

        speechPlayer?.stop()
        speechPlayer = nil
        musicPlayer.stop()
        isAwaitingSongCompletion = false
        hasObservedActiveSongPlayback = false
        isUserPausingSong = false

        let item = playbackItems[currentIndex]
        currentItem = item
        currentPlaybackTime = 0
        currentPlaybackDuration = item.durationSeconds

        switch item.payload {
        case .speech(let clip):
            let player = try AVAudioPlayer(contentsOf: clip.localFileURL)
            player.delegate = self
            player.prepareToPlay()
            player.volume = 1.2
            player.play()
            speechPlayer = player
            isPlaying = true
            currentPlaybackDuration = player.duration > 0 ? player.duration : clip.response.durationSeconds
            updateNowPlaying(for: item)
            refreshPlaybackProgress()

        case .song(let resolvedSong):
            let storeID = resolvedSong.id.rawValue
            let descriptor = MPMusicPlayerStoreQueueDescriptor(storeIDs: [storeID])
            musicPlayer.setQueue(with: descriptor)
            try await musicPlayer.prepareToPlay()
            musicPlayer.play()
            lastMusicStatus = musicPlayer.playbackState
            isAwaitingSongCompletion = true
            hasObservedActiveSongPlayback = false
            isPlaying = true
            currentPlaybackDuration = resolvedSong.song.duration ?? 0
            updateNowPlaying(for: item)
            refreshPlaybackProgress()
        }
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

    private func handleMusicStateChange() {
        let newStatus = musicPlayer.playbackState
        defer { lastMusicStatus = newStatus }

        guard let currentItem, currentItem.kind == .song else { return }

        switch newStatus {
        case .playing:
            isPlaying = true
            hasObservedActiveSongPlayback = true
        case .paused, .interrupted:
            isPlaying = false
            if shouldAdvanceAfterSongCompletion(for: newStatus) {
                advanceToNextSequentialItemAfterSong()
            }
        case .stopped:
            isPlaying = false
            if shouldAdvanceAfterSongCompletion(for: newStatus) {
                advanceToNextSequentialItemAfterSong()
            }
        case .seekingForward, .seekingBackward:
            break
        @unknown default:
            isPlaying = false
        }

        refreshPlaybackProgress()
    }

    private func shouldAdvanceAfterSongCompletion(
        for newStatus: MPMusicPlaybackState
    ) -> Bool {
        guard isAwaitingSongCompletion, !isTransitioning else { return false }
        guard hasObservedActiveSongPlayback else { return false }
        guard !isUserPausingSong else {
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

    private func advanceToNextSequentialItemAfterSong() {
        isAwaitingSongCompletion = false
        hasObservedActiveSongPlayback = false
        isUserPausingSong = false
        Task { @MainActor in
            await self.playNextSequentialItem()
        }
    }

    private func configureRemoteCommands() {
        let commandCenter = MPRemoteCommandCenter.shared()

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
            print("geddy::command::next before task")
            guard let self else { return .commandFailed }
            Task { @MainActor in
                print("geddy::command::next")
                await self.skipToNextSegment()
            }
            return .success
        }

        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            print("geddy::command::previous before task")
            guard let self else { return .commandFailed }
            Task { @MainActor in
                print("geddy::command::previous")
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
            let duration = speechPlayer?.duration ?? clip.response.durationSeconds
            currentPlaybackDuration = duration
            currentPlaybackTime = min(speechPlayer?.currentTime ?? 0, max(duration, 0))
        case .song(let resolvedSong):
            currentPlaybackDuration = resolvedSong.song.duration ?? currentPlaybackDuration
            currentPlaybackTime = min(currentMusicPlaybackTime(), max(currentPlaybackDuration, 0))
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
            info[MPMediaItemPropertyAlbumTitle] = "AI 鄭子誠"
            info[MPMediaItemPropertyPlaybackDuration] = clip.response.durationSeconds
            MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        case .song(let resolvedSong):
            if let duration = resolvedSong.song.duration {
                info[MPMediaItemPropertyPlaybackDuration] = duration
            }
            MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }
}

extension StationPlaybackCoordinator: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        guard flag else { return }
        Task { @MainActor in
            await self.playNextSequentialItem()
        }
    }
}
