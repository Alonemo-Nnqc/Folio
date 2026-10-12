import FolioCore
import Foundation
import Testing
@testable import FolioAgent

@Suite struct ConnectorProtocolTests {
    func raw(_ text: String, body: String = "") -> Data {
        Data((text.replacingOccurrences(of: "\n", with: "\r\n") + "Content-Length: \(body.utf8.count)\r\n\r\n" + body).utf8)
    }

    @Test func parsesRequestsInPieces() throws {
        let body = #"{"item":{"title":"A"}}"#
        let data = raw("POST /save?groupId=g1 HTTP/1.1\nHost: 127.0.0.1\nOrigin: chrome-extension://abc\nX-Folio-Connector: 1\n", body: body)
        guard case .incomplete = ConnectorProtocol.parse(data.prefix(20)) else { Issue.record("partial headers"); return }
        guard case .incomplete = ConnectorProtocol.parse(data.dropLast(3)) else { Issue.record("partial body"); return }
        guard case .complete(let request) = ConnectorProtocol.parse(data) else { Issue.record("complete"); return }
        #expect(request.method == "POST" && request.path == "/save" && request.query["groupId"] == "g1")
        #expect(request.headers["origin"] == "chrome-extension://abc")
        #expect(String(decoding: request.body, as: UTF8.self) == body)
        #expect(ConnectorProtocol.reject(request) == nil)
    }

    @Test func webPagesAndFormsAreRejected() throws {
        guard case .complete(let fromSite) = ConnectorProtocol.parse(raw("POST /save HTTP/1.1\nOrigin: https://evil.example\nX-Folio-Connector: 1\n")),
              case .complete(let form) = ConnectorProtocol.parse(raw("POST /save HTTP/1.1\nOrigin: safari-web-extension://x\n")),
              case .complete(let ping) = ConnectorProtocol.parse(raw("GET /ping HTTP/1.1\nOrigin: moz-extension://y\n")) else {
            Issue.record("parse"); return
        }
        #expect(ConnectorProtocol.reject(fromSite)?.status == 403)
        #expect(ConnectorProtocol.reject(form)?.status == 403, "writes need the custom header")
        #expect(ConnectorProtocol.reject(ping) == nil)
        #expect(ConnectorProtocol.corsHeaders(origin: "https://evil.example").isEmpty)
        #expect(ConnectorProtocol.corsHeaders(origin: "chrome-extension://abc")["Access-Control-Allow-Origin"] == "chrome-extension://abc")
    }

    @Test func pageMetadataMapsToFolioFields() throws {
        let item: JSONValue = ["title": "Night-Time Scene Parsing", "authors": ["Tan, Xin", "Ke Xu", ["family": "Cao", "given": "Ying"]],
                               "date": "2021/10/20", "venue": "IEEE TIP", "doi": "https://doi.org/10.1109/TIP.2021.3122004",
                               "type": "journalArticle", "pages": "1-12"]
        let m = try #require(ConnectorProtocol.metadata(from: item))
        #expect(m.authors.map(\.family) == ["Tan", "Xu", "Cao"])
        #expect(m.year == 2021 && m.doi == "10.1109/tip.2021.3122004" && m.source == "IEEE TIP")
        let arxiv = try #require(ConnectorProtocol.metadata(from: ["title": "X", "arxiv": "2401.00001"]))
        #expect(arxiv.type == .preprint && arxiv.source == "arXiv")
        #expect(ConnectorProtocol.metadata(from: ["title": "  "]) == nil)
    }
}
