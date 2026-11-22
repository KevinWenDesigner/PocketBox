import Foundation

struct TVBoxLiveEntry {
    var name: String
    var url: String?
    var epg: String?
    var ua: String?
    var headers: [String: String]
    var inlineChannels: [LiveChannel]
}

struct TVBoxConfigParseResult {
    var liveEntries: [TVBoxLiveEntry]
    var inlineChannels: [LiveChannel]
    var vodSites: [VodSite]
    var skippedSpiderCount: Int
    var defaultEPG: String?
}

enum TVBoxConfigParser {
    static func parse(_ rawText: String, baseURL: URL? = nil) throws -> TVBoxConfigParseResult {
        let cleaned = stripJSONComments(rawText)
        guard let data = cleaned.data(using: .utf8),
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw NSError(domain: "TVBoxConfigParser", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "无法解析 TVBox JSON 配置，请确认链接返回标准 JSON 内容。"
            ])
        }

        var liveEntries: [TVBoxLiveEntry] = []
        var inlineChannels: [LiveChannel] = []
        var defaultEPG: String?

        if let lives = json["lives"] as? [[String: Any]] {
            for entry in lives {
                // Case 1: Inline TVBox live group format: {"group": "央视", "channels": [{"name": "...", "urls": [...]}]}
                if let channels = entry["channels"] as? [[String: Any]] {
                    let groupName = (entry["group"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    let group = (groupName?.isEmpty == false) ? groupName! : "直播"
                    for ch in channels {
                        guard let name = ch["name"] as? String, !name.isEmpty else { continue }
                        let rawURLs = ch["urls"] as? [String] ?? []
                        var eps: [StreamEndpoint] = []
                        for raw in rawURLs {
                            eps.append(contentsOf: PlaylistParser.parseEndpoints(rawURLList: raw, inheritedHeaders: [:]))
                        }
                        if !eps.isEmpty {
                            inlineChannels.append(LiveChannel(name: name, group: group, endpoints: eps))
                        }
                    }
                    continue
                }

                // Case 2: Standard TVBox live subscription format: {"name": "...", "type": 0, "url": "...", "epg": "...", "ua": "..."}
                let name = (entry["name"] as? String) ?? "直播源"
                let rawURL = (entry["url"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolvedURL = rawURL.map { resolveURL($0, relativeTo: baseURL) }
                let rawEPG = (entry["epg"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let resolvedEPG = rawEPG.flatMap { $0.isEmpty ? nil : resolveURL($0, relativeTo: baseURL) }
                if defaultEPG == nil, let resolvedEPG {
                    defaultEPG = resolvedEPG
                }

                var headers: [String: String] = [:]
                let ua = (entry["ua"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let ua, !ua.isEmpty {
                    headers["User-Agent"] = ua
                }
                if let headerDict = entry["header"] as? [String: String] {
                    for (k, v) in headerDict {
                        headers[k] = v
                    }
                }

                liveEntries.append(TVBoxLiveEntry(
                    name: name,
                    url: resolvedURL,
                    epg: resolvedEPG,
                    ua: ua,
                    headers: headers,
                    inlineChannels: []
                ))
            }
        }

        var vodSites: [VodSite] = []
        var skippedSpiderCount = 0

        if let sites = json["sites"] as? [[String: Any]] {
            for site in sites {
                let typeInt = (site["type"] as? Int) ?? Int((site["type"] as? String) ?? "") ?? -1
                let key = (site["key"] as? String) ?? UUID().uuidString
                let name = (site["name"] as? String) ?? key
                let api = (site["api"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let searchable = ((site["searchable"] as? Int) ?? 1) != 0
                let playURL = site["playUrl"] as? String

                var headers: [String: String] = [:]
                if let headerObj = site["header"] as? [String: String] {
                    headers = headerObj
                }

                if (typeInt == 0 || typeInt == 1),
                   api.lowercased().hasPrefix("http") {
                    let apiType: VodAPIType = (typeInt == 0) ? .xml : .json
                    vodSites.append(VodSite(
                        key: key,
                        name: name,
                        apiURL: api,
                        apiType: apiType,
                        searchable: searchable,
                        playURL: playURL,
                        headers: headers
                    ))
                } else if typeInt == 3 || typeInt == 4 {
                    skippedSpiderCount += 1
                }
            }
        }

        return TVBoxConfigParseResult(
            liveEntries: liveEntries,
            inlineChannels: inlineChannels,
            vodSites: vodSites,
            skippedSpiderCount: skippedSpiderCount,
            defaultEPG: defaultEPG
        )
    }

    static func resolveURL(_ raw: String, relativeTo baseURL: URL?) -> String {
        if raw.lowercased().hasPrefix("http://") || raw.lowercased().hasPrefix("https://") {
            return raw
        }
        if let baseURL, let resolved = URL(string: raw, relativeTo: baseURL)?.absoluteURL {
            return resolved.absoluteString
        }
        return raw
    }

    /// Strips `//` and `/* ... */` comments only outside JSON string literals,
    /// preserving `http://` and `https://` URLs inside strings.
    static func stripJSONComments(_ input: String) -> String {
        let cleanedBOM = input.replacingOccurrences(of: "\u{FEFF}", with: "")
        var result = String()
        result.reserveCapacity(cleanedBOM.count)

        var idx = cleanedBOM.startIndex
        let end = cleanedBOM.endIndex
        var inString = false
        var escaped = false

        while idx < end {
            let ch = cleanedBOM[idx]
            let next = cleanedBOM.index(after: idx)

            if inString {
                result.append(ch)
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
                idx = next
                continue
            }

            if ch == "\"" {
                inString = true
                result.append(ch)
                idx = next
                continue
            }

            if ch == "/", next < end {
                let nextCh = cleanedBOM[next]
                if nextCh == "/" {
                    // Skip line comment until newline
                    var cursor = cleanedBOM.index(after: next)
                    while cursor < end && cleanedBOM[cursor] != "\n" && cleanedBOM[cursor] != "\r" {
                        cursor = cleanedBOM.index(after: cursor)
                    }
                    idx = cursor
                    continue
                } else if nextCh == "*" {
                    // Skip block comment until */
                    var cursor = cleanedBOM.index(after: next)
                    while cursor < end {
                        let c1 = cleanedBOM[cursor]
                        let cNext = cleanedBOM.index(after: cursor)
                        if c1 == "*", cNext < end, cleanedBOM[cNext] == "/" {
                            cursor = cleanedBOM.index(after: cNext)
                            break
                        }
                        cursor = cNext
                    }
                    idx = cursor
                    continue
                }
            }

            result.append(ch)
            idx = next
        }

        return result
    }
}
