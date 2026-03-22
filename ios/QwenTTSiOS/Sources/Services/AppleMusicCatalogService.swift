import Foundation
import MusicKit

enum AppleMusicError: LocalizedError {
    case authorizationDenied
    case noPlayableSongFound(String)

    var errorDescription: String? {
        switch self {
        case .authorizationDenied:
            return "未能取得 Apple Music 權限。"
        case .noPlayableSongFound(let query):
            return "Apple Music 暫時搵唔到可播放歌曲：\(query)"
        }
    }
}

struct AppleMusicCatalogService {
    func requestAuthorizationIfNeeded() async throws {
        let status = MusicAuthorization.currentStatus
        if status == .authorized {
            return
        }

        let requested = await MusicAuthorization.request()
        guard requested == .authorized else {
            throw AppleMusicError.authorizationDenied
        }
    }

    func resolveSuggestions(_ suggestions: [SongSuggestion]) async throws -> [ResolvedSong] {
        try await requestAuthorizationIfNeeded()
        var songs: [ResolvedSong] = []

        for suggestion in suggestions {
            if let song = try await searchTopSong(for: suggestion.searchQuery) {
                songs.append(
                    ResolvedSong(
                        id: song.id,
                        suggestion: suggestion,
                        song: song
                    )
                )
            }
        }

        if songs.isEmpty, let first = suggestions.first {
            throw AppleMusicError.noPlayableSongFound(first.searchQuery)
        }

        return songs
    }

    private func searchTopSong(for query: String) async throws -> Song? {
        print("search song: \(query)")
        var request = MusicCatalogSearchRequest(term: query, types: [Song.self])
        request.limit = 5
        
        if #available(iOS 16.0, *) {
            request.includeTopResults = true
        }

        let response = try await request.response()
        return response.songs.first(where: { $0.playParameters != nil }) ?? response.songs.first
    }
}
