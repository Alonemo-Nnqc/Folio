import Foundation

/// What easyScholar answered for one journal.
public enum EasyScholarResult: Sendable, Equatable {
    /// The journal's ranks (`data.officialRank.all`), dataset abbreviation → text.
    case found([String: String])
    /// easyScholar answered but lists nothing for the name.
    case notIndexed
    /// The SecretKey was refused (code 40002, "Key错误").
    case invalidKey(String)
    /// Too many requests: wait and ask again.
    case rateLimited(String)
    /// Any other refusal or an unreadable answer; worth retrying later.
    case failed(String)
}

/// easyScholar's open API (https://www.easyscholar.cc/console/user/open):
/// `GET https://www.easyscholar.cc/open/getPublicationRank?secretKey=…&publicationName=…`, answering
/// `{"code": 200, "msg": "SUCCESS", "data": {"officialRank": {"all": {…}, "select": {…}}, "customRank": {…}}}`
/// or `{"code": 40002, "msg": "Key错误", "data": null}`. The documentation asks for at most two requests a second.
public struct EasyScholarClient: Sendable {
    public static let endpoint = URL(string: "https://www.easyscholar.cc/open/getPublicationRank")!
    /// Where users find their SecretKey.
    public static let keyPage = URL(string: "https://www.easyscholar.cc/console/user/open")!

    let http: any HTTPClient

    public init(http: any HTTPClient = URLSessionHTTPClient(timeout: 15)) {
        self.http = http
    }

    /// Looks up one journal. Network failures throw `URLError`.
    public func lookup(_ journal: String, secretKey: String) async throws -> EasyScholarResult {
        let (data, status) = try await http.get(Self.url(journal: journal, secretKey: secretKey), headers: ["Accept": "application/json"])
        return Self.parse(data, status: status)
    }

    /// The request URL, both values encoded like JavaScript's encodeURIComponent (as the documentation asks), so "&"
    /// or "+" in a journal name cannot break the query.
    static func url(journal: String, secretKey: String) -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.percentEncodedQuery = "secretKey=\(encode(secretKey))&publicationName=\(encode(journal))"
        return components.url!
    }

    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    /// Reads an answer. Lenient: numbers and strings are both accepted as rank texts, `select` stands in for a
    /// missing `all`, and fields easyScholar adds later are kept as they are.
    public static func parse(_ data: Data, status: Int) -> EasyScholarResult {
        if status == 429 { return .rateLimited("HTTP 429") }
        // JSON5 tolerates the trailing commas of the documentation's examples, should the service ever send them.
        guard let object = try? JSONSerialization.jsonObject(with: data, options: .json5Allowed) as? [String: Any] else {
            // Not localised here (FolioMetadata has no strings): the app words it for the user.
            return .failed(status == 200 ? "unreadable response" : "HTTP \(status)")
        }
        let code = (object["code"] as? NSNumber)?.intValue ?? Int(object["code"] as? String ?? "") ?? status
        let message = (object["msg"] as? String ?? object["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if code != 200 {
            let lower = message.lowercased()
            if code == 40002 || (lower.contains("key") && (message.contains("错误") || message.contains("无效") || lower.contains("invalid"))) {
                return .invalidKey(message.isEmpty ? "Key错误" : message)
            }
            if code == 429 || message.contains("频繁") || message.contains("过快") || lower.contains("too many") || lower.contains("rate") {
                return .rateLimited(message)
            }
            return .failed(message.isEmpty ? "code \(code)" : "\(message)（\(code)）")
        }
        guard let payload = object["data"] as? [String: Any] else { return .notIndexed }
        let official = payload["officialRank"] as? [String: Any]
        let ranks = texts(official?["all"]) .merging(texts(official?["select"])) { all, _ in all }
        return ranks.isEmpty ? .notIndexed : .found(ranks)
    }

    private static func texts(_ value: Any?) -> [String: String] {
        guard let dictionary = value as? [String: Any] else { return [:] }
        var result: [String: String] = [:]
        for (key, value) in dictionary {
            let text: String? = switch value {
            case let string as String: string
            case let number as NSNumber: number.stringValue
            default: nil
            }
            if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { result[key] = text }
        }
        return result
    }
}
