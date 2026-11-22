import Foundation

enum EnginePreference: String, Codable, CaseIterable, Identifiable {
    case auto = "auto"
    case avPlayerOnly = "avplayer"
    case ffmpegOnly = "ffmpeg"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto:
            return "智能双引擎 (AVPlayer + FFmpeg)"
        case .avPlayerOnly:
            return "仅系统 AVPlayer (最省电)"
        case .ffmpegOnly:
            return "仅 FFmpeg / KSMEPlayer (全格式)"
        }
    }

    var shortTitle: String {
        switch self {
        case .auto: return "智能双引擎"
        case .avPlayerOnly: return "AVPlayer"
        case .ffmpegOnly: return "FFmpeg"
        }
    }
}

enum ActiveEngineKind: String {
    case avPlayer = "AVPlayer (硬件解码)"
    case ffmpeg = "KSMEPlayer (FFmpeg)"
    case unknown = "准备中"

    var shortName: String {
        switch self {
        case .avPlayer: return "AVPlayer"
        case .ffmpeg: return "FFmpeg"
        case .unknown: return "--"
        }
    }
}

enum SleepTimerPreset: Equatable, Hashable, Identifiable {
    case off
    case minutes(Int)
    case endOfEpisode

    var id: String {
        switch self {
        case .off: return "off"
        case .minutes(let m): return "min_\(m)"
        case .endOfEpisode: return "eoe"
        }
    }

    var title: String {
        switch self {
        case .off: return "不开启"
        case .minutes(let m): return "\(m) 分钟后"
        case .endOfEpisode: return "播完当前集"
        }
    }

    static var allCases: [SleepTimerPreset] {
        [.off, .minutes(15), .minutes(30), .minutes(45), .minutes(60), .minutes(90), .endOfEpisode]
    }
}

struct PlayableMedia: Identifiable, Equatable {
    let id: String
    let mediaKey: String
    let title: String
    let subtitle: String?
    let artworkURL: String?
    let endpoints: [StreamEndpoint]
    let isLive: Bool
    let startTime: TimeInterval
    let siteKey: String?
    let vodID: String?
    let episodeName: String?

    init(
        id: String = UUID().uuidString,
        mediaKey: String,
        title: String,
        subtitle: String? = nil,
        artworkURL: String? = nil,
        endpoints: [StreamEndpoint],
        isLive: Bool,
        startTime: TimeInterval = 0,
        siteKey: String? = nil,
        vodID: String? = nil,
        episodeName: String? = nil
    ) {
        self.id = id
        self.mediaKey = mediaKey
        self.title = title
        self.subtitle = subtitle
        self.artworkURL = artworkURL
        self.endpoints = endpoints
        self.isLive = isLive
        self.startTime = startTime
        self.siteKey = siteKey
        self.vodID = vodID
        self.episodeName = episodeName
    }

    static func from(channel: LiveChannel, currentProgram: String? = nil) -> PlayableMedia {
        PlayableMedia(
            id: channel.id,
            mediaKey: "live::\(channel.id)",
            title: channel.name,
            subtitle: currentProgram ?? channel.group,
            artworkURL: channel.logo,
            endpoints: channel.endpoints,
            isLive: true
        )
    }

    static func from(
        movie: VodMovie,
        sourceName: String,
        episode: VodEpisode,
        resumeTime: TimeInterval = 0
    ) -> PlayableMedia {
        let epLabel = episode.name.isEmpty ? sourceName : episode.name
        return PlayableMedia(
            id: "\(movie.id)::\(sourceName)::\(episode.id)",
            mediaKey: "vod::\(movie.id)",
            title: movie.title,
            subtitle: "\(sourceName) · \(epLabel)",
            artworkURL: movie.posterURL,
            endpoints: [StreamEndpoint(label: sourceName, url: episode.url, headers: episode.headers)],
            isLive: false,
            startTime: resumeTime,
            siteKey: movie.siteKey,
            vodID: movie.vodID,
            episodeName: epLabel
        )
    }

    static func from(custom: CustomMediaItem, resumeTime: TimeInterval = 0) -> PlayableMedia {
        PlayableMedia(
            id: custom.id.uuidString,
            mediaKey: "custom::\(custom.url)",
            title: custom.title,
            subtitle: custom.subtitle ?? (custom.isLive ? "自定义直播" : "自定义点播"),
            artworkURL: custom.posterURL,
            endpoints: [StreamEndpoint(label: "直连", url: custom.url, headers: custom.headers)],
            isLive: custom.isLive,
            startTime: custom.isLive ? 0 : resumeTime
        )
    }
}
