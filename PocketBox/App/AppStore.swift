import Foundation
import SwiftUI

@MainActor
final class AppStore: ObservableObject {
    @Published var sources: [SubscriptionSource] = []
    @Published var channels: [LiveChannel] = []
    @Published var vodSites: [VodSite] = []
    @Published var customMedia: [CustomMediaItem] = []
    @Published var favorites: [FavoriteChannel] = []
    @Published var watchHistory: [WatchHistoryItem] = []
    @Published var epgMap: [String: [EPGProgram]] = [:]
    @Published var activeEPGURL: String = ""

    @Published var isSyncingSources = false
    @Published var syncNotice: String?

    // User Settings
    @Published var backgroundPlayEnabled: Bool {
        didSet { saveDefaults() }
    }
    @Published var defaultAudioOnlyMode: Bool {
        didSet { saveDefaults() }
    }
    @Published var enginePreference: EnginePreference {
        didSet { saveDefaults() }
    }
    @Published var hardwareDecode: Bool {
        didSet { saveDefaults() }
    }
    @Published var autoReconnectLive: Bool {
        didSet { saveDefaults() }
    }
    @Published var defaultUserAgent: String {
        didSet { saveDefaults() }
    }
    @Published var bufferDuration: Double {
        didSet { saveDefaults() }
    }

    private let defaults = UserDefaults.standard
    private let fileManager = FileManager.default

    private enum Keys {
        static let backgroundPlay = "pb.backgroundPlayEnabled"
        static let audioOnly = "pb.defaultAudioOnlyMode"
        static let enginePref = "pb.enginePreference"
        static let hardwareDecode = "pb.hardwareDecode"
        static let autoReconnect = "pb.autoReconnectLive"
        static let defaultUA = "pb.defaultUserAgent"
        static let bufferDuration = "pb.bufferDuration"
        static let activeEPGURL = "pb.activeEPGURL"
    }

    init() {
        self.backgroundPlayEnabled = defaults.object(forKey: Keys.backgroundPlay) as? Bool ?? true
        self.defaultAudioOnlyMode = defaults.object(forKey: Keys.audioOnly) as? Bool ?? false
        let rawPref = defaults.string(forKey: Keys.enginePref) ?? EnginePreference.auto.rawValue
        self.enginePreference = EnginePreference(rawValue: rawPref) ?? .auto
        self.hardwareDecode = defaults.object(forKey: Keys.hardwareDecode) as? Bool ?? true
        self.autoReconnectLive = defaults.object(forKey: Keys.autoReconnect) as? Bool ?? true
        self.defaultUserAgent = defaults.string(forKey: Keys.defaultUA) ?? "Mozilla/5.0 (iPhone; CPU iPhone OS 15_8_8 like Mac OS X) AppleWebKit/605.1.15"
        let buf = defaults.double(forKey: Keys.bufferDuration)
        self.bufferDuration = buf > 0 ? buf : 3.0
        self.activeEPGURL = defaults.string(forKey: Keys.activeEPGURL) ?? ""

        loadPersistedCollections()
        seedBuiltInLegalTestDataIfNeeded()
    }

    // MARK: - Live Channels & EPG Helpers

