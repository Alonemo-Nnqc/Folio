import FolioCore
import Foundation

/// The local service browser extensions talk to (WEB-01): a tiny HTTP/1.1 dialect on 127.0.0.1.
public enum ConnectorProtocol {
    public static let port: UInt16 = 23120
    /// Required on every write so plain web forms (which cannot set headers) cannot post to Folio.
    public static let header = "x-folio-connector"
    public static let maxBodyBytes = 300 * 1024 * 1024

    public struct Request: Sendable {
        public var method: String
        public var path: String
        public var query: [String: String]
        /// Lowercased names.
        public var headers: [String: String]
        public var body: Data
    }

    public struct Response: Sendable {
        public var status: Int
        public var body: Data
        public var contentType = "application/json; charset=utf-8"
        public var headers: [String: String] = [:]

        public init(status: Int, body: Data, contentType: String = "application/json; charset=utf-8", headers: [String: String] = [:]) {
            self.status = status
            self.body = body
            self.contentType = contentType
            self.headers = headers
        }

        public static func json(_ value: JSONValue, status: Int = 200) -> Response {
            Response(status: status, body: Data(value.encoded().utf8))
        }

        public static func error(_ message: String, status: Int) -> Response {
            .json(["error": .string(message)], status: status)
        }

        public func serialized() -> Data {
            let reason = [200: "OK", 204: "No Content", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
                          413: "Payload Too Large", 500: "Internal Server Error", 503: "Service Unavailable"][status] ?? "OK"
            var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
            for (name, value) in headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
            return Data((head + "\r\n").utf8) + body
        }
    }

    public enum ParseResult: Sendable {
        case incomplete
        case invalid(String)
        case complete(Request)
    }

    /// Parses one request from the bytes received so far.
    public static func parse(_ data: Data) -> ParseResult {
        guard let end = data.firstRange(of: Data("\r\n\r\n".utf8)) else {
            return data.count > 64 * 1024 ? .invalid("headers too large") : .incomplete
        }
        guard let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return .invalid("bad headers") }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return .invalid("bad request line") }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length <= maxBodyBytes else { return .invalid("body too large") }
        let bodyStart = end.upperBound
        guard data.count - bodyStart >= length else { return .incomplete }
        let target = String(requestLine[1])
        let components = URLComponents(string: "http://localhost" + target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return .complete(Request(method: String(requestLine[0]).uppercased(), path: components?.path ?? target, query: query,
                                 headers: headers, body: data[bodyStart..<(bodyStart + length)]))
    }

    /// Extension pages may call Folio; web pages may not. Requests without an Origin come from local
    /// processes (curl, folio-cli), which could reach the library anyway.
    public static func isAllowedOrigin(_ origin: String?) -> Bool {
        guard let origin, !origin.isEmpty, origin != "null" else { return true }
        return ["chrome-extension://", "safari-web-extension://", "moz-extension://", "ms-browser-extension://"]
            .contains { origin.hasPrefix($0) }
    }

    /// CORS headers for an allowed extension origin.
    public static func corsHeaders(origin: String?) -> [String: String] {
        guard let origin, isAllowedOrigin(origin), !origin.isEmpty else { return [:] }
        return ["Access-Control-Allow-Origin": origin,
                "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
                "Access-Control-Allow-Headers": "Content-Type, X-Folio-Connector",
                "Access-Control-Max-Age": "600",
                "Vary": "Origin"]
    }

    /// Checks origin and the connector header; nil when the request may proceed.
    public static func reject(_ request: Request) -> Response? {
        let origin = request.headers["origin"]
        guard isAllowedOrigin(origin) else { return .error("Only Folio's browser extension may use this service.", status: 403) }
        if request.method == "POST", request.headers[header] == nil {
            return .error("Missing X-Folio-Connector header.", status: 403)
        }
        return nil
    }

    // MARK: Page metadata

    /// What the extension read from a page (WEB-02), mapped to Folio's fields.
    public static func metadata(from item: JSONValue) -> Metadata? {
        guard let title = item["title"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return nil
        }
        var m = Metadata(title: title)
        m.authors = (item["authors"]?.arrayValue ?? []).compactMap { author in
            if let name = author.stringValue { return parseName(name) }
            guard let family = author["family"]?.stringValue, !family.isEmpty else { return nil }
            return Author(family: family, given: author["given"]?.stringValue ?? "")
        }
        func text(_ key: String) -> String? {
            item[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        m.date = text("date")
        m.year = item["year"]?.intValue ?? m.date.flatMap { Int($0.prefix(4)) }
        m.source = text("venue")
        m.volume = text("volume")
        m.issue = text("issue")
        m.pages = text("pages")
        m.publisher = text("publisher")
        m.doi = text("doi")?.lowercased().replacingOccurrences(of: "https://doi.org/", with: "").replacingOccurrences(of: "doi:", with: "")
        m.arxivId = text("arxiv")
        m.isbn = text("isbn")
        m.url = text("url")
        m.abstract = text("abstract")
        m.type = ItemType(rawValue: text("type") ?? "") ?? (m.arxivId != nil && m.source == nil ? .preprint : .journalArticle)
        if m.type == .preprint && m.source == nil && m.arxivId != nil { m.source = "arXiv" }
        return m
    }

    /// "Family, Given" or "Given Family".
    static func parseName(_ raw: String) -> Author? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if let comma = name.firstIndex(of: ",") {
            return Author(family: name[..<comma].trimmingCharacters(in: .whitespaces),
                          given: name[name.index(after: comma)...].trimmingCharacters(in: .whitespaces))
        }
        let parts = name.split(separator: " ")
        guard parts.count > 1 else { return Author(family: name) }
        return Author(family: String(parts.last!), given: parts.dropLast().joined(separator: " "))
    }

    /// Fills gaps in looked-up metadata with what the page said (abstract, URL, keywords stay with the page).
    public static func merge(resolved: Metadata, page: Metadata) -> Metadata {
        var merged = resolved
        if (merged.abstract ?? "").isEmpty { merged.abstract = page.abstract }
        if (merged.url ?? "").isEmpty { merged.url = page.url }
        if (merged.pages ?? "").isEmpty { merged.pages = page.pages }
        if (merged.volume ?? "").isEmpty { merged.volume = page.volume }
        if (merged.issue ?? "").isEmpty { merged.issue = page.issue }
        if merged.authors.isEmpty { merged.authors = page.authors }
        return merged
    }
}
