import AppKit
import CoreText
import Foundation
import Testing
@testable import FolioMetadata

enum Fixtures {
    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// One-page PDF: the first `titleLines` lines large (the title), the rest body-sized.
    static func pdf(lines: [String], titleLines: Int = 1) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "folio-meta-\(UUID().uuidString).pdf")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        context.beginPDFPage(nil)
        var y: CGFloat = 740
        for (index, line) in lines.enumerated() {
            let font = CTFontCreateWithName("Helvetica" as CFString, index < titleLines ? 18 : 10, nil)
            let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: line, attributes: [.font: font]))
            context.textPosition = CGPoint(x: 40, y: y)
            CTLineDraw(ctLine, context)
            y -= index < titleLines ? 24 : 14
        }
        context.endPDFPage()
        context.closePDF()
        return url
    }
}

/// Routes requests to canned responses; unknown URLs get 404.
/// POSTs (the Zotero recognizer) go to `postHandler`, or to `handler` when there is none.
struct MockHTTPClient: HTTPClient {
    let handler: @Sendable (URL) async throws -> (Data, Int)
    var postHandler: (@Sendable (URL, Data) async throws -> (Data, Int))? = nil

    func get(_ url: URL, headers: [String: String]) async throws -> (Data, Int) {
        try await handler(url)
    }

    func post(_ url: URL, body: Data, headers: [String: String]) async throws -> (Data, Int) {
        if let postHandler { return try await postHandler(url, body) }
        return try await handler(url)
    }
}

extension MetadataEngine {
    static func testing(_ handler: @escaping @Sendable (URL) throws -> (Data, Int)) -> MetadataEngine {
        testing(MockHTTPClient(handler: handler))
    }

    static func testing(_ http: MockHTTPClient, useZoteroRecognizer: Bool = true,
                        recognizerTimeout: Duration = .seconds(2)) -> MetadataEngine {
        var configuration = MetadataEngineConfiguration()
        configuration.overallTimeout = 5
        configuration.useZoteroRecognizer = useZoteroRecognizer
        return MetadataEngine(configuration: configuration, http: http,
                              throttle: HostThrottle(minimumIntervals: [:]), searchGrace: .milliseconds(50),
                              recognizerTimeout: recognizerTimeout, recognizerLookupTimeout: .seconds(2))
    }
}
