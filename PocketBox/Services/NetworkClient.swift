import Foundation

enum NetworkError: LocalizedError {
    case invalidURL(String)
    case httpError(Int)
    case emptyResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL(let raw):
            return "无效的 URL 地址: \(raw)"
        case .httpError(let code):
            return "服务器返回异常状态码 HTTP \(code)"
        case .emptyResponse:
            return "服务器返回内容为空"
        }
    }
}

final class NetworkClient {
    static let shared = NetworkClient()

    private let session: URLSession

    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 18
        config.timeoutIntervalForResource = 45
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    func fetchData(url urlString: String, headers: [String: String] = [:], defaultUA: String? = nil) async throws -> Data {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw NetworkError.invalidURL(urlString)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 18

        var mergedHeaders = headers
        if mergedHeaders["User-Agent"] == nil {
            mergedHeaders["User-Agent"] = defaultUA ?? "Mozilla/5.0 (iPhone; CPU iPhone OS 15_8_8 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) PocketBox/1.0"
        }
        for (k, v) in mergedHeaders where !v.isEmpty {
            request.setValue(v, forHTTPHeaderField: k)
        }

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw NetworkError.httpError(http.statusCode)
        }
        if data.isEmpty {
            throw NetworkError.emptyResponse
        }
        return data
    }

    func fetchText(url urlString: String, headers: [String: String] = [:], defaultUA: String? = nil) async throws -> String {
        let data = try await fetchData(url: urlString, headers: headers, defaultUA: defaultUA)
        return Self.decodeText(data)
    }

    static func decodeText(_ data: Data) -> String {
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8
        }
        let gbEncoding = CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
        if let gbk = String(data: data, encoding: String.Encoding(rawValue: gbEncoding)) {
            return gbk
        }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }
}
