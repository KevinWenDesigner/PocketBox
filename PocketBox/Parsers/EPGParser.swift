import Foundation

enum EPGParser {
    /// Parses either XMLTV XML (including `.xml.gz`) or DIYP/TVBox JSON EPG payloads into a dictionary keyed by lowercase channel id/name.
    static func parse(data rawData: Data, fallbackChannelName: String? = nil) -> [String: [EPGProgram]] {
        let data = GzipDecoder.decompressIfNeeded(rawData)
        if let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           text.hasPrefix("{") || text.hasPrefix("[") {
            return parseDIYPJSON(data: data, fallbackChannelName: fallbackChannelName)
        }
        return parseXMLTV(data: data)
    }

    // MARK: - DIYP / TVBox JSON EPG

    private static func parseDIYPJSON(data: Data, fallbackChannelName: String?) -> [String: [EPGProgram]] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = obj["epg_data"] as? [[String: Any]]
        else {
            return [:]
        }

        let channelName = (obj["channel_name"] as? String) ?? fallbackChannelName ?? ""
        let key = channelName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return [:] }

        let dateStr = (obj["date"] as? String) ?? todayString()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        var programs: [EPGProgram] = []
        for item in list {
            guard let title = item["title"] as? String,
                  let startHM = item["start"] as? String,
                  let endHM = item["end"] as? String,
                  let startDate = formatter.date(from: "\(dateStr) \(startHM)"),
                  var endDate = formatter.date(from: "\(dateStr) \(endHM)")
            else { continue }

            if endDate <= startDate {
                endDate = Calendar.current.date(byAdding: .day, value: 1, to: endDate) ?? endDate
            }

            programs.append(EPGProgram(
                channelKey: key,
                title: title,
                start: startDate,
                end: endDate,
                description: item["desc"] as? String
            ))
        }

        return [key: programs.sorted { $0.start < $1.start }]
    }

    // MARK: - XMLTV EPG

    private static func parseXMLTV(data: Data) -> [String: [EPGProgram]] {
        let delegate = XMLTVDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()

        var grouped: [String: [EPGProgram]] = [:]
        for prog in delegate.programs {
            let idKey = prog.channelKey.lowercased()
            grouped[idKey, default: []].append(prog)

            if let displayNames = delegate.channelDisplayNames[prog.channelKey] {
                for alias in displayNames {
                    let aliasKey = alias.lowercased()
                    if aliasKey != idKey {
                        grouped[aliasKey, default: []].append(prog)
                    }
                }
            }
        }

        for (k, list) in grouped {
            grouped[k] = list.sorted { $0.start < $1.start }
        }
        return grouped
    }

    private static func todayString() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyy-MM-dd"
        return df.string(from: Date())
    }
}

private final class XMLTVDelegate: NSObject, XMLParserDelegate {
    var programs: [EPGProgram] = []
    var channelDisplayNames: [String: [String]] = [:]

    private var currentElement = ""
    private var buffer = ""
    private var currentChannelID = ""
    private var inChannel = false
    private var inProgramme = false
    private var progStart: Date?
    private var progStop: Date?
    private var progChannel = ""
    private var progTitle = ""
    private var progDesc = ""

    private static let dateFormats: [DateFormatter] = {
        let formats = ["yyyyMMddHHmmss Z", "yyyyMMddHHmmss ZZZZZ", "yyyyMMddHHmmss"]
        return formats.map { fmt in
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.dateFormat = fmt
            return df
        }
    }()

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName.lowercased()
        buffer = ""

        if currentElement == "channel" {
            inChannel = true
            currentChannelID = attributeDict["id"] ?? ""
        } else if currentElement == "programme" {
            inProgramme = true
            progChannel = attributeDict["channel"] ?? ""
            progStart = parseXMLTVDate(attributeDict["start"])
            progStop = parseXMLTVDate(attributeDict["stop"])
            progTitle = ""
            progDesc = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        buffer.append(string)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        let name = elementName.lowercased()
        let val = buffer.trimmingCharacters(in: .whitespacesAndNewlines)

        if inChannel {
            if name == "display-name", !currentChannelID.isEmpty, !val.isEmpty {
                channelDisplayNames[currentChannelID, default: []].append(val)
            } else if name == "channel" {
                inChannel = false
            }
        } else if inProgramme {
            switch name {
            case "title": progTitle = val
            case "desc": progDesc = val
            case "programme":
                if !progChannel.isEmpty, !progTitle.isEmpty, let start = progStart, let stop = progStop {
                    programs.append(EPGProgram(
                        channelKey: progChannel,
                        title: progTitle,
                        start: start,
                        end: stop,
                        description: progDesc.isEmpty ? nil : progDesc
                    ))
                }
                inProgramme = false
            default:
                break
            }
        }
    }

    private func parseXMLTVDate(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        for df in Self.dateFormats {
            if let d = df.date(from: raw) {
                return d
            }
        }
        return nil
    }
}
