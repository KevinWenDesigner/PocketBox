import Foundation

enum VodAPIType: Int, Codable, Hashable {
    case xml = 0
    case json = 1
}

struct VodSite: Identifiable, Codable, Hashable {
    var id: String { key }
    let key: String
    var name: String
    var apiURL: String
    var apiType: VodAPIType
    var searchable: Bool
    var playURL: String?
    var headers: [String: String] = [:]
}

struct VodCategory: Identifiable, Codable, Hashable {
    let id: String
    let name: String
}

struct VodEpisode: Identifiable, Codable, Hashable {
    var id: String { "\(name)|\(url)" }
    let name: String
    let url: String
    var headers: [String: String] = [:]
}

struct VodPlaySource: Identifiable, Codable, Hashable {
    var id: String { name }
    let name: String
    let episodes: [VodEpisode]
}

struct VodMovie: Identifiable, Codable, Hashable {
    var id: String { "\(siteKey)::\(vodID)" }
    let siteKey: String
    let vodID: String
    var title: String
    var posterURL: String?
    var remarks: String?
    var year: String?
    var area: String?
    var typeName: String?
    var director: String?
    var actor: String?
    var synopsis: String?
    var playSources: [VodPlaySource] = []
}

struct CustomMediaItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String
    var subtitle: String?
    var url: String
    var posterURL: String?
    var isLive: Bool = false
    var headers: [String: String] = [:]
    var addedAt: Date = Date()
}

struct WatchHistoryItem: Identifiable, Codable, Hashable {
    var id: String { mediaKey }
    let mediaKey: String
    var title: String
    var subtitle: String?
    var posterURL: String?
    var url: String
    var isLive: Bool
    var position: TimeInterval
    var duration: TimeInterval
    var updatedAt: Date
    var headers: [String: String] = [:]
    var siteKey: String?
    var vodID: String?
    var episodeName: String?

    var progressRatio: Double {
        guard !isLive, duration > 1 else { return 0 }
        return min(max(position / duration, 0), 1)
    }
}

struct FavoriteChannel: Identifiable, Codable, Hashable {
    var id: String { channelID }
    let channelID: String
    var name: String
    var group: String
    var logo: String?
    var endpoints: [StreamEndpoint]
    var savedAt: Date = Date()

    func toLiveChannel() -> LiveChannel {
        LiveChannel(
            id: channelID,
            name: name,
            group: group,
            endpoints: endpoints,
            logo: logo
        )
    }
}
