import AVFAudio
import Combine
import Foundation
import MediaPlayer
@preconcurrency import MusicKit

@MainActor
final class StationPlaybackCoordinator: NSObject, ObservableObject {
    @Published private(set) var currentItem: StationPlaybackItem?
    @Published private(set) var isPlaying = false
    @Published private(set) var currentIndex: Int = 0

    private let musicPlayer = ApplicationMusicPlayer.shared
    private var speechPlayer: AVAudioPlayer?
    private var playbackItems: [StationPlaybackItem] = []
    private var lastMusicStatus: MusicKit.MusicPlayer.PlaybackStatus = .stopped
    private var musicStateCancellable: AnyCancellable?
    private var isTransitioning = false
    private var isAwaitingSongCompletion = false
    private var hasObservedActiveSongPlayback = false
    private var isUserPausingSong = false

    override init() {
        super.init()
        configureAudioSession()
        observeMusicPlayerState()
        configureRemoteCommands()
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
            return
        }

        if playbackItems.indices.contains(currentIndex) {
            currentItem = playbackItems[currentIndex]
            return
        }

        currentIndex = min(currentIndex, max(playbackItems.count - 1, 0))
        currentItem = playbackItems[currentIndex]
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
                } else {
                    speechPlayer.play()
                    isPlaying = true
                    updateNowPlaying(for: currentItem)
                }
            }
        case .song:
            switch musicPlayer.state.playbackStatus {
            case .playing:
                isUserPausingSong = true
                musicPlayer.pause()
                isPlaying = false
            default:
                try? await musicPlayer.play()
                isUserPausingSong = false
                isPlaying = true
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
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    func skipToNextSong() async {
        guard let index = nextSongIndex(after: currentIndex) else { return }
        currentIndex = index
        try? await playCurrentItem()
    }

    func skipToPreviousSong() async {
        guard let index = previousSongIndex(beforeOrAt: currentIndex) else { return }
        currentIndex = index
        try? await playCurrentItem()
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

        switch item.payload {
        case .speech(let clip):
            let player = try AVAudioPlayer(contentsOf: clip.localFileURL)
            player.delegate = self
            player.prepareToPlay()
            player.play()
            speechPlayer = player
            isPlaying = true
            updateNowPlaying(for: item)

        case .song(let resolvedSong):
            let queue = ApplicationMusicPlayer.Queue(for: [resolvedSong.song])
            musicPlayer.queue = queue
            try await musicPlayer.prepareToPlay()
            try await musicPlayer.play()
            lastMusicStatus = musicPlayer.state.playbackStatus
            isAwaitingSongCompletion = true
            hasObservedActiveSongPlayback = false
            isPlaying = true
            updateNowPlaying(for: item)
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

    private func nextSongIndex(after index: Int) -> Int? {
        let start = min(index + 1, playbackItems.count)
        guard start < playbackItems.count else { return nil }
        return playbackItems[start...].firstIndex(where: { $0.kind == .song })
    }

    private func previousSongIndex(beforeOrAt index: Int) -> Int? {
        guard !playbackItems.isEmpty else { return nil }
        let clamped = min(index, playbackItems.count - 1)
        if playbackItems[clamped].kind == .song {
            return clamped
        }

        return playbackItems[0...clamped].lastIndex(where: { $0.kind == .song })
    }

    private func observeMusicPlayerState() {
        musicStateCancellable = musicPlayer.state.objectWillChange.sink { [weak self] in
            Task { @MainActor in
                self?.handleMusicStateChange()
            }
        }
    }

    private func handleMusicStateChange() {
        let newStatus = musicPlayer.state.playbackStatus
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
    }

    private func shouldAdvanceAfterSongCompletion(
        for newStatus: MusicKit.MusicPlayer.PlaybackStatus
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
            guard let self else { return .commandFailed }
            Task { @MainActor in
                await self.skipToNextSong()
            }
            return .success
        }

        commandCenter.previousTrackCommand.addTarget { [weak self] _ in
            guard let self else { return .commandFailed }
            Task { @MainActor in
                await self.skipToPreviousSong()
            }
            return .success
        }
    }

    private func configureAudioSession() {
        AppAudioSessionConfigurator.configureForAppLaunch()
    }

    private func updateNowPlaying(for item: StationPlaybackItem) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.subtitle,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0
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
