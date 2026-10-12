import AppKit
import FolioAgent
import FolioCore
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
        if case .posix(.EADDRINUSE) = error { return "端口 \(port) 已被占用（是否打开了另一个 Folio？）" }
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
                          "library": .string(model.library.root.lastPathComponent)])
        case ("GET", "/collections"):
            return .json(collections(model))
        case ("POST", "/save"):
            guard let body = try? JSONValue.decode(String(decoding: request.body, as: UTF8.self)) else {
                return .error("Invalid JSON", status: 400)
            }
            return await save(body, model: model)
        case ("POST", "/attach"):
            return attach(request, model: model)
        case ("POST", "/savePDF"):
            return savePDF(request, model: model)
        default:
            return .error("Not found", status: 404)
        }
    }

    private func noteBrowser(_ userAgent: String?) {
        guard let ua = userAgent else { return }
        let name = ua.contains("Edg/") ? "Edge" : ua.contains("Firefox/") ? "Firefox" : ua.contains("OPR/") ? "Opera"
            : ua.contains("Chrome/") ? "Chrome" : ua.contains("Safari/") ? "Safari" : "浏览器"
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
            return .error("没有识别到文献信息", status: 400)
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
            for name in body["tags"]?.stringList ?? [] {
                let clean = name.trimmingCharacters(in: .whitespaces)
                guard !clean.isEmpty else { continue }
                let snapshot = try library.snapshot()
                let existing = snapshot.tags.first { $0.name.caseInsensitiveCompare(clean) == .orderedSame }?.id
                let tagId = try existing ?? library.createTag(
                    name: clean, colorHex: TagPalette.presets[snapshot.tags.count % TagPalette.presets.count].hex).id
                try library.setTag(tagId, onItems: [itemId], enabled: true)
            }
            let title = (try? library.item(itemId))?.title ?? metadata.title
            let groupName = groupId.flatMap { model.snapshot.groupsById[$0]?.name }
            model.toasts.show(status == "created" ? "已从浏览器保存「\(title)」" : "「\(title)」已在文献库中",
                              systemImage: "safari", actionTitle: "显示") {
                AppDelegate.shared.open(folioLink: "folio://select?item=\(itemId)")
            }
            return .json(["status": .string(status), "itemId": .string(itemId), "title": .string(title),
                          "group": .from(groupName), "lookedUp": .bool(lookedUp)])
        } catch {
            return .error(error.localizedDescription, status: 500)
        }
    }

    /// A PDF the browser downloaded for a saved item (it may carry the user's sign-in).
    private func attach(_ request: ConnectorProtocol.Request, model: AppModel) -> ConnectorProtocol.Response {
        guard let itemId = request.query["item"], model.snapshot.items[itemId] != nil || (try? model.library.item(itemId)) != nil else {
            return .error("Unknown item", status: 404)
        }
        guard Self.looksLikePDF(request.body) else { return .error("下载的文件不是 PDF（可能需要登录或订阅）", status: 400) }
        do {
            let url = try Self.temporaryFile(request.body, name: request.query["filename"])
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let outcome = try model.library.addFiles([url], toItem: itemId, autoRename: model.settings.autoRenameFiles).first
            model.importer.indexFulltext()
            switch outcome {
            case .added: return .json(["status": "added"])
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
        guard Self.looksLikePDF(request.body) else { return .error("这不是 PDF 文件", status: 400) }
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
