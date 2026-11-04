import AppKit
import FolioAgent
import FolioCore
import FolioMetadata
import Network
import Observation

/// The local service the browser extension talks to (WEB-01): `127.0.0.1:23120`, extension origins only.
@Observable
final class ConnectorServer {
    enum State: Equatable {
        case stopped
        case running
        case failed(String)
    }

    private(set) var state = State.stopped
    /// Last request per browser ("Chrome", "Safari" …), for 设置 ▸ 浏览器.
    private(set) var lastSeen: [String: Date] = [:]

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var listener: NWListener?

    init(model: AppModel) {
        self.model = model
    }

    func start() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.acceptLocalOnly = true
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.port)!)
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    switch state {
                    case .ready: self?.state = .running
                    case .failed(let error):
                        self?.state = .failed(Self.describe(error))
                        self?.listener?.cancel()
                        self?.listener = nil
                    case .cancelled: if self?.state == .running { self?.state = .stopped }
                    default: break
                    }
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        state = .stopped
    }

    /// `-FolioConnectorPort <n>` lets a test copy of Folio run next to the user's own.
    static var port: UInt16 {
        UInt16(exactly: UserDefaults.standard.integer(forKey: "FolioConnectorPort")).flatMap { $0 > 0 ? $0 : nil }
            ?? ConnectorProtocol.port
    }

    private static func describe(_ error: NWError) -> String {
        if case .posix(.EADDRINUSE) = error { return String(localized: "端口 \(String(port)) 已被占用（是否打开了另一个 Folio？）") }
        return error.localizedDescription
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            MainActor.assumeIsolated {
                guard let self else { return connection.cancel() }
                var buffer = buffer
                if let data { buffer.append(data) }
                switch ConnectorProtocol.parse(buffer) {
                case .incomplete:
                    if isComplete || error != nil { connection.cancel() } else { self.receive(connection, buffer: buffer) }
                case .invalid(let reason):
                    self.send(.error(reason, status: reason.contains("large") ? 413 : 400), to: connection, origin: nil)
                case .complete(let request):
                    Task { @MainActor in
                        let response = await self.route(request)
                        self.send(response, to: connection, origin: request.headers["origin"])
                    }
                }
            }
        }
    }

    private func send(_ response: ConnectorProtocol.Response, to connection: NWConnection, origin: String?) {
        var response = response
        response.headers.merge(ConnectorProtocol.corsHeaders(origin: origin)) { $1 }
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: Routing

    private func route(_ request: ConnectorProtocol.Request) async -> ConnectorProtocol.Response {
        if request.method == "OPTIONS" {
            return ConnectorProtocol.isAllowedOrigin(request.headers["origin"])
                ? ConnectorProtocol.Response(status: 204, body: Data()) : .error("Forbidden", status: 403)
        }
        if let rejection = ConnectorProtocol.reject(request) { return rejection }
        guard let model else { return .error("Folio is not ready", status: 503) }
        noteBrowser(request.headers["user-agent"])
        switch (request.method, request.path) {
        case ("GET", "/ping"):
            return .json(["name": "Folio", "version": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""),
                          "apiVersion": .from(ConnectorProtocol.apiVersion),
                          "extensionVersion": .from(BrowserExtensions.bundledVersion),
                          "library": .string(model.library.root.lastPathComponent)])
        case ("GET", "/collections"):
            return .json(collections(model))
        case ("POST", "/save"):
            guard let body = try? JSONValue.decode(String(decoding: request.body, as: UTF8.self)) else {
                return .error("Invalid JSON", status: 400)
            }
            return await save(body, model: model)
        case ("POST", "/saveItems"):
            guard let body = try? JSONValue.decode(String(decoding: request.body, as: UTF8.self)) else {
                return .error("Invalid JSON", status: 400)
            }
            return await saveItems(body, model: model)
        case ("POST", "/attach"):
            return attach(request, model: model)
        case ("POST", "/savePDF"):
            return savePDF(request, model: model)
        case ("POST", "/pdfFailed"):
            return pdfFailed(request, model: model)
        case ("POST", "/reveal"):
            guard let itemId = request.query["item"], model.snapshot.items[itemId] != nil else { return .error("Unknown item", status: 404) }
            NSApp.activate()
            AppDelegate.shared.open(folioLink: "folio://select?item=\(itemId)")
            return .json(["status": "shown"])
        default:
            return .error("Not found", status: 404)
        }
    }

    private func noteBrowser(_ userAgent: String?) {
        guard let ua = userAgent else { return }
        let name = ua.contains("Edg/") ? "Edge" : ua.contains("Firefox/") ? "Firefox" : ua.contains("OPR/") ? "Opera"
            : ua.contains("Chrome/") ? "Chrome" : ua.contains("Safari/") ? "Safari" : String(localized: "浏览器")
        lastSeen[name] = Date()
    }

    /// Groups for the picker, in sidebar order, plus the group Folio is showing (the default choice).
    private func collections(_ model: AppModel) -> JSONValue {
        let s = model.snapshot
        let groups: [JSONValue] = model.groupsForMenus.map { entry in
            var object: [String: JSONValue] = ["id": .string(entry.group.id), "name": .string(entry.group.name),
                                               "depth": .from(entry.depth)]
            if let color = entry.group.colorHex { object["color"] = .string(color) }
            return .object(object)
        }
        return [
            "groups": .array(groups),
            "currentGroupId": .from(model.sidebarSelection.groupId),
            "tags": .array(s.tags.map { .string($0.name) }),
        ]
    }

    // MARK: Saving (WEB-04)

    private func save(_ body: JSONValue, model: AppModel) async -> ConnectorProtocol.Response {
        guard let page = body["item"].flatMap(ConnectorProtocol.metadata(from:)) else {
            return .error(String(localized: "没有识别到文献信息"), status: 400)
        }
        let groupId = body["groupId"]?.stringValue.flatMap { model.snapshot.groupsById[$0] != nil ? $0 : nil }
        var metadata = page
        var lookedUp = false
        if body["resolve"]?.boolValue ?? true, let identifier = page.doi ?? page.arxivId ?? page.isbn {
            if case .found(let resolved) = await model.importer.resolver.resolve(identifier: identifier) {
                metadata = ConnectorProtocol.merge(resolved: resolved, page: page)
                lookedUp = true
            }
        }
        do {
            let library = model.library
            let itemId: String, status: String
            switch try library.createItem(metadata, inGroup: groupId) {
            case .created(let id): (itemId, status) = (id, "created")
            case .duplicate(let existing):
                (itemId, status) = (existing, "duplicate")
                if let groupId { _ = try library.addItems([existing], toGroup: groupId, includeSubgroups: false) }
            }
            try applyTags(body["tags"]?.stringList ?? [], to: itemId, library: library)
            let title = (try? library.item(itemId))?.title ?? metadata.title
            let groupName = groupId.flatMap { model.snapshot.groupsById[$0]?.name }
            model.toasts.show(status == "created" ? String(localized: "已从浏览器保存「\(title)」") : String(localized: "「\(title)」已在文献库中"),
                              systemImage: "safari", actionTitle: String(localized: "显示")) {
                AppDelegate.shared.open(folioLink: "folio://select?item=\(itemId)")
            }
            return .json(["status": .string(status), "itemId": .string(itemId), "title": .string(title),
                          "group": .from(groupName), "lookedUp": .bool(lookedUp)])
        } catch {
            return .error(error.localizedDescription, status: 500)
        }
    }

    /// Several works found on a list page (WEB-03 批量保存), saved by identifier: Folio looks each one up,
    /// creates or reuses the item and puts it in the group. Open-access PDFs (arXiv …) follow afterwards.
    private func saveItems(_ body: JSONValue, model: AppModel) async -> ConnectorProtocol.Response {
        let entries = (body["items"]?.arrayValue ?? []).prefix(200).compactMap { entry -> (identifier: String, title: String?)? in
            guard let identifier = entry["identifier"]?.stringValue?.trimmingCharacters(in: .whitespaces), !identifier.isEmpty else { return nil }
            return (identifier, entry["title"]?.stringValue)
        }
        guard !entries.isEmpty else { return .error(String(localized: "没有可保存的文献"), status: 400) }
        let groupId = body["groupId"]?.stringValue.flatMap { model.snapshot.groupsById[$0] != nil ? $0 : nil }
        let tags = body["tags"]?.stringList ?? []
        let resolver = model.importer.resolver
        // Four lookups at a time, like imports; results keep the page's order.
        var lookups = [RetrievalResult?](repeating: nil, count: entries.count)
        await withTaskGroup(of: (Int, RetrievalResult).self) { group in
            var next = 0
            func enqueue() {
                guard next < entries.count else { return }
                let index = next
                let identifier = entries[index].identifier
                group.addTask { (index, await resolver.resolve(identifier: identifier)) }
                next += 1
            }
            for _ in 0..<4 { enqueue() }
            for await (index, result) in group {
                lookups[index] = result
                enqueue()
            }
        }
        var results: [JSONValue] = []
        var saved: [(id: String, metadata: Metadata)] = []
        let library = model.library
        for (index, entry) in entries.enumerated() {
            var object: [String: JSONValue] = ["identifier": .string(entry.identifier), "title": .from(entry.title)]
            switch lookups[index] {
            case .found(let metadata)?:
                do {
                    let itemId: String
                    switch try library.createItem(metadata, inGroup: groupId) {
                    case .created(let id):
                        itemId = id
                        object["status"] = "created"
                    case .duplicate(let existing):
                        itemId = existing
                        object["status"] = "duplicate"
                        if let groupId { _ = try library.addItems([existing], toGroup: groupId, includeSubgroups: false) }
                    }
                    try applyTags(tags, to: itemId, library: library)
                    object["itemId"] = .string(itemId)
                    object["title"] = .string(metadata.title)
                    saved.append((itemId, metadata))
                } catch {
                    object["status"] = "failed"
                    object["error"] = .string(error.localizedDescription)
                }
            case .networkError?:
                object["status"] = "failed"
                object["error"] = .string(String(localized: "网络错误，请稍后重试"))
            default:
                object["status"] = "failed"
                object["error"] = .string(String(localized: "数据源中没有找到"))
            }
            results.append(.object(object))
        }
        let created = results.filter { $0["status"]?.stringValue == "created" }.count
        let existing = results.filter { $0["status"]?.stringValue == "duplicate" }.count
        if !saved.isEmpty {
            let first = saved[0].id
            model.toasts.show(existing > 0 ? String(localized: "已从浏览器保存 \(created) 篇，\(existing) 篇已在文献库中") : String(localized: "已从浏览器保存 \(created) 篇文献"),
                              systemImage: "safari", actionTitle: String(localized: "显示")) {
                AppDelegate.shared.open(folioLink: "folio://select?item=\(first)")
            }
        }
        if body["pdf"]?.boolValue == true, !saved.isEmpty {
            Task { await attachOpenAccessPDFs(saved, model: model) }
        }
        return .json(["results": .array(results), "group": .from(groupId.flatMap { model.snapshot.groupsById[$0]?.name })])
    }

    /// Downloads freely available PDFs (arXiv, open-access copies) for items that have none yet.
    private func attachOpenAccessPDFs(_ items: [(id: String, metadata: Metadata)], model: AppModel) async {
        let library = model.library
        let mailto = model.settings.crossrefMailto
        var attached = 0
        for item in items {
            guard (try? library.files(ofItem: item.id).contains(where: \.isPDF)) == false,
                  let url = await OpenAccessPDF.locate(doi: item.metadata.doi, arxivId: item.metadata.arxivId, mailto: mailto),
                  let file = try? await OpenAccessPDF.download(url, mailto: mailto) else { continue }
            defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
            if case .added? = try? library.addFiles([file], toItem: item.id, autoRename: model.settings.autoRenameFiles).first {
                attached += 1
            }
        }
        if attached > 0 {
            model.importer.indexFulltext()
            model.toasts.show(String(localized: "已为 \(attached) 篇文献下载 PDF"), systemImage: "arrow.down.doc")
        }
    }

    private func applyTags(_ names: [String], to itemId: String, library: Library) throws {
        for name in names {
            let clean = name.trimmingCharacters(in: .whitespaces)
            guard !clean.isEmpty else { continue }
            let snapshot = try library.snapshot()
            let existing = snapshot.tags.first { $0.name.caseInsensitiveCompare(clean) == .orderedSame }?.id
            let tagId = try existing ?? library.createTag(
                name: clean, colorHex: TagPalette.presets[snapshot.tags.count % TagPalette.presets.count].hex).id
            try library.setTag(tagId, onItems: [itemId], enabled: true)
        }
    }

    /// The browser could not download the PDF of a saved item: say why in Folio too (the popup may be closed).
    private func pdfFailed(_ request: ConnectorProtocol.Request, model: AppModel) -> ConnectorProtocol.Response {
        let body = try? JSONValue.decode(String(decoding: request.body, as: UTF8.self))
        let reason = body?["message"]?.stringValue ?? String(localized: "下载失败")
        let title = request.query["item"].flatMap { model.snapshot.items[$0]?.title } ?? String(localized: "条目")
        model.toasts.show(String(localized: "「\(title)」的 PDF 未能保存：\(reason)"), systemImage: "exclamationmark.triangle")
        return .json(["status": "noted"])
    }

    /// A PDF the browser downloaded for a saved item (it may carry the user's sign-in).
    private func attach(_ request: ConnectorProtocol.Request, model: AppModel) -> ConnectorProtocol.Response {
        guard let itemId = request.query["item"], model.snapshot.items[itemId] != nil || (try? model.library.item(itemId)) != nil else {
            return .error("Unknown item", status: 404)
        }
        guard Self.looksLikePDF(request.body) else { return .error(String(localized: "下载的文件不是 PDF（可能需要登录或订阅）"), status: 400) }
        do {
            let url = try Self.temporaryFile(request.body, name: request.query["filename"])
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let outcome = try model.library.addFiles([url], toItem: itemId, autoRename: model.settings.autoRenameFiles).first
            model.importer.indexFulltext()
            switch outcome {
            case .added:
                let title = (try? model.library.item(itemId))?.title ?? String(localized: "条目")
                model.toasts.show(String(localized: "已为「\(title)」附加 PDF"), systemImage: "doc.badge.plus")
                return .json(["status": "added"])
            case .duplicate: return .json(["status": "duplicate"])
            case .failed(_, let reason): return .error(reason, status: 500)
            case nil: return .error("Nothing attached", status: 500)
            }
        } catch {
            return .error(error.localizedDescription, status: 500)
        }
    }

    /// A PDF page saved as a file; Folio retrieves its metadata like any imported PDF.
    private func savePDF(_ request: ConnectorProtocol.Request, model: AppModel) -> ConnectorProtocol.Response {
        guard Self.looksLikePDF(request.body) else { return .error(String(localized: "这不是 PDF 文件"), status: 400) }
        do {
            let url = try Self.temporaryFile(request.body, name: request.query["filename"])
            let groupId = request.query["groupId"].flatMap { model.snapshot.groupsById[$0] != nil ? $0 : nil }
            model.importer.importFiles([url], toGroup: groupId)
            // Import copies the file; the temporary folder goes once it has been read.
            DispatchQueue.main.asyncAfter(deadline: .now() + 30) { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            return .json(["status": "importing", "group": .from(groupId.flatMap { model.snapshot.groupsById[$0]?.name })])
        } catch {
            return .error(error.localizedDescription, status: 500)
        }
    }

    static func looksLikePDF(_ data: Data) -> Bool {
        data.prefix(1024).range(of: Data("%PDF".utf8)) != nil
    }

    private static func temporaryFile(_ data: Data, name: String?) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(path: "folio-web-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var fileName = FileNamer.sanitize((name ?? "").removingPercentEncoding ?? "")
        if fileName.isEmpty { fileName = "download" }
        if !fileName.lowercased().hasSuffix(".pdf") { fileName += ".pdf" }
        let url = folder.appending(path: fileName)
        try data.write(to: url)
        return url
    }
}
