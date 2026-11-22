import Foundation

enum SourceKind: String, Codable, CaseIterable, Identifiable {
    case livePlaylist = "live"
    case tvboxConfig = "tvbox"
    case vodMacCMS = "maccms"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .livePlaylist:
            return "直播源 (M3U / TXT)"
        case .tvboxConfig:
            return "TVBox 订阅 (JSON)"
        case .vodMacCMS:
            return "点播接口 (MacCMS)"
        }
    }
}

struct SubscriptionSource: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var url: String
    var kind: SourceKind
    var epgURL: String?
    var customHeaders: [String: String] = [:]
    var isEnabled: Bool = true
    var lastUpdated: Date?
    var lastSummary: String?
}

struct StreamEndpoint: Identifiable, Codable, Hashable {
    let id: String
    let label: String
    let url: String
    let headers: [String: String]

    init(label: String, url: String, headers: [String: String] = [:]) {
        self.id = "\(label)|\(url)"
        self.label = label
        self.url = url
        self.headers = headers
    }
}

struct LiveChannel: Identifiable, Codable, Hashable {
    let id: String
    var name: String
    var group: String
    var endpoints: [StreamEndpoint]
    var logo: String?
    var tvgID: String?
    var tvgName: String?

    var primaryURL: String? {
        endpoints.first?.url
    }

    init(
        id: String? = nil,
        name: String,
        group: String,
        endpoints: [StreamEndpoint],
        logo: String? = nil,
        tvgID: String? = nil,
        tvgName: String? = nil
    ) {
        self.id = id ?? "\(group)::\(name)"
        self.name = name
        self.group = group
        self.endpoints = endpoints
        self.logo = logo
        self.tvgID = tvgID
        self.tvgName = tvgName
    }
}

struct EPGProgram: Identifiable, Codable, Hashable {
    var id: String { "\(channelKey)|\(Int(start.timeIntervalSince1970))|\(title)" }
    let channelKey: String
    let title: String
    let start: Date
    let end: Date
    let description: String?

    func isLive(at date: Date = Date()) -> Bool {
        date >= start && date < end
    }

    func progress(at date: Date = Date()) -> Double {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        let elapsed = date.timeIntervalSince(start)
        return min(max(elapsed / total, 0), 1)
    }
}