    var channelGroups: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for ch in channels {
            if seen.insert(ch.group).inserted {
                result.append(ch.group)
            }
        }
        return result
    }

    func isFavorite(_ channel: LiveChannel) -> Bool {
        favorites.contains { $0.channelID == channel.id }
    }

    func toggleFavorite(_ channel: LiveChannel) {
        if let idx = favorites.firstIndex(where: { $0.channelID == channel.id }) {
            favorites.remove(at: idx)
        } else {
            favorites.insert(
                FavoriteChannel(
                    channelID: channel.id,
                    name: channel.name,
                    group: channel.group,
                    logo: channel.logo,
                    endpoints: channel.endpoints
                ),
                at: 0
            )
        }
        persist(favorites, to: "favorites.json")
    }

    func programs(for channel: LiveChannel) -> [EPGProgram] {
        let rawKeys = [channel.tvgID, channel.tvgName, channel.name]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        var candidates: [String] = []
        for k in rawKeys {
            candidates.append(k)
            let compact = k.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: " ", with: "")
            if compact != k { candidates.append(compact) }
        }
        for k in candidates {
            if let list = epgMap[k], !list.isEmpty {
                return list
            }
        }
        return []
    }

    func currentProgram(for channel: LiveChannel, at date: Date = Date()) -> EPGProgram? {
        programs(for: channel).first { $0.isLive(at: date) }
    }

    func currentProgramTitle(forChannelNamed name: String) -> String? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return epgMap[key]?.first(where: { $0.isLive() })?.title
    }

    // MARK: - Source Management & Sync

    func addSource(_ source: SubscriptionSource) {
        sources.append(source)
        persist(sources, to: "sources.json")
    }

    func updateSource(_ source: SubscriptionSource) {
        if let idx = sources.firstIndex(where: { $0.id == source.id }) {
            sources[idx] = source
            persist(sources, to: "sources.json")
        }
    }

    func deleteSources(at offsets: IndexSet) {
        sources.remove(atOffsets: offsets)
        persist(sources, to: "sources.json")
    }

    func importLocalPlaylist(content: String, name: String) {
        let parsed = PlaylistParser.parse(content, defaultGroup: name)
        var merged = channels
        for ch in parsed.channels where !merged.contains(where: { $0.id == ch.id }) {
            merged.append(ch)
        }
        channels = merged
        persist(channels, to: "channels.json")
        if let epg = parsed.epgURL, activeEPGURL.isEmpty {
            activeEPGURL = epg
            saveDefaults()
        }
        syncNotice = "已从本地文件导入 \(parsed.channels.count) 个频道"
    }

    func syncAllEnabledSources() async {
        let enabled = sources.filter(\.isEnabled)
        guard !enabled.isEmpty else {
            syncNotice = "当前没有启用的订阅源"
            return
        }

        isSyncingSources = true
        defer { isSyncingSources = false }

        var newChannels: [LiveChannel] = []
        var newSites: [VodSite] = []
        var errors: [String] = []

        for var src in enabled {
            do {
                let output = try await SourceRepository.shared.syncSource(src, defaultUA: defaultUserAgent)
                newChannels.append(contentsOf: output.channels)
                for site in output.vodSites where !newSites.contains(where: { $0.apiURL == site.apiURL }) {
                    newSites.append(site)
                }
                if let epg = output.discoveredEPGURL, !epg.isEmpty, activeEPGURL.isEmpty {
                    activeEPGURL = epg
                    saveDefaults()
                }
                src.lastUpdated = Date()
                src.lastSummary = output.summary
                updateSource(src)
            } catch {
                src.lastSummary = "失败: \(error.localizedDescription)"
                updateSource(src)
                errors.append("\(src.name): \(error.localizedDescription)")
            }
        }

        if !newChannels.isEmpty {
            channels = deduplicateChannels(newChannels)
            persist(channels, to: "channels.json")
        }
        if !newSites.isEmpty {
            vodSites = newSites
            persist(vodSites, to: "vod_sites.json")
        }

        if !activeEPGURL.isEmpty && !activeEPGURL.contains("{name}") && !activeEPGURL.contains("{ch}") {
            await refreshGlobalEPG()
        }

        if errors.isEmpty {
            syncNotice = "同步完成：\(channels.count) 个频道，\(vodSites.count) 个点播站点"
        } else {
            syncNotice = "部分同步失败：\(errors.joined(separator: "; "))"
        }
    }

    func refreshGlobalEPG() async {
        guard !activeEPGURL.isEmpty else { return }
        do {
            let map = try await SourceRepository.shared.fetchEPG(epgURL: activeEPGURL, defaultUA: defaultUserAgent)
            if !map.isEmpty {
                epgMap = map
            }
        } catch {
            // EPG failures should never block playback
        }
    }

    func fetchChannelEPGIfNeeded(_ channel: LiveChannel) async {
        guard !activeEPGURL.isEmpty,
              activeEPGURL.contains("{name}") || activeEPGURL.contains("{ch}")
        else { return }
        if !programs(for: channel).isEmpty { return }
        do {
            let result = try await SourceRepository.shared.fetchEPG(
                epgURL: activeEPGURL,
                channelName: channel.tvgName ?? channel.name,
                defaultUA: defaultUserAgent
            )
            for (k, v) in result {
                epgMap[k] = v
            }
        } catch {}
    }

    // MARK: - Custom VOD & History

    func addCustomMedia(_ item: CustomMediaItem) {
        customMedia.insert(item, at: 0)
        persist(customMedia, to: "custom_media.json")
    }

    func deleteCustomMedia(at offsets: IndexSet) {
        customMedia.remove(atOffsets: offsets)
        persist(customMedia, to: "custom_media.json")
    }

    func recordHistory(_ item: WatchHistoryItem) {
        watchHistory.removeAll { $0.mediaKey == item.mediaKey }
        watchHistory.insert(item, at: 0)
        if watchHistory.count > 100 {
            watchHistory = Array(watchHistory.prefix(100))
        }
        persist(watchHistory, to: "history.json")
    }

    func savedPosition(forMediaKey key: String) -> TimeInterval {
        guard let item = watchHistory.first(where: { $0.mediaKey == key }),
              !item.isLive,
              item.position > 3
        else { return 0 }
        if item.duration > 10 && item.position >= item.duration - 5 {
            return 0
        }
        return item.position
    }

    func clearHistory() {
        watchHistory = []
        persist(watchHistory, to: "history.json")
    }

    func clearCache() {
        URLCache.shared.removeAllCachedResponses()
        epgMap = [:]
        syncNotice = "已清除网络缓存与临时节目单"
    }

    func loadDemoLegalTestStreams() {
        let demoChannels: [LiveChannel] = [
            LiveChannel(
                name: "Apple BipBop 测试流 (HLS)",
                group: "官方测试流",
                endpoints: [
                    StreamEndpoint(label: "主线路 HLS", url: "https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8"),
                    StreamEndpoint(label: "备用 16:9", url: "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8")
                ]
            ),
            LiveChannel(
                name: "Big Buck Bunny (MP4 点播测试)",
                group: "官方测试流",
                endpoints: [
                    StreamEndpoint(label: "MP4 线路", url: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")
                ]
            ),
            LiveChannel(
                name: "Sintel 开源短片 (MP4)",
                group: "官方测试流",
                endpoints: [
                    StreamEndpoint(label: "MP4 线路", url: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/Sintel.mp4")
                ]
            )
        ]

        var merged = channels
        for ch in demoChannels where !merged.contains(where: { $0.id == ch.id }) {
            merged.append(ch)
        }
        channels = merged
        persist(channels, to: "channels.json")

        let demoVOD = CustomMediaItem(
            title: "Big Buck Bunny (测试点播)",
            subtitle: "开源测试片 · 支持锁屏与进度记忆",
            url: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4",
            isLive: false
        )
        if !customMedia.contains(where: { $0.url == demoVOD.url }) {
            customMedia.insert(demoVOD, at: 0)
            persist(customMedia, to: "custom_media.json")
        }
        syncNotice = "已载入公开测试流（请在「源管理」添加您自己的 M3U/TXT/TVBox 接口）"
    }

    // MARK: - Persistence Helpers

    private func deduplicateChannels(_ list: [LiveChannel]) -> [LiveChannel] {
        var order: [String] = []
        var map: [String: LiveChannel] = [:]
        for ch in list {
            if var existing = map[ch.id] {
                for ep in ch.endpoints where !existing.endpoints.contains(where: { $0.url == ep.url }) {
                    existing.endpoints.append(ep)
                }
                map[ch.id] = existing
            } else {
                order.append(ch.id)
                map[ch.id] = ch
            }
        }
        return order.compactMap { map[$0] }
    }

    private func storageDirectory() -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("PocketBoxData", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    private func persist<T: Encodable>(_ value: T, to filename: String) {
        let url = storageDirectory().appendingPathComponent(filename)
        if let data = try? JSONEncoder().encode(value) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func load<T: Decodable>(_ type: T.Type, from filename: String) -> T? {
        let url = storageDirectory().appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private func loadPersistedCollections() {
        sources = load([SubscriptionSource].self, from: "sources.json") ?? []
        channels = load([LiveChannel].self, from: "channels.json") ?? []
        vodSites = load([VodSite].self, from: "vod_sites.json") ?? []
        customMedia = load([CustomMediaItem].self, from: "custom_media.json") ?? []
        favorites = load([FavoriteChannel].self, from: "favorites.json") ?? []
        watchHistory = load([WatchHistoryItem].self, from: "history.json") ?? []
    }

    private func seedBuiltInLegalTestDataIfNeeded() {
        let seededKey = "pb.didSeedUserSourcesV2"
        if !defaults.bool(forKey: seededKey) {
            defaults.set(true, forKey: seededKey)

            let defaultLive = SubscriptionSource(
                name: "默认直播源 (tv.m3u)",
                url: "https://gitee.com/ht-healthcare/look/raw/master/tv.m3u",
                kind: .livePlaylist,
                isEnabled: true
            )
            let defaultTVBox = SubscriptionSource(
                name: "newwex 配置 (含直播/参考)",
                url: "https://9280.kstore.vip/newwex.json",
                kind: .tvboxConfig,
                isEnabled: true
            )

            for src in [defaultLive, defaultTVBox] where !sources.contains(where: { $0.url == src.url }) {
                sources.append(src)
            }
            persist(sources, to: "sources.json")

            if channels.isEmpty {
                loadDemoLegalTestStreams()
            }
            syncNotice = nil
        }
    }

    private func saveDefaults() {
        defaults.set(backgroundPlayEnabled, forKey: Keys.backgroundPlay)
        defaults.set(defaultAudioOnlyMode, forKey: Keys.audioOnly)
        defaults.set(enginePreference.rawValue, forKey: Keys.enginePref)
        defaults.set(hardwareDecode, forKey: Keys.hardwareDecode)
        defaults.set(autoReconnectLive, forKey: Keys.autoReconnect)
        defaults.set(defaultUserAgent, forKey: Keys.defaultUA)
        defaults.set(bufferDuration, forKey: Keys.bufferDuration)
        defaults.set(activeEPGURL, forKey: Keys.activeEPGURL)
    }
}
