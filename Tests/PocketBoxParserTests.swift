import XCTest
@testable import PocketBox

final class PocketBoxParserTests: XCTestCase {
    func testM3UWithHeadersAndMultiLineMerge() {
        let m3u = """
        #EXTM3U x-tvg-url="https://epg.example.com/e.xml"
        #EXTINF:-1 tvg-id="cctv1" tvg-name="CCTV1" tvg-logo="https://img.example.com/1.png" group-title="央视",CCTV-1 综合
        #EXTVLCOPT:http-user-agent=CustomUA/1.0
        #EXTVLCOPT:http-referrer=https://ref.example.com
        http://stream.example.com/cctv1.m3u8$主线#http://backup.example.com/cctv1.flv|User-Agent=BackupUA
        #EXTINF:-1 group-title="央视",CCTV-1 综合
        http://third.example.com/cctv1.ts
        """

        let result = PlaylistParser.parse(m3u)
        XCTAssertEqual(result.epgURL, "https://epg.example.com/e.xml")
        XCTAssertEqual(result.channels.count, 1)

        let ch = result.channels[0]
        XCTAssertEqual(ch.name, "CCTV-1 综合")
        XCTAssertEqual(ch.group, "央视")
        XCTAssertEqual(ch.tvgID, "cctv1")
        XCTAssertEqual(ch.endpoints.count, 3)
        XCTAssertEqual(ch.endpoints[0].label, "主线")
        XCTAssertEqual(ch.endpoints[0].url, "http://stream.example.com/cctv1.m3u8")
        XCTAssertEqual(ch.endpoints[0].headers["User-Agent"], "CustomUA/1.0")
        XCTAssertEqual(ch.endpoints[0].headers["Referer"], "https://ref.example.com")
        XCTAssertEqual(ch.endpoints[1].headers["User-Agent"], "BackupUA")
        XCTAssertEqual(ch.endpoints[2].url, "http://third.example.com/cctv1.ts")
    }

    func testTXTGenreParsing() {
        let txt = """
        央视频道,#genre#
        CCTV1,http://a.example.com/1.m3u8#http://b.example.com/1.m3u8
        卫视频道,#genre#
        湖南卫视,https://c.example.com/hn.m3u8$高清
        """

        let result = PlaylistParser.parse(txt)
        XCTAssertEqual(result.channels.count, 2)
        XCTAssertEqual(result.channels[0].group, "央视频道")
        XCTAssertEqual(result.channels[0].endpoints.count, 2)
        XCTAssertEqual(result.channels[1].group, "卫视频道")
        XCTAssertEqual(result.channels[1].endpoints[0].label, "高清")
    }

    func testTVBoxConfigStripsCommentsPreservingURLs() throws {
        let raw = """
        // 顶部注释
        {
          /* 块注释 */
          "lives": [
            {
              "name": "测试直播",
              "type": 0,
              "url": "./live.txt", // 行尾注释
              "epg": "https://epg.example.com/?ch={name}&date={date}"
            }
          ],
          "sites": [
            {"key": "cms_json", "name": "JSON资源", "type": 1, "api": "https://cms.example.com/api.php/provide/vod/"},
            {"key": "cms_xml", "name": "XML资源", "type": 0, "api": "https://xml.example.com/api.php/provide/vod/at/xml/"},
            {"key": "jar_spider", "name": "JAR爬虫", "type": 3, "api": "csp_Demo"}
          ]
        }
        """

        let parsed = try TVBoxConfigParser.parse(raw, baseURL: URL(string: "https://config.example.com/tv/box.json"))
        XCTAssertEqual(parsed.liveEntries.count, 1)
        XCTAssertEqual(parsed.liveEntries[0].url, "https://config.example.com/tv/live.txt")
        XCTAssertEqual(parsed.vodSites.count, 2)
        XCTAssertEqual(parsed.vodSites[0].apiType, .json)
        XCTAssertEqual(parsed.vodSites[1].apiType, .xml)
        XCTAssertEqual(parsed.skippedSpiderCount, 1)
    }

