import Foundation

struct MacCMSPageResult {
    var categories: [VodCategory]
    var movies: [VodMovie]
    var page: Int
    var pageCount: Int
}

enum MacCMSParser {
    static func parse(data: Data, site: VodSite) throws -> MacCMSPageResult {
        if site.apiType == .json {
            return try parseJSON(data: data, site: site)
        } else {
            return try parseXML(data: data, site: site)
        }
    }

    // MARK: - JSON (MacCMS v10)

    private static func parseJSON(data: Data, site: VodSite) throws -> MacCMSPageResult {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "MacCMSParser", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "点播接口返回的 JSON 格式无效"
            ])
        }

        var categories: [VodCategory] = []
        if let classes = root["class"] as? [[String: Any]] {
            for cls in classes {
                let idStr: String
                if let i = cls["type_id"] as? Int {
                    idStr = String(i)
                } else if let s = cls["type_id"] as? String {
                    idStr = s
                } else {
                    continue
                }
                let name = (cls["type_name"] as? String) ?? "分类"
                categories.append(VodCategory(id: idStr, name: name))
            }
        }

        var movies: [VodMovie] = []
        if let list = root["list"] as? [[String: Any]] {
            for item in list {
                let vodID: String
                if let i = item["vod_id"] as? Int {
                    vodID = String(i)
                } else if let s = item["vod_id"] as? String {
                    vodID = s
                } else {
                    continue
                }

                let title = (item["vod_name"] as? String) ?? "未命名"
                let pic = (item["vod_pic"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                let remarks = item["vod_remarks"] as? String
                let year = (item["vod_year"] as? String) ?? (item["vod_year"] as? Int).map(String.init)
                let area = item["vod_area"] as? String
                let typeName = item["type_name"] as? String
                let director = item["vod_director"] as? String
                let actor = item["vod_actor"] as? String
                let rawContent = (item["vod_content"] as? String) ?? (item["vod_blurb"] as? String)
                let synopsis = rawContent.map(stripHTMLTags)

                let playFrom = (item["vod_play_from"] as? String) ?? ""
                let playURL = (item["vod_play_url"] as? String) ?? ""
                let playSources = parsePlaySources(playFrom: playFrom, playURL: playURL, headers: site.headers)

                movies.append(VodMovie(
                    siteKey: site.key,
                    vodID: vodID,
                    title: title,
                    posterURL: pic?.isEmpty == true ? nil : pic,
                    remarks: remarks,
                    year: year,
                    area: area,
                    typeName: typeName,
                    director: director,
                    actor: actor,
                    synopsis: synopsis,
                    playSources: playSources
                ))
            }
        }

        let page = (root["page"] as? Int) ?? Int((root["page"] as? String) ?? "1") ?? 1
        let pageCount = (root["pagecount"] as? Int) ?? Int((root["pagecount"] as? String) ?? "1") ?? 1

        return MacCMSPageResult(categories: categories, movies: movies, page: page, pageCount: pageCount)
    }

    // MARK: - XML (MacCMS / SeaCMS XML)

    private static func parseXML(data: Data, site: VodSite) throws -> MacCMSPageResult {
        let delegate = MacCMSXMLDelegate(site: site)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return MacCMSPageResult(
            categories: delegate.categories,
            movies: delegate.movies,
            page: delegate.page,
            pageCount: delegate.pageCount
        )
    }

    // MARK: - Shared Play Source Splitter (`$$$` / `#` / `$`)

    static func parsePlaySources(playFrom: String, playURL: String, headers: [String: String]) -> [VodPlaySource] {
        guard !playURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let fromList = playFrom.components(separatedBy: "$$$")
        let urlGroups = playURL.components(separatedBy: "$$$")

        var sources: [VodPlaySource] = []
        for (index, groupStr) in urlGroups.enumerated() {
            let sourceName: String
            if index < fromList.count {
                let candidate = fromList[index].trimmingCharacters(in: .whitespacesAndNewlines)
                sourceName = candidate.isEmpty ? "线路 \(index + 1)" : candidate
            } else {
                sourceName = "线路 \(index + 1)"
            }

            let episodes = parseEpisodeGroup(groupStr, headers: headers)
            if !episodes.isEmpty {
                sources.append(VodPlaySource(name: sourceName, episodes: episodes))
            }
        }
        return sources
    }

    private static func parseEpisodeGroup(_ rawGroup: String, headers: [String: String]) -> [VodEpisode] {
        let items = rawGroup
            .components(separatedBy: "#")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var episodes: [VodEpisode] = []
        for (idx, item) in items.enumerated() {
            let parts = item.components(separatedBy: "$")
            let name: String
            let url: String
            if parts.count >= 2 {
                name = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                url = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                name = "第\(idx + 1)集"
                url = item
            }
            guard !url.isEmpty else { continue }
            episodes.append(VodEpisode(
                name: name.isEmpty ? "第\(idx + 1)集" : name,
                url: url,
                headers: headers
            ))
        }
        return episodes
    }

    private static func stripHTMLTags(_ raw: String) -> String {
        raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class MacCMSXMLDelegate: NSObject, XMLParserDelegate {
    let site: VodSite
    var categories: [VodCategory] = []
    var movies: [VodMovie] = []
    var page = 1
    var pageCount = 1

    private var currentElement = ""
    private var buffer = ""
    private var currentTypeID: String?
    private var inClass = false
    private var inVideo = false

    private var vodID = ""
    private var vodName = ""
    private var vodPic = ""
    private var vodNote = ""
    private var vodYear = ""
    private var vodArea = ""
    private var vodType = ""
    private var vodDirector = ""
    private var vodActor = ""
    private var vodDes = ""
    private var currentFlag = ""
    private var playFlags: [String] = []
    private var playGroups: [String] = []

    init(site: VodSite) {
        self.site = site
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName.lowercased()
        buffer = ""

        switch currentElement {
        case "list":
            if let p = attributeDict["page"], let pi = Int(p) { page = pi }
            if let pc = attributeDict["pagecount"], let pci = Int(pc) { pageCount = pci }
        case "class":
            inClass = true
        case "ty":
            currentTypeID = attributeDict["id"]
        case "video":
            inVideo = true
            vodID = ""; vodName = ""; vodPic = ""; vodNote = ""
            vodYear = ""; vodArea = ""; vodType = ""
            vodDirector = ""; vodActor = ""; vodDes = ""
            playFlags = []; playGroups = []
        case "dd":
            currentFlag = attributeDict["flag"] ?? "线路 \(playFlags.count + 1)"
        default:
            break
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

        if inClass && name == "ty", let id = currentTypeID, !val.isEmpty {
            categories.append(VodCategory(id: id, name: val))
        } else if name == "class" {
            inClass = false
        } else if inVideo {
            switch name {
            case "id": vodID = val
            case "name": vodName = val
            case "pic": vodPic = val
            case "note": vodNote = val
            case "year": vodYear = val
            case "area": vodArea = val
            case "type": vodType = val
            case "director": vodDirector = val
            case "actor": vodActor = val
            case "des": vodDes = val
            case "dd":
                if !val.isEmpty {
                    playFlags.append(currentFlag)
                    playGroups.append(val)
                }
            case "video":
                let sources = MacCMSParser.parsePlaySources(
                    playFrom: playFlags.joined(separator: "$$$"),
                    playURL: playGroups.joined(separator: "$$$"),
                    headers: site.headers
                )
                if !vodID.isEmpty {
                    movies.append(VodMovie(
                        siteKey: site.key,
                        vodID: vodID,
                        title: vodName.isEmpty ? "未命名" : vodName,
                        posterURL: vodPic.isEmpty ? nil : vodPic,
                        remarks: vodNote.isEmpty ? nil : vodNote,
                        year: vodYear.isEmpty ? nil : vodYear,
                        area: vodArea.isEmpty ? nil : vodArea,
                        typeName: vodType.isEmpty ? nil : vodType,
                        director: vodDirector.isEmpty ? nil : vodDirector,
                        actor: vodActor.isEmpty ? nil : vodActor,
                        synopsis: vodDes.isEmpty ? nil : vodDes,
                        playSources: sources
                    ))
                }
                inVideo = false
            default:
                break
            }
        }
    }
}
