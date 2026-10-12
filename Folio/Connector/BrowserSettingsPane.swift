import AppKit
import SwiftUI

/// 设置 ▸ 浏览器 (WEB-01/05): the connector service and the extension in each browser.
struct BrowserSettingsPane: View {
    let model: AppModel
    @State private var browsers: [BrowserInfo] = []
    @State private var safariEnabled: Bool?
    @State private var installed: Set<String> = []

    var body: some View {
        @Bindable var settings = model.settings
        Form {
            Section {
                Toggle(isOn: $settings.browserConnectorEnabled) {
                    Text("允许浏览器插件保存文献")
                    Text("Folio 运行时在本机 127.0.0.1:\(String(ConnectorServer.port)) 接收插件的保存请求，只接受浏览器扩展、不接受网页的请求。")
                }
                .onChange(of: settings.browserConnectorEnabled) { _, on in on ? model.connector.start() : model.connector.stop() }
                LabeledContent("状态") { status }
            } header: {
                Text("Folio 连接器")
            } footer: {
                Text("在浏览器中打开论文页面后，点工具栏上的 Folio 按钮即可保存：自动识别标题、作者、DOI 等信息，选择分组和标签，并可同时保存 PDF。")
            }

            Section {
                ForEach(browsers) { browser in
                    LabeledContent {
                        action(for: browser)
                    } label: {
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: browser.appURL.path))
                                .resizable()
                                .frame(width: 26, height: 26)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(browser.name)
                                Text(detail(for: browser)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                HStack {
                    Text("浏览器")
                    Spacer()
                    Button {
                        refresh()
                    } label: {
                        Label("重新检测", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            } footer: {
                Text("Chrome、Edge 等浏览器：点\"安装…\"后，Folio 会准备好扩展文件夹（路径已拷贝），并打开浏览器的扩展页面；在页面右上角打开\"开发者模式\"，点\"加载已解压的扩展程序\"，选择该文件夹即可。Firefox 在调试页面中\"临时载入附加组件\"，选择文件夹中的 manifest.json。")
            }
        }
        .formStyle(.grouped)
        .task { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    @ViewBuilder
    private var status: some View {
        let connector = model.connector
        switch connector.state {
        case .running:
            let recent = connector.lastSeen.max { $0.value < $1.value }
            Label(recent.map { "运行中 · \($0.key) \($0.value.formatted(.relative(presentation: .named)))连接过" } ?? "运行中，等待插件连接",
                  systemImage: "circle.fill")
                .labelStyle(StatusLabelStyle(color: .green))
        case .stopped:
            Label("已关闭", systemImage: "circle.fill").labelStyle(StatusLabelStyle(color: .secondary))
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill").labelStyle(StatusLabelStyle(color: .orange))
        }
    }

    private func detail(for browser: BrowserInfo) -> String {
        switch browser.family {
        case .safari:
            switch safariEnabled {
            case true?: return "已启用"
            case false?: return "未启用"
            case nil: return "扩展随 Folio 提供"
            }
        case .chromium:
            return installed.contains(browser.id) ? "已安装" : "未安装"
        case .firefox:
            return "临时载入（重启 Firefox 后需重新载入）"
        }
    }

    @ViewBuilder
    private func action(for browser: BrowserInfo) -> some View {
        switch browser.family {
        case .safari:
            Button(safariEnabled == true ? "Safari 扩展设置…" : "在 Safari 中启用…") { BrowserExtensions.openSafariSettings() }
        case .chromium, .firefox:
            Button(installed.contains(browser.id) ? "重新安装…" : "安装…") { install(browser) }
        }
    }

    private func install(_ browser: BrowserInfo) {
        do {
            let folder = try BrowserExtensions.install(in: browser)
            model.toasts.show("扩展文件夹已准备好，路径已拷贝：\(folder.path)", systemImage: "puzzlepiece.extension")
        } catch {
            model.toasts.show("无法准备扩展：\(error.localizedDescription)", systemImage: "exclamationmark.triangle")
        }
    }

    private func refresh() {
        browsers = BrowserExtensions.detect()
        installed = Set(browsers.filter(BrowserExtensions.isInstalled).map(\.id))
        Task { safariEnabled = await BrowserExtensions.safariState() }
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