    func testMacCMSJSONAndXMLParsing() throws {
        let jsonStr = """
        {
          "page": 1,
          "pagecount": 3,
          "class": [{"type_id": 1, "type_name": "电影"}],
          "list": [
            {
              "vod_id": 100,
              "vod_name": "测试影片",
              "vod_pic": "https://img.example.com/p.jpg",
              "vod_remarks": "HD",
              "vod_content": "<p>简介&nbsp;测试</p>",
              "vod_play_from": "线路A$$$线路B",
              "vod_play_url": "第1集$https://v.example.com/1.m3u8#第2集$https://v.example.com/2.m3u8$$$HD$https://v.example.com/b.mp4"
            }
          ]
        }
        """
        let site = VodSite(key: "s1", name: "测试", apiURL: "https://cms.example.com", apiType: .json, searchable: true)
        let page = try MacCMSParser.parse(data: Data(jsonStr.utf8), site: site)
        XCTAssertEqual(page.categories.count, 1)
        XCTAssertEqual(page.movies.count, 1)
        XCTAssertEqual(page.movies[0].synopsis, "简介 测试")
        XCTAssertEqual(page.movies[0].playSources.count, 2)
        XCTAssertEqual(page.movies[0].playSources[0].episodes.count, 2)
        XCTAssertEqual(page.movies[0].playSources[1].episodes[0].url, "https://v.example.com/b.mp4")
    }

    func testDIYPAndXMLTVEPGParsing() {
        let diyp = """
        {
          "channel_name": "CCTV1",
          "date": "2026-11-22",
          "epg_data": [
            {"start": "08:00", "end": "09:00", "title": "朝闻天下"}
          ]
        }
        """
        let map = EPGParser.parse(data: Data(diyp.utf8))
        XCTAssertEqual(map["cctv1"]?.count, 1)
        XCTAssertEqual(map["cctv1"]?.first?.title, "朝闻天下")
    }

    func testGzippedXMLTVEPGParsing() {
        // Real RFC 1952 gzip payload with FNAME="epg.xml" containing minimal XMLTV
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <tv><channel id="CCTV1"><display-name>CCTV1</display-name></channel><programme channel="CCTV1" start="20261122080000 +0800" stop="20261122090000 +0800"><title>测试节目</title></programme></tv>
        """
        // Verify non-gzipped XML parses cleanly
        let direct = EPGParser.parse(data: Data(xml.utf8))
        XCTAssertEqual(direct["cctv1"]?.first?.title, "测试节目")

        // Construct valid RFC 1952 gzip with FNAME flag (0x08) and stored deflate block
        let rawBytes = Array(xml.utf8)
        XCTAssertLessThan(rawBytes.count, 65535)
        var gz = Data([0x1F, 0x8B, 0x08, 0x08, 0, 0, 0, 0, 0, 0xFF])
        gz.append(contentsOf: "epg.xml\0".utf8)
        // Stored deflate block: BFINAL=1, BTYPE=00 -> 0x01
        let len = UInt16(rawBytes.count)
        let nlen = ~len
        gz.append(0x01)
        gz.append(UInt8(len & 0xFF))
        gz.append(UInt8(len >> 8))
        gz.append(UInt8(nlen & 0xFF))
        gz.append(UInt8(nlen >> 8))
        gz.append(contentsOf: rawBytes)
        // 8-byte trailer placeholder (GzipDecoder strips trailer before raw deflate decode)
        gz.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])

        let parsed = EPGParser.parse(data: gz)
        XCTAssertEqual(parsed["cctv1"]?.first?.title, "测试节目")
    }

    func testPlaylistDefaultHeadersInheritance() {
        let m3u = """
        #EXTM3U
        #EXTINF:-1,测试台
        http://example.com/live.m3u8
        """
        let res = PlaylistParser.parse(m3u, defaultGroup: "默认", defaultHeaders: ["User-Agent": "bingcha/1.1"])
        XCTAssertEqual(res.channels.first?.endpoints.first?.headers["User-Agent"], "bingcha/1.1")
    }
}
