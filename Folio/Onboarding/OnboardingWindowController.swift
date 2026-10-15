import AppKit
import FolioAgent
import FolioTranslate
import FolioZotero
import Observation
import SwiftUI

/// The first-run guide (欢迎使用 Folio): a welcome, then the few things worth setting up once — importing
/// from Zotero, the browser extension, Folio's MCP server and skill for the agents on this Mac, and the
/// translation engine. Every step can be skipped; 帮助 ▸ 欢迎使用 Folio… opens it again.
///
///   -FolioPreviewOnboarding <step>   opens the guide on that step (welcome, zotero, browser, agents, translation, done)
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    static let completedKey = "onboardingCompleted"
    private static var current: OnboardingWindowController?

    /// At first launch with an empty library. A library that already has papers (an update from an earlier
    /// version) only marks the guide as seen.
    static func showIfNeeded(model: AppModel) {
        let defaults = UserDefaults.standard
        if let step = defaults.string(forKey: "FolioPreviewOnboarding") {
            show(model: model, step: OnboardingStep(rawValue: step) ?? .welcome)
            return
        }
        guard !defaults.bool(forKey: "FolioUITesting"), !defaults.bool(forKey: completedKey) else { return }
        guard model.snapshot.items.isEmpty else {
            defaults.set(true, forKey: completedKey)
            return
        }
        show(model: model)
    }

    static func show(model: AppModel, step: OnboardingStep = .welcome) {
        if current == nil { current = OnboardingWindowController(model: model, step: step) }
        current?.showWindow(nil)
        current?.window?.makeKeyAndOrderFront(nil)
    }

    private let state: OnboardingState

    private init(model: AppModel, step: OnboardingStep) {
        state = OnboardingState(model: model, step: step)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 640),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = String(localized: "欢迎使用 Folio")
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.setAccessibilityIdentifier("onboardingWindow")
        super.init(window: window)
        let host = NSHostingController(rootView: OnboardingView(state: state, close: { [weak self] in self?.close() }))
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(NSSize(width: 720, height: 640))
        window.delegate = self
        if let library = model.libraryWindow, library.isVisible {
            window.setFrameOrigin(NSPoint(x: library.frame.midX - 360, y: library.frame.midY - 320))
        } else {
            window.center()
        }
        state.start()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    func windowWillClose(_ notification: Notification) {
        if !UserDefaults.standard.bool(forKey: "FolioUITesting") {
            UserDefaults.standard.set(true, forKey: Self.completedKey)
        }
        state.stop()
        Self.current = nil
    }
}

enum OnboardingStep: String, CaseIterable {
    case welcome, zotero, browser, agents, translation, done
}

/// What the guide found on this Mac, and where it is.
@Observable
final class OnboardingState {
    let model: AppModel
    var step: OnboardingStep
    let integration = AIIntegration.shared

    // Zotero
    let zoteroDirectory = ZoteroLocator.defaultDataDirectory()
    private(set) var zoteroReport: ZoteroReadReport?
    private(set) var zoteroProblem: String?
    var zoteroImported = false

    // Browsers
    private(set) var browsers: [BrowserInfo] = []
    private(set) var defaultBrowser: BrowserInfo?
    private(set) var enabledBrowsers: Set<String> = []

    // pdf2zh_next already on this Mac
    enum Discovery: Equatable { case idle, searching, found(URL, String), notFound }
    private(set) var discovery = Discovery.idle

    @ObservationIgnored private var activation: NSObjectProtocol?

    init(model: AppModel, step: OnboardingStep) {
        self.model = model
        self.step = step
    }

    /// Steps that apply to this Mac: Zotero only when it has a library, agents only when there are some.
    var steps: [OnboardingStep] {
        OnboardingStep.allCases.filter {
            switch $0 {
            case .zotero: zoteroDirectory != nil
            case .agents: !integration.detected.isEmpty
            default: true
            }
        }
    }

    var isFirst: Bool { step == steps.first }
    var isLast: Bool { step == steps.last }

    func next() {
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return }
        step = steps[index + 1]
    }

    func back() {
        guard let index = steps.firstIndex(of: step), index > 0 else { return }
        step = steps[index - 1]
    }

    func start() {
        integration.detect()
        Task { await refreshBrowsers() }
        probeZotero()
        discoverTranslator()
        // Back from a browser or System Settings: the extension may be enabled now.
        activation = NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.refreshBrowsers() }
            }
        }
    }

    func stop() {
        if let activation { NotificationCenter.default.removeObserver(activation) }
    }

    // MARK: Zotero

    private func probeZotero() {
        guard let directory = zoteroDirectory else { return }
        Task {
            do {
                zoteroReport = try await Task.detached { try ZoteroReader(dataDirectory: directory).probe() }.value
            } catch {
                zoteroProblem = String(localized: "无法读取 Zotero 数据库：\(error.localizedDescription)")
            }
        }
    }

    // MARK: Browsers

    func refreshBrowsers() async {
        browsers = BrowserExtensions.detect()
        defaultBrowser = BrowserExtensions.defaultBrowser(among: browsers)
        var enabled = Set<String>()
        for browser in browsers {
            switch browser.family {
            case .chromium:
                if case .installed(true, _) = BrowserExtensions.installState(in: browser) { enabled.insert(browser.id) }
            case .safari:
                if await BrowserExtensions.safariState() == true { enabled.insert(browser.id) }
            case .firefox:
                if model.connector.lastSeen["Firefox"] != nil { enabled.insert(browser.id) }
            }
        }
        enabledBrowsers = enabled
    }

    // MARK: Translation

    var usesOwnTranslator: Bool { !model.settings.translatorCustomPath.isEmpty }

    var builtInInstalled: Bool {
        if case .installed = model.translations.installation.status() { true } else { false }
    }

    /// Looks for a pdf2zh_next the user installed (uv, pipx, conda, the Zotero plugin …), unless one is set up.
    func discoverTranslator() {
        guard !usesOwnTranslator, !builtInInstalled, discovery != .searching else { return }
        // Screenshots of the "not found" page on a Mac that has one.
        if UserDefaults.standard.bool(forKey: "FolioPreviewTranslatorNotFound") {
            discovery = .notFound
            return
        }
        discovery = .searching
        let installation = model.translations.installation
        Task {
            let found = await Task.detached {
                await TranslatorDiscovery.discover(installation: installation, pathFolders: ShellEnvironment.loginPATH())
            }.value
            discovery = found.map { .found($0.executable, $0.version) } ?? .notFound
        }
    }

    func useFoundTranslator() {
        guard case .found(let url, _) = discovery else { return }
        model.settings.translatorCustomPath = url.path
    }

    /// Picks the executable by hand; it is used only if it runs.
    func chooseTranslator() {
        let panel = NSOpenPanel()
        panel.message = String(localized: "选择 pdf2zh_next 可执行文件")
        panel.prompt = String(localized: "使用")
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/bin")
        panel.showsHiddenFiles = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let installation = model.translations.installation
        Task {
            do {
                let runtime = try await installation.customRuntime(executable: url)
                model.settings.translatorCustomPath = url.path
                discovery = .found(url, runtime.version)
            } catch {
                let alert = NSAlert()
                alert.messageText = String(localized: "无法使用这个文件")
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    /// What to ask an agent when Folio cannot find the user's pdf2zh_next itself.
    static var agentPrompt: String {
        String(localized: "请用 Folio 的 MCP 找到我电脑上安装的 pdf2zh_next，并把它设置为 Folio 的翻译组件。")
    }
}
