import Foundation

struct PlaylistParseResult {
    var channels: [LiveChannel]
    var epgURL: String?
}

enum PlaylistParser {
    static func parse(_ content: String, defaultGroup: String = "默认分组") -> PlaylistParseResult {
        let normalized = content
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return PlaylistParseResult(channels: [], epgURL: nil)
        }

        if normalized.contains("#EXTM3U") || normalized.contains("#EXTINF") {
            return parseM3U(normalized, defaultGroup: defaultGroup)
        } else {
            return parseTXT(normalized, defaultGroup: defaultGroup)
        }
    }

    // MARK: - M3U / M3U8 Playlist

    private static func parseM3U(_ text: String, defaultGroup: String) -> PlaylistParseResult {
        var epgURL: String?
        var orderedKeys: [String] = []
        var channelMap: [String: LiveChannel] = [:]

        var pendingName: String?
        var pendingGroup: String = defaultGroup
        var pendingLogo: String?
        var pendingTvgID: String?
        var pendingTvgName: String?
        var pendingHeaders: [String: String] = [:]

        let lines = text.components(separatedBy: "\n")
        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if line.hasPrefix("#EXTM3U") {
                if epgURL == nil {
                    let rawEPG = extractAttribute("x-tvg-url", from: line)
                        ?? extractAttribute("url-tvg", from: line)
                        ?? extractAttribute("tvg-url", from: line)
                    if let rawEPG {
                        epgURL = rawEPG
                            .components(separatedBy: ",")
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .first { !$0.isEmpty }
                    }
                }
                continue
            }

            if line.hasPrefix("#EXTINF") {
                pendingName = extractChannelTitle(fromExtInf: line)
                pendingGroup = extractAttribute("group-title", from: line) ?? defaultGroup
                if pendingGroup.isEmpty { pendingGroup = defaultGroup }
                pendingLogo = extractAttribute("tvg-logo", from: line)
                pendingTvgID = extractAttribute("tvg-id", from: line)
                pendingTvgName = extractAttribute("tvg-name", from: line)
                if let ua = extractAttribute("http-user-agent", from: line), !ua.isEmpty {
                    pendingHeaders["User-Agent"] = ua
                }
                if let ref = extractAttribute("http-referrer", from: line) ?? extractAttribute("http-referer", from: line), !ref.isEmpty {
                    pendingHeaders["Referer"] = ref
                }
                continue
            }

            if line.hasPrefix("#EXTVLCOPT:") {
                let opt = String(line.dropFirst("#EXTVLCOPT:".count)).trimmingCharacters(in: .whitespaces)
                if opt.lowercased().hasPrefix("http-user-agent=") {
                    let val = String(opt.dropFirst("http-user-agent=".count))
                    if !val.isEmpty { pendingHeaders["User-Agent"] = val }
                } else if opt.lowercased().hasPrefix("http-referrer=") {
                    let val = String(opt.dropFirst("http-referrer=".count))
                    if !val.isEmpty { pendingHeaders["Referer"] = val }
                } else if opt.lowercased().hasPrefix("http-referer=") {
                    let val = String(opt.dropFirst("http-referer=".count))
                    if !val.isEmpty { pendingHeaders["Referer"] = val }
                }
                continue
            }

            if line.hasPrefix("#EXTGRP:") {
                let grp = String(line.dropFirst("#EXTGRP:".count)).trimmingCharacters(in: .whitespaces)
                if !grp.isEmpty { pendingGroup = grp }
                continue
            }

            if line.hasPrefix("#") {
                continue
            }

            // Stream URL line
            let endpoints = parseEndpoints(rawURLList: line, inheritedHeaders: pendingHeaders)
            if !endpoints.isEmpty {
                let name = (pendingName?.isEmpty == false)
                    ? pendingName!
                    : (pendingTvgName?.isEmpty == false ? pendingTvgName! : "未命名频道")
                let key = "\(pendingGroup)::\(name)"
                if var existing = channelMap[key] {
                    appendUniqueEndpoints(endpoints, to: &existing)
                    if existing.logo == nil { existing.logo = pendingLogo }
                    if existing.tvgID == nil { existing.tvgID = pendingTvgID }
                    if existing.tvgName == nil { existing.tvgName = pendingTvgName }
                    channelMap[key] = existing
                } else {
                    orderedKeys.append(key)
                    channelMap[key] = LiveChannel(
                        id: key,
                        name: name,
                        group: pendingGroup,
                        endpoints: endpoints,
                        logo: pendingLogo,
                        tvgID: pendingTvgID,
                        tvgName: pendingTvgName
                    )
                }
            }

            // Reset per-channel metadata
            pendingName = nil
            pendingGroup = defaultGroup
            pendingLogo = nil
            pendingTvgID = nil
            pendingTvgName = nil
            pendingHeaders = [:]
        }

        let channels = orderedKeys.compactMap { channelMap[$0] }
        return PlaylistParseResult(channels: channels, epgURL: epgURL)
    }

    // MARK: - TVBox / DIYP TXT (#genre#)

    private static func parseTXT(_ text: String, defaultGroup: String) -> PlaylistParseResult {
        var currentGroup = defaultGroup
        var orderedKeys: [String] = []
        var channelMap: [String: LiveChannel] = [:]

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") {
                continue
            }

            if line.contains("#genre#") {
                let groupName = line
                    .components(separatedBy: ",")
                    .first?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                currentGroup = groupName.isEmpty ? defaultGroup : groupName
                continue
            }

            guard let commaIndex = line.firstIndex(of: ",") else { continue }
            let name = String(line[..<commaIndex]).trimmingCharacters(in: .whitespacesAndNewlines)
            let urlPart = String(line[line.index(after: commaIndex)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !urlPart.isEmpty else { continue }

            let endpoints = parseEndpoints(rawURLList: urlPart, inheritedHeaders: [:])
            guard !endpoints.isEmpty else { continue }

            let key = "\(currentGroup)::\(name)"
            if var existing = channelMap[key] {
                appendUniqueEndpoints(endpoints, to: &existing)
                channelMap[key] = existing
            } else {
                orderedKeys.append(key)
                channelMap[key] = LiveChannel(
                    id: key,
                    name: name,
                    group: currentGroup,
                    endpoints: endpoints
                )
            }
        }

        let channels = orderedKeys.compactMap { channelMap[$0] }
        return PlaylistParseResult(channels: channels, epgURL: nil)
    }

    // MARK: - Helpers

    static func parseEndpoints(rawURLList: String, inheritedHeaders: [String: String]) -> [StreamEndpoint] {
        // TVBox TXT/M3U often separates backup URLs with `#`
        let candidates = rawURLList
            .components(separatedBy: "#")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var results: [StreamEndpoint] = []
        for (idx, raw) in candidates.enumerated() {
            var working = raw
            var label = "线路 \(idx + 1)"
            var headers = inheritedHeaders

            // Inline pipe headers: http://.../live.m3u8|User-Agent=xxx&Referer=yyy
            if let pipeIndex = working.firstIndex(of: "|") {
                let headerPart = String(working[working.index(after: pipeIndex)...])
                working = String(working[..<pipeIndex]).trimmingCharacters(in: .whitespaces)
                let pairs = headerPart.components(separatedBy: "&")
                for pair in pairs {
                    guard let eq = pair.firstIndex(of: "=") else { continue }
                    let k = String(pair[..<eq]).trimmingCharacters(in: .whitespaces)
                    let v = String(pair[pair.index(after: eq)...])
                        .trimmingCharacters(in: .whitespaces)
                        .removingPercentEncoding ?? String(pair[pair.index(after: eq)...])
                    if !k.isEmpty, !v.isEmpty {
                        headers[normalizeHeaderKey(k)] = v
                    }
                }
            }

            // Optional `$线路名` suffix (only if suffix has no `/`, `=`, `&`)
            if let dollarIndex = working.lastIndex(of: "$") {
                let suffix = String(working[working.index(after: dollarIndex)...]).trimmingCharacters(in: .whitespaces)
                let prefix = String(working[..<dollarIndex]).trimmingCharacters(in: .whitespaces)
                if !prefix.isEmpty, !suffix.isEmpty,
                   !suffix.contains("/"), !suffix.contains("="), !suffix.contains("&") {
                    working = prefix
                    label = suffix
                }
            }

            guard isValidStreamURL(working) else { continue }
            results.append(StreamEndpoint(label: label, url: working, headers: headers))
        }
        return results
    }

    private static func appendUniqueEndpoints(_ incoming: [StreamEndpoint], to channel: inout LiveChannel) {
        for ep in incoming {
            if !channel.endpoints.contains(where: { $0.url == ep.url && $0.headers == ep.headers }) {
                let label = ep.label.hasPrefix("线路 ")
                    ? "线路 \(channel.endpoints.count + 1)"
                    : ep.label
                channel.endpoints.append(StreamEndpoint(label: label, url: ep.url, headers: ep.headers))
            }
        }
    }

    private static func isValidStreamURL(_ s: String) -> Bool {
        let lower = s.lowercased()
        return lower.hasPrefix("http://")
            || lower.hasPrefix("https://")
            || lower.hasPrefix("rtmp://")
            || lower.hasPrefix("rtsp://")
            || lower.hasPrefix("udp://")
            || lower.hasPrefix("rtp://")
            || lower.hasPrefix("mms://")
            || lower.hasPrefix("file://")
    }

    private static func normalizeHeaderKey(_ raw: String) -> String {
        switch raw.lowercased() {
        case "user-agent", "ua": return "User-Agent"
        case "referer", "referrer": return "Referer"
        case "origin": return "Origin"
        case "cookie": return "Cookie"
        default: return raw
        }
    }

    private static func extractAttribute(_ name: String, from line: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = #"(?i)(?:^|[\s,])\#(escaped)\s*=\s*(?:"([^"]*)"|([^\s,]+))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..., in: line)
        guard let match = regex.firstMatch(in: line, range: range) else { return nil }
        for groupIdx in [1, 2] {
            if let r = Range(match.range(at: groupIdx), in: line) {
                let val = String(line[r]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !val.isEmpty { return val }
            }
        }
        return nil
    }

    private static func extractChannelTitle(fromExtInf line: String) -> String? {
        var inQuotes = false
        var lastComma: String.Index?
        for idx in line.indices {
            let ch = line[idx]
            if ch == "\"" {
                inQuotes.toggle()
            } else if ch == "," && !inQuotes {
                lastComma = idx
            }
        }
        guard let comma = lastComma else { return nil }
        let title = String(line[line.index(after: comma)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }
}
