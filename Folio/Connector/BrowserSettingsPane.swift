import AppKit
import SwiftUI

/// 设置 ▸ 浏览器 (WEB-01/05): the connector service, and the extension in each browser with a step-by-step
/// install guide that watches for the installation to finish.
struct BrowserSettingsPane: View {
    let model: AppModel
    @State private var browsers: [BrowserInfo] = []
    @State private var safariEnabled: Bool?
    @State private var states: [String: BrowserExtensions.InstallState] = [:]
    @State private var guide: BrowserInfo?
    @State private var redetect = RedetectState()

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle("允许浏览器插件保存文献", isOn: $settings.browserConnectorEnabled)
                    .help("Folio 运行时在本机 127.0.0.1:\(String(ConnectorServer.port)) 接收插件的保存请求，只接受浏览器扩展、不接受网页的请求")
                .onChange(of: settings.browserConnectorEnabled) { _, on in on ? model.connector.start() : model.connector.stop() }
                LabeledContent("状态") { status }
            } header: {
                Text("Folio 连接器")
            } footer: {
                Text("在论文页面点工具栏中的 Folio 按钮或按 ⌘⇧S 保存\n也可以在链接上右键\"保存链接到 Folio\"")
            }

            Section {
                ForEach(browsers) { browser in
                    LabeledContent {
                        HStack(spacing: 10) {
                            let state = status(for: browser)
                            StatusBadge(text: state.text, tone: state.tone)
                            Button(buttonTitle(for: browser)) { guide = browser }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: browser.appURL.path))
                                .resizable()
                                .frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(browser.name)
                                if let detail = detail(for: browser) {
                                    Text(detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("浏览器")
                    Spacer()
                    RedetectButton(isChecking: redetect.isChecking, result: redetect.result,
                                   help: String(localized: "重新检测各浏览器中的 Folio 扩展")) {
                        redetect.run { await refreshNow() }
                    }
                }
            } footer: {
                Text("扩展暂未上架应用商店，点按钮按引导完成安装")
            }
        }
        .formStyle(.grouped)
        .task { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .sheet(item: $guide, onDismiss: refresh) { browser in
            ExtensionInstallGuide(browser: browser, model: model)
        }
    }

    @ViewBuilder
    private var status: some View {
        let connector = model.connector
        switch connector.state {
        case .running:
            let recent = connector.lastSeen.max { $0.value < $1.value }
            Label(recent.map { String(localized: "运行中 · \($0.key) \($0.value.formatted(.relative(presentation: .named)))连接过") } ?? String(localized: "运行中，等待插件连接"),
                  systemImage: "circle.fill")
                .labelStyle(StatusLabelStyle(color: .green))
        case .stopped:
            Label("已关闭", systemImage: "circle.fill").labelStyle(StatusLabelStyle(color: .secondary))
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").labelStyle(StatusLabelStyle(color: .orange))
        }
    }

    private func buttonTitle(for browser: BrowserInfo) -> String {
        switch browser.family {
        case .safari: safariEnabled == true ? String(localized: "设置…") : String(localized: "启用…")
        case .chromium: states[browser.id].map { $0 == .notInstalled ? String(localized: "安装…") : String(localized: "重新安装…") } ?? String(localized: "安装…")
        case .firefox: String(localized: "安装…")
        }
    }

    /// The extension's state in a browser, as a badge.
    private func status(for browser: BrowserInfo) -> (text: String, tone: StatusBadge.Tone) {
        switch browser.family {
        case .safari:
            switch safariEnabled {
            case true?: return (String(localized: "已启用"), .positive)
            case false?: return (String(localized: "未启用"), .attention)
            case nil: return (String(localized: "未允许"), .attention)
            }
        case .chromium:
            switch states[browser.id] ?? .notInstalled {
            case .notInstalled: return (String(localized: "未安装"), .neutral)
            case .installed(let enabled, let version):
                if !enabled { return (String(localized: "已停用"), .attention) }
                if let version, let bundled = BrowserExtensions.bundledVersion,
                   bundled.compare(version, options: .numeric) == .orderedDescending { return (String(localized: "有新版本"), .info) }
                return (String(localized: "已启用"), .positive)
            }
        case .firefox:
            return model.connector.lastSeen["Firefox"] == nil ? (String(localized: "未载入"), .neutral) : (String(localized: "临时载入"), .attention)
        }
    }

    /// One short line under the name, only when it says something the badge does not.
    private func detail(for browser: BrowserInfo) -> String? {
        let seen = model.connector.lastSeen[ExtensionInstallGuide.connectorName(for: browser)]
            .map { String(localized: "\($0.formatted(.relative(presentation: .named)))连接过") }
        switch browser.family {
        case .safari:
            return safariEnabled == nil ? String(localized: "需要先在 Safari 中允许未签名的扩展") : seen
        case .chromium:
            if case .installed(true, let version)? = states[browser.id],
               let version, let bundled = BrowserExtensions.bundledVersion,
               bundled.compare(version, options: .numeric) == .orderedDescending {
                return String(localized: "在扩展页点\"重新加载\"即可更新")
            }
            return seen
        case .firefox:
            return String(localized: "重启 Firefox 后需重新载入")
        }
    }

    private func refresh() {
        Task { await refreshNow() }
    }

    /// Re-reads every browser and the Safari extension's state; returns a one-line summary.
    @discardableResult
    private func refreshNow() async -> String {
        browsers = BrowserExtensions.detect()
        states = Dictionary(uniqueKeysWithValues: browsers.map { ($0.id, BrowserExtensions.installState(in: $0)) })
        safariEnabled = await BrowserExtensions.safariState()
        let enabled = browsers.filter { status(for: $0).tone == .positive }.count
        return enabled == 0 ? String(localized: "尚未在浏览器中启用") : String(localized: "\(enabled) 个浏览器已启用")
    }
}

