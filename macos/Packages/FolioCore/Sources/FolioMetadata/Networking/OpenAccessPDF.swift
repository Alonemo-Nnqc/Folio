import Foundation

/// Finds and downloads freely available PDFs (AI-01 `download_pdf`, `add_pdf` / `attach_file` with a URL).
public enum OpenAccessPDF {
    public enum Failure: Error, LocalizedError, Sendable {
        case notFound
        case network(String)
        case notPDF(String)

        public var errorDescription: String? {
            switch self {
            case .notFound: "No open-access PDF is known for this work."
            case .network(let detail): "Could not download the PDF: \(detail)"
            case .notPDF(let detail): "The download is not a PDF (\(detail)); the site may require signing in or a subscription."
            }
        }
    }

    /// The PDF of an arXiv paper, or the best open-access copy OpenAlex knows for a DOI.
    public static func locate(doi: String?, arxivId: String?, mailto: String? = nil, apiKey: String? = nil) async -> URL? {
        if let arxivId = FieldNormalizer.nonEmpty(arxivId) {
            return URL(string: "https://arxiv.org/pdf/\(arxivId)")
        }
        guard let doi = FieldNormalizer.normalizeDOI(doi) else { return nil }
        if let arxiv = IdentifierExtractor.arxivID(fromDOI: doi) { return URL(string: "https://arxiv.org/pdf/\(arxiv)") }
        guard let url = URL.make("https://api.openalex.org/works/doi:\(doi)",
                                 query: [("select", "best_oa_location,locations"), ("mailto", mailto), ("api_key", apiKey)]) else {
            return nil
        }
        struct Location: Decodable { let pdf_url: String? }
        struct Work: Decodable { let best_oa_location: Location?; let locations: [Location]? }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.setValue(userAgent(mailto), forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let work = try? JSONDecoder().decode(Work.self, from: data) else { return nil }
        let candidates = [work.best_oa_location?.pdf_url] + (work.locations ?? []).map(\.pdf_url)
        return candidates.compactMap { $0.flatMap(URL.init(string:)) }.first
    }

    /// Downloads `url` into a new temporary folder and checks that it is a PDF. A publisher page that
    /// only links to the PDF (citation_pdf_url, a meta refresh, an embedded viewer) is followed once.
    /// The caller removes the returned file's folder.
    public static func download(_ url: URL, mailto: String? = nil) async throws(Failure) -> URL {
        var target = url
        for attempt in 0..<2 {
            let (data, response): (Data, URLResponse)
            do {
                var request = URLRequest(url: target, timeoutInterval: 60)
                request.setValue(userAgent(mailto), forHTTPHeaderField: "User-Agent")
                request.setValue("application/pdf,text/html;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")
                (data, response) = try await URLSession.shared.data(for: request)
            } catch {
                throw .network(error.localizedDescription)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 200
            guard (200..<300).contains(status) else { throw .network("HTTP \(status)") }
            if isPDF(data) {
                let folder = FileManager.default.temporaryDirectory.appending(path: "folio-download-\(UUID().uuidString)")
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let file = folder.appending(path: fileName(for: response.url ?? target))
                    try data.write(to: file)
                    return file
                } catch {
                    throw .network(error.localizedDescription)
                }
            }
            let html = String(decoding: data.prefix(2_000_000), as: UTF8.self)
            guard attempt == 0, let next = pdfLink(inHTML: html, base: response.url ?? target) else {
                throw .notPDF(response.mimeType ?? "unknown type")
            }
            target = next
        }
        throw .notPDF("no PDF link on the page")
    }

    public static func isPDF(_ data: Data) -> Bool {
        data.prefix(1024).range(of: Data("%PDF".utf8)) != nil
    }

    /// The PDF a landing or interstitial page points to.
    static func pdfLink(inHTML html: String, base: URL) -> URL? {
        let patterns = [
            #"<meta[^>]+name=["']citation_pdf_url["'][^>]+content=["']([^"']+)["']"#,
            #"<meta[^>]+content=["']([^"']+)["'][^>]+name=["']citation_pdf_url["']"#,
            #"<meta[^>]+http-equiv=["']refresh["'][^>]+content=["'][^"']*url=([^"'>]+)["']"#,
            #"<(?:iframe|embed)[^>]+src=["']([^"']+)["']"#,
            #"window\.location(?:\.href)?\s*=\s*["']([^"']+)["']"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
                  let range = Range(match.range(at: 1), in: html) else { continue }
            let raw = html[range].replacingOccurrences(of: "&amp;", with: "&").trimmingCharacters(in: .whitespaces)
            if let url = URL(string: raw, relativeTo: base)?.absoluteURL, ["http", "https"].contains(url.scheme) { return url }
        }
        return nil
    }

    static func fileName(for url: URL) -> String {
        var name = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        name = name.replacingOccurrences(of: "/", with: "_")
        if name.isEmpty || name == "/" { name = "download" }
        if !name.lowercased().hasSuffix(".pdf") { name += ".pdf" }
        return name
    }

    private static func userAgent(_ mailto: String?) -> String {
        FieldNormalizer.nonEmpty(mailto).map { "Folio/2.6 (macOS; mailto:\($0))" } ?? "Folio/2.6 (macOS)"
    }
}
