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
/// An ordinary window of its own, opened in front of the library window once that is up (so it can't open
/// behind it). Only 跳过设置 and 开始使用 finish it: closed or quit half way, the first-run guide comes back
/// once, at the next launch, on the page it was left on.
///
///   -FolioPreviewOnboarding <step>   opens the guide on that step (welcome, zotero, browser, agents, translation, done)
final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    static let completedKey = "onboardingCompleted"
    /// The page an unfinished first-run guide was left on.
    static let resumeStepKey = "onboardingResumeStep"
    static let size = NSSize(width: 720, height: 700)
    private static var current: OnboardingWindowController?
    /// A guide asked for before the library window is on screen waits for it.
    private static var libraryShown = false
    private static var waiting: (() -> Void)?

    /// Called once the library window is on screen at launch.
    static func libraryWindowShown() {
        libraryShown = true
        waiting?()
        waiting = nil
    }

    /// At first launch with an empty library, or where an unfinished guide was left. A library that already
    /// has papers and no unfinished guide (an update from an earlier version) only marks the guide as seen.
    static func showIfNeeded(model: AppModel) {
        let defaults = UserDefaults.standard
        if let step = defaults.string(forKey: "FolioPreviewOnboarding") {
            show(model: model, step: OnboardingStep(rawValue: step) ?? .welcome)
            return
        }
        guard !defaults.bool(forKey: "FolioUITesting"), !defaults.bool(forKey: completedKey) else { return }
        if let saved = defaults.string(forKey: resumeStepKey) {
            show(model: model, step: OnboardingStep(rawValue: saved) ?? .welcome, comesBack: false)
            return
        }
        guard model.snapshot.items.isEmpty else {
            defaults.set(true, forKey: completedKey)
            return
        }
        show(model: model, comesBack: true)
    }

    /// `comesBack`: closing it before the end leaves it to reopen at the next launch (the first showing only).
    static func show(model: AppModel, step: OnboardingStep = .welcome, comesBack: Bool = false) {
        guard libraryShown else {
            waiting = { show(model: model, step: step, comesBack: comesBack) }
            return
        }
        if current == nil { current = OnboardingWindowController(model: model, step: step, comesBack: comesBack) }
        current?.showWindow(nil)
        current?.window?.makeKeyAndOrderFront(nil)
    }

    private let state: OnboardingState
    private let comesBack: Bool
    private var finished = false

    private init(model: AppModel, step: OnboardingStep, comesBack: Bool) {
        state = OnboardingState(model: model, step: step)
        self.comesBack = comesBack
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: Self.size),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = String(localized: "欢迎使用 Folio")
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.setAccessibilityIdentifier("onboardingWindow")
        super.init(window: window)
        let host = NSHostingController(rootView: OnboardingView(state: state, finish: { [weak self] in self?.finish() }))
        host.sizingOptions = []
        window.contentViewController = host
        window.setContentSize(Self.size)
        window.delegate = self
        // Previews and UI tests share the real app's defaults: they never leave a guide to resume.
        if !UserDefaults.standard.bool(forKey: Self.completedKey), !UserDefaults.standard.bool(forKey: "FolioUITesting") {
            state.stepChanged = { UserDefaults.standard.set($0.rawValue, forKey: Self.resumeStepKey) }
        }
        if let library = model.libraryWindow, library.isVisible {
            window.setFrameOrigin(NSPoint(x: library.frame.midX - Self.size.width / 2, y: library.frame.midY - Self.size.height / 2))
        } else {
            window.center()
        }
        state.start()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    /// 跳过设置 or 开始使用.
    private func finish() {
        finished = true
        close()
    }

    func windowWillClose(_ notification: Notification) {
        state.stop()
        Self.current = nil
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "FolioUITesting"), !defaults.bool(forKey: Self.completedKey) else { return }
        if !finished, comesBack {
            defaults.set(state.step.rawValue, forKey: Self.resumeStepKey)
            state.model.toasts.show(String(localized: "设置还没有完成，下次打开 Folio 时会继续"), systemImage: "arrow.uturn.forward")
            return
        }
        defaults.set(true, forKey: Self.completedKey)
        defaults.removeObject(forKey: Self.resumeStepKey)
        if !finished {
            state.model.toasts.show(String(localized: "可以随时在 帮助 ▸ 欢迎使用 Folio 中继续设置"), systemImage: "questionmark.circle")
        }
    }
}

enum OnboardingStep: String, CaseIterable {
    case welcome, zotero, browser, agents, translation, done
}

/// What the guide found on this Mac, and where it is.
@Observable
final class OnboardingState {
    let model: AppModel
    var step: OnboardingStep {
        didSet { stepChanged?(step) }
    }
    @ObservationIgnored var stepChanged: ((OnboardingStep) -> Void)?
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

    // Coding agents on this Mac that can translate
    private(set) var translationAgents: [LocalAgent]?

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

    /// Finds the coding agents that can translate without a key (Claude Code, Codex …).
    func discoverTranslator() {
        guard translationAgents == nil else { return }
        Task {
            translationAgents = await Task.detached { LocalAgent.installed() }.value
        }
    }

    func useAgent(_ agent: LocalAgent) {
        model.settings.translationService = agent.serviceID
    }
}