/// Step-by-step installation for one browser; watches until the extension shows up.
struct ExtensionInstallGuide: View {
    let browser: BrowserInfo
    let model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var folder: URL?
    @State private var problem: String?
    @State private var state: BrowserExtensions.InstallState = .notInstalled
    @State private var safariEnabled: Bool?
    @State private var copied: String?

    /// The name ConnectorServer records for requests from this browser.
    static func connectorName(for browser: BrowserInfo) -> String {
        switch browser.id {
        case "safari": "Safari"
        case "edge": "Edge"
        case "firefox": "Firefox"
        case "opera": "Opera"
        default: "Chrome"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: browser.appURL.path)).resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 2) {
                    (browser.family == .safari ? Text("在 \(browser.name) 中启用 Folio 扩展") : Text("在 \(browser.name) 中安装 Folio 扩展")).font(.headline)
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 14) {
                switch browser.family {
                case .safari: safariSteps
                case .chromium: chromiumSteps
                case .firefox: firefoxSteps
                }
            }
            Divider()
            HStack {
                progress
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .task { await prepareAndWatch() }
    }

    private var subtitle: String {
        switch browser.family {
        case .safari: String(localized: "扩展随 Folio 提供，按下面三步打开即可")
        case .chromium: String(localized: "扩展尚未上架应用商店，需要以\"开发者模式\"载入，约一分钟")
        case .firefox: String(localized: "以临时附加组件载入，Firefox 重启后需要重新载入")
        }
    }

    // MARK: Steps

    @ViewBuilder
    private var chromiumSteps: some View {
        let page = browser.extensionsPage ?? "chrome://extensions"
        step(1, String(localized: "打开扩展页面"), detail: String(localized: "如果浏览器没有跳转，把地址粘贴到地址栏：\(page)")) {
            Button("打开") { BrowserExtensions.openExtensionsPage(of: browser) }
            Button("拷贝地址") { copy(page, label: String(localized: "地址")) }
        }
        step(2, browser.id == "edge" ? String(localized: "打开左侧的\"开发人员模式\"") : String(localized: "打开右上角的\"开发者模式\"开关"), detail: nil) { EmptyView() }
        step(3, browser.id == "edge" ? String(localized: "点\"加载解压缩的扩展\"") : String(localized: "点\"加载已解压的扩展程序\""), detail: nil) { EmptyView() }
        step(4, String(localized: "选择 Folio 扩展文件夹"), detail: String(localized: "在弹出的窗口中按 ⌘⇧G，再按 ⌘V 粘贴下面的路径（已拷贝），回车后点\"选择\"\n也可以把 Finder 中的文件夹拖进窗口")) {
            Button("拷贝路径") { if let folder { copy(folder.path, label: String(localized: "路径")) } }
            Button("在 Finder 中显示") { if let folder { NSWorkspace.shared.activateFileViewerSelecting([folder]) } }
        }
        if let folder {
            Text(folder.path)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
                .padding(.leading, 30)
        }
    }

    @ViewBuilder
    private var safariSteps: some View {
        step(1, String(localized: "打开网页开发者功能"), detail: String(localized: "Safari ▸ 设置 ▸ 高级，勾选\"显示网页开发者功能\"")) {
            Button("打开 Safari") { NSWorkspace.shared.open(browser.appURL) }
        }
        step(2, String(localized: "允许未签名的扩展"), detail: String(localized: "Safari ▸ 设置 ▸ 开发者，勾选\"允许未签名的扩展\"\nFolio 使用开发证书签名，Safari 每次重新打开后需要再勾选一次")) {
            EmptyView()
        }
        step(3, String(localized: "启用 Folio 文献保存"), detail: String(localized: "Safari ▸ 设置 ▸ 扩展，勾选\"Folio 文献保存\"，并允许它在所有网站上使用（读取论文页面时需要）")) {
            Button("打开扩展设置") {
                Task { problem = await BrowserExtensions.openSafariSettings().map { String(localized: "Safari 还没有列出 Folio 扩展，请先完成第 2 步（\($0)）") } }
            }
        }
    }

    @ViewBuilder
    private var firefoxSteps: some View {
        let page = "about:debugging#/runtime/this-firefox"
        step(1, String(localized: "打开 Firefox 的调试页面"), detail: String(localized: "Firefox 不允许其他应用打开该页面，请把地址粘贴到地址栏：\(page)")) {
            Button("拷贝地址") { copy(page, label: String(localized: "地址")) }
            Button("打开 Firefox") { NSWorkspace.shared.open(browser.appURL) }
        }
        step(2, String(localized: "点\"临时载入附加组件…\""), detail: String(localized: "在选择窗口中按 ⌘⇧G，粘贴路径（已拷贝）后回车，选择其中的 manifest.json")) {
            Button("拷贝路径") { if let folder { copy(folder.appending(path: "manifest.json").path, label: String(localized: "路径")) } }
        }
        if let folder {
            Text(folder.appending(path: "manifest.json").path)
                .font(.callout.monospaced()).textSelection(.enabled).foregroundStyle(.secondary).padding(.leading, 30)
        }
    }

    private func step<Actions: View>(_ number: Int, _ title: String, detail: String?, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.callout.weight(.semibold).monospacedDigit())
                .frame(width: 20, height: 20)
                .background(Circle().fill(.quaternary))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                if let detail { Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 8)
            HStack(spacing: 6) { actions() }.controlSize(.small)
        }
    }

    @ViewBuilder
    private var progress: some View {
        let connected = model.connector.lastSeen[Self.connectorName(for: browser)].map { Date().timeIntervalSince($0) < 600 } ?? false
        switch browser.family {
        case .chromium:
            switch state {
            case .installed(true, _):
                Label("已安装并启用", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .installed(false, _):
                Label("已安装但已停用：在扩展页面中打开它的开关", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            case .notInstalled:
                waiting(copied.map { String(localized: "已拷贝\($0)，正在等待安装…") } ?? String(localized: "正在等待安装…"))
            }
        case .safari:
            switch safariEnabled {
            case true?: Label("已启用", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case false?: waiting(String(localized: "Safari 已列出 Folio 扩展，等待勾选启用…"))
            case nil: waiting(String(localized: "等待 Safari 列出 Folio 扩展（完成第 2 步后出现）…"))
            }
        case .firefox:
            if connected {
                Label("扩展已连接 Folio", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                waiting(String(localized: "载入后在论文页面点一次 Folio 按钮即可确认"))
            }
        }
    }

    private func waiting(_ text: String) -> some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.small)
            Text(text).foregroundStyle(.secondary)
        }
    }

    private func copy(_ text: String, label: String) {
        BrowserExtensions.copyToPasteboard(text)
        copied = label
    }

    /// Prepares the folder (path copied), opens the first step, then checks every 1.5 s until done.
    private func prepareAndWatch() async {
        if browser.family != .safari {
            do {
                folder = try BrowserExtensions.prepareInstall(for: browser)
                copied = String(localized: "路径")
            } catch {
                problem = String(localized: "无法准备扩展文件夹：\(error.localizedDescription)")
            }
        }
        if browser.family == .chromium { BrowserExtensions.openExtensionsPage(of: browser) }
        while !Task.isCancelled {
            switch browser.family {
            case .chromium: state = BrowserExtensions.installState(in: browser)
            case .safari: safariEnabled = await BrowserExtensions.safariState()
            case .firefox: break
            }
            try? await Task.sleep(for: .seconds(1.5))
        }
    }
}

private struct StatusLabelStyle: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 8)).foregroundStyle(color)
            configuration.title.foregroundStyle(.secondary)
        }
    }
}
