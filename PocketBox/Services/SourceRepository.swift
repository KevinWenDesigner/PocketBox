import Foundation

struct SourceSyncOutput {
    var channels: [LiveChannel] = []
    var vodSites: [VodSite] = []
    var discoveredEPGURL: String?
    var summary: String
}

final class SourceRepository {
    static let shared = SourceRepository()

    private init() {}

    func syncSource(_ source: SubscriptionSource, defaultUA: String) async throws -> SourceSyncOutput {
        switch source.kind {
        case .livePlaylist:
            let text = try await NetworkClient.shared.fetchText(
                url: source.url,
                headers: source.customHeaders,
                defaultUA: defaultUA
            )
            let parsed = PlaylistParser.parse(text, defaultGroup: source.name, defaultHeaders: source.customHeaders)
            return SourceSyncOutput(
                channels: parsed.channels,
                vodSites: [],
                discoveredEPGURL: source.epgURL ?? parsed.epgURL,
                summary: "已加载 \(parsed.channels.count) 个直播频道"
            )

        case .tvboxConfig:
            let rawText = try await NetworkClient.shared.fetchText(
                url: source.url,
                headers: source.customHeaders,
                defaultUA: defaultUA
            )
            let config = try TVBoxConfigParser.parse(rawText, baseURL: URL(string: source.url))
            var allChannels = config.inlineChannels
            var discoveredEPG = source.epgURL ?? config.defaultEPG

            for live in config.liveEntries {
                guard let liveURL = live.url, !liveURL.isEmpty else { continue }
                do {
                    var reqHeaders = source.customHeaders
                    for (k, v) in live.headers { reqHeaders[k] = v }
                    let text = try await NetworkClient.shared.fetchText(
                        url: liveURL,
                        headers: reqHeaders,
                        defaultUA: defaultUA
                    )
                    let parsed = PlaylistParser.parse(text, defaultGroup: live.name, defaultHeaders: reqHeaders)
                    allChannels.append(contentsOf: parsed.channels)
                    if discoveredEPG == nil {
                        discoveredEPG = live.epg ?? parsed.epgURL
                    }
                } catch {
                    // Continue fetching remaining live entries even if one mirror fails
                    continue
                }
            }

            var parts: [String] = []
            parts.append("\(allChannels.count) 个直播频道")
            if !config.vodSites.isEmpty {
                parts.append("\(config.vodSites.count) 个 CMS 点播源")
            }
            if config.skippedSpiderCount > 0 {
                parts.append("\(config.skippedSpiderCount) 个 Android JAR 爬虫源(iOS不支持)")
            }

            return SourceSyncOutput(
                channels: allChannels,
                vodSites: config.vodSites,
                discoveredEPGURL: discoveredEPG,
                summary: parts.joined(separator: " · ")
            )

        case .vodMacCMS:
            let apiType: VodAPIType = try await detectMacCMSType(url: source.url, headers: source.customHeaders, defaultUA: defaultUA)
            let site = VodSite(
                key: source.id.uuidString,
                name: source.name,
                apiURL: source.url,
                apiType: apiType,
                searchable: true,
                playURL: nil,
                headers: source.customHeaders
            )
            let page = try await fetchVodList(site: site, categoryID: nil, page: 1, keyword: nil, defaultUA: defaultUA)
            return SourceSyncOutput(
                channels: [],
                vodSites: [site],
                discoveredEPGURL: nil,
                summary: "CMS 接口可用（\(page.categories.count) 个分类，首页 \(page.movies.count) 部影片）"
            )
        }
    }

    func fetchEPG(epgURL: String, channelName: String? = nil, defaultUA: String) async throws -> [String: [EPGProgram]] {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        let today = df.string(from: Date())

        var finalURL = epgURL
            .replacingOccurrences(of: "{date}", with: today)
        if let ch = channelName?.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            finalURL = finalURL
                .replacingOccurrences(of: "{name}", with: ch)
                .replacingOccurrences(of: "{ch}", with: ch)
        }

        let data = try await NetworkClient.shared.fetchData(url: finalURL, defaultUA: defaultUA)
        return EPGParser.parse(data: data, fallbackChannelName: channelName)
    }

    func fetchVodList(
        site: VodSite,
        categoryID: String?,
        page: Int,
        keyword: String?,
        defaultUA: String
    ) async throws -> MacCMSPageResult {
        var components = URLComponents(string: site.apiURL)
        var items = components?.queryItems ?? []

        func setQuery(_ name: String, _ value: String) {
            items.removeAll { $0.name == name }
            items.append(URLQueryItem(name: name, value: value))
        }

        setQuery("ac", (keyword?.isEmpty == false || categoryID != nil) ? "detail" : "list")
        setQuery("pg", String(page))
        if let categoryID, !categoryID.isEmpty {
            setQuery("t", categoryID)
        }
        if let keyword, !keyword.isEmpty {
            setQuery("wd", keyword)
        }
        components?.queryItems = items

        let requestURL = components?.url?.absoluteString ?? site.apiURL
        let data = try await NetworkClient.shared.fetchData(
            url: requestURL,
            headers: site.headers,
            defaultUA: defaultUA
        )
        return try MacCMSParser.parse(data: data, site: site)
    }

    func fetchVodDetail(site: VodSite, vodID: String, defaultUA: String) async throws -> VodMovie? {
        var components = URLComponents(string: site.apiURL)
        var items = components?.queryItems ?? []
        items.removeAll { $0.name == "ac" || $0.name == "ids" || $0.name == "t" || $0.name == "wd" || $0.name == "pg" }
        items.append(URLQueryItem(name: "ac", value: "detail"))
        items.append(URLQueryItem(name: "ids", value: vodID))
        components?.queryItems = items

        let requestURL = components?.url?.absoluteString ?? site.apiURL
        let data = try await NetworkClient.shared.fetchData(
            url: requestURL,
            headers: site.headers,
            defaultUA: defaultUA
        )
        let parsed = try MacCMSParser.parse(data: data, site: site)
        return parsed.movies.first
    }

    private func detectMacCMSType(url: String, headers: [String: String], defaultUA: String) async throws -> VodAPIType {
        let data = try await NetworkClient.shared.fetchData(url: url, headers: headers, defaultUA: defaultUA)
        let preview = NetworkClient.decodeText(data).trimmingCharacters(in: .whitespacesAndNewlines)
        return (preview.hasPrefix("{") || preview.hasPrefix("[")) ? .json : .xml
    }
}
