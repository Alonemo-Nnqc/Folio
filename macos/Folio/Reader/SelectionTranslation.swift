import AppKit
import FolioTranslate
import Observation
import PDFKit
import SwiftUI

/// What the 划词翻译 popover shows.
@Observable
final class SelectionTranslationState {
    enum Phase: Equatable {
        case translating
        case done(String)
        case failed(String)
    }

    var source = ""
    var pageIndex = 0
    var phase = Phase.translating
    var serviceID = ""
    var services: [TranslationService] = []
    var sourceLanguage = "en"
    var targetLanguage = "zh"
    var copied = false
    var addedToNote = false

    var translation: String? {
        if case .done(let text) = phase { return text }
        return nil
    }
}

/// 划词翻译 in one reader (TRANS-10): a small button beside a text selection, and a popover with its translation by
/// the service chosen in 设置 ▸ 翻译. Every passage is translated once per service and language.
final class SelectionTranslationController: NSObject, NSPopoverDelegate {
    private let model: AppModel
    private weak var pdfView: ReaderPDFView?
    private let state = SelectionTranslationState()
    private let badge = SelectionTranslateBadge()
    private var popover: NSPopover?
    private var task: Task<Void, Never>?
    private var autoTask: Task<Void, Never>?
    private var badgeSelection: PDFSelection?
    private var cache: [String: String] = [:]
    var onAddToNote: (String, String, Int) -> Void = { _, _, _ in }

    init(model: AppModel, pdfView: ReaderPDFView) {
        self.model = model
        self.pdfView = pdfView
        super.init()
        badge.isHidden = true
        badge.onClick = { [weak self] in self?.badgeClicked() }
        pdfView.addSubview(badge)
        NotificationCenter.default.addObserver(self, selector: #selector(selectionChanged), name: .PDFViewSelectionChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(viewMoved), name: .PDFViewScaleChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(viewMoved), name: .PDFViewDisplayModeChanged, object: pdfView)
        DispatchQueue.main.async { [weak self] in self?.followScrolling() }
    }

    private var settings: AppSettings { model.settings }

    // MARK: Triggers

    /// The mouse was released over a text selection (select tool).
    func selectionFinished() {
        hideBadge(animated: false)
        guard settings.selectionTranslationEnabled, let selection = currentSelection else { return }
        switch settings.selectionTranslationTrigger {
        case .button:
            showBadge(for: selection)
        case .automatic:
            // A double or triple click is still under way: wait for the selection to settle.
            autoTask?.cancel()
            autoTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(220))
                guard !Task.isCancelled, let self, let selection = self.currentSelection else { return }
                self.translate(selection)
            }
        case .shortcut:
            break
        }
    }

    func mouseWentDown() {
        autoTask?.cancel()
        hideBadge(animated: true)
    }

    /// The shortcut: translates the selection, or closes the popover showing it. False when there is nothing to translate.
    @discardableResult
    func translateCurrentSelection() -> Bool {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return true
        }
        guard let selection = currentSelection else { return false }
        translate(selection)
        return true
    }

    private var currentSelection: PDFSelection? {
        guard let selection = pdfView?.currentSelection,
              !(selection.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return selection
    }

    @objc private func selectionChanged() {
        if currentSelection == nil { hideBadge(animated: true) }
    }

    private func badgeClicked() {
        guard let selection = badgeSelection ?? currentSelection else { return }
        translate(selection)
    }

    // MARK: Badge

    /// The rectangle of the selection's last line, in the PDF view's coordinates.
    private func lastLineRect(of selection: PDFSelection) -> NSRect? {
        guard let pdfView else { return nil }
        let lines = selection.selectionsByLine()
        guard let line = lines.last ?? Optional(selection), let page = line.pages.last else { return nil }
        return pdfView.convert(line.bounds(for: page), from: page)
    }

    private func selectionRect(of selection: PDFSelection) -> NSRect? {
        guard let pdfView else { return nil }
        let rects = selection.selectionsByLine().compactMap { line -> NSRect? in
            guard let page = line.pages.first else { return nil }
            return pdfView.convert(line.bounds(for: page), from: page)
        }
        let visible = rects.filter { $0.intersects(pdfView.bounds) }
        return (visible.isEmpty ? rects : visible).reduce(nil) { $0?.union($1) ?? $1 }
    }

    private func showBadge(for selection: PDFSelection) {
        badgeSelection = selection
        guard placeBadge() else { return }
        let final = badge.frame
        badge.alphaValue = 0
        badge.frame = final.insetBy(dx: 5, dy: 5)
        badge.isHidden = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 1.3, 0.4, 1)
            badge.animator().alphaValue = 1
            badge.animator().frame = final
        }
    }

    /// Puts the badge just after the end of the selection, inside the visible area. False when the selection is out of view.
    @discardableResult
    private func placeBadge() -> Bool {
        guard let pdfView, let selection = badgeSelection, let line = lastLineRect(of: selection) else { return false }
        let size = badge.intrinsicContentSize
        let bounds = pdfView.bounds
        var origin = NSPoint(x: line.maxX + 6, y: line.midY - size.height / 2)
        if origin.x + size.width > bounds.maxX - 18 { origin = NSPoint(x: line.maxX - size.width, y: line.minY - size.height - 6) }
        origin.x = min(max(origin.x, bounds.minX + 6), bounds.maxX - size.width - 18)
        origin.y = min(max(origin.y, bounds.minY + 6), bounds.maxY - size.height - 6)
        badge.frame = NSRect(origin: origin, size: size)
        return line.intersects(bounds)
    }

    private func hideBadge(animated: Bool) {
        guard !badge.isHidden else { return }
        badgeSelection = nil
        guard animated else { badge.isHidden = true; return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            badge.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.badgeSelection == nil else { return }
            self.badge.isHidden = true
        })
    }

    /// The badge moves with the text while the page scrolls.
    private func followScrolling() {
        guard let clip = pdfView?.documentView?.enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewMoved), name: NSView.boundsDidChangeNotification, object: clip)
    }

    @objc private func viewMoved() {
        guard !badge.isHidden else { return }
        if !placeBadge() { badge.isHidden = true; badgeSelection = nil }
    }

    // MARK: Translating

    private func translate(_ selection: PDFSelection) {
        guard let pdfView, let text = selection.string else { return }
        hideBadge(animated: false)
        state.source = SelectionTranslator.normalized(text)
        guard !state.source.isEmpty else { return }
        state.pageIndex = selection.pages.first.flatMap { pdfView.document?.index(for: $0) } ?? 0
        state.copied = false
        state.addedToNote = false
        state.sourceLanguage = settings.translationOptions.langIn
        state.targetLanguage = settings.translationOptions.langOut
        state.serviceID = settings.effectiveSelectionService
        refreshServices()
        run()
        show(at: selectionRect(of: selection) ?? lastLineRect(of: selection) ?? .zero)
    }

    private func refreshServices() {
        let settings = settings, secrets = model.translations.secrets
        state.services = ServiceAvailability.ready(settings: settings, secrets: secrets, agents: ServiceAvailability.knownAgents)
        Task { [weak self] in
            let agents = await ServiceAvailability.agents()
            guard let self else { return }
            self.state.services = ServiceAvailability.ready(settings: settings, secrets: secrets, agents: agents)
        }
    }

    private func run() {
        task?.cancel()
        let source = state.source, serviceID = state.serviceID
        let from = state.sourceLanguage, to = state.targetLanguage
        let key = "\(serviceID)|\(from)|\(to)|\(source)"
        if let cached = cache[key] {
            state.phase = .done(cached)
            return
        }
        state.phase = .translating
        let service = TranslationServiceCatalog.resolve(serviceID)
        let fields = settings.translationFields[service.id] ?? [:]
        let secrets = (try? model.translations.secrets.secrets(for: service)) ?? [:]
        task = Task { [weak self] in
            do {
                let result = try await SelectionTranslator.translate(source, serviceID: service.id, fields: fields, secrets: secrets, from: from, to: to)
                guard !Task.isCancelled, let self else { return }
                self.cache[key] = result
                withAnimation(.easeOut(duration: 0.2)) { self.state.phase = .done(result) }
            } catch is CancellationError {
            } catch {
                guard !Task.isCancelled, let self else { return }
                withAnimation(.easeOut(duration: 0.2)) { self.state.phase = .failed(error.localizedDescription) }
            }
        }
    }

    private func show(at rect: NSRect) {
        guard let pdfView else { return }
        let popover = self.popover ?? makePopover()
        let anchor = rect.intersection(pdfView.bounds).isEmpty ? rect : rect.intersection(pdfView.bounds)
        if popover.isShown {
            popover.positioningRect = anchor
        } else {
            popover.show(relativeTo: anchor, of: pdfView, preferredEdge: .minY)
        }
    }

    private func makePopover() -> NSPopover {
        let actions = SelectionTranslationActions(
            chooseService: { [weak self] id in
                guard let self else { return }
                self.settings.selectionTranslationService = id == self.settings.translationService ? "" : id
                self.state.serviceID = id
                self.run()
            },
            retry: { [weak self] in
                guard let self else { return }
                let key = "\(self.state.serviceID)|\(self.state.sourceLanguage)|\(self.state.targetLanguage)|\(self.state.source)"
                self.cache[key] = nil
                self.run()
            },
            copy: { [weak self] in
                guard let self, let text = self.state.translation else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                withAnimation { self.state.copied = true }
            },
            addToNote: { [weak self] in
                guard let self, let text = self.state.translation else { return }
                self.onAddToNote(self.state.source, text, self.state.pageIndex)
                withAnimation { self.state.addedToNote = true }
            },
            openSettings: { [weak self] in
                self?.popover?.performClose(nil)
                AppDelegate.shared.showSettings(nil)
                AppDelegate.shared.settingsWindow?.select(pane: "translation")
            })
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let host = NSHostingController(rootView: SelectionTranslationView(state: state, actions: actions))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        self.popover = popover
        return popover
    }

    func popoverDidClose(_ notification: Notification) {
        task?.cancel()
        pdfView?.window?.makeFirstResponder(pdfView)
    }

    func close() {
        task?.cancel()
        autoTask?.cancel()
        popover?.close()
        NotificationCenter.default.removeObserver(self)
    }
}

/// The round button beside a selection: glass, the translate symbol, a press state.
final class SelectionTranslateBadge: NSView {
    private let effect = NSVisualEffectView()
    private let icon = NSImageView()
    var onClick: () -> Void = {}
    private var pressed = false { didSet { icon.alphaValue = pressed ? 0.55 : 1 } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        effect.material = .popover
        effect.blendingMode = .withinWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 14
        effect.layer?.cornerCurve = .continuous
        effect.layer?.masksToBounds = true
        effect.layer?.borderWidth = 0.5
        icon.image = NSImage(systemSymbolName: "translate", accessibilityDescription: String(localized: "翻译"))?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        icon.contentTintColor = .controlAccentColor
        icon.imageScaling = .scaleNone
        for view in [effect, icon] as [NSView] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.2
        layer?.shadowRadius = 5
        layer?.shadowOffset = CGSize(width: 0, height: -1.5)
        layer?.masksToBounds = false
        toolTip = String(localized: "翻译所选文字")
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(String(localized: "翻译所选文字"))
        setAccessibilityIdentifier("selectionTranslateBadge")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is unused") }

    override var intrinsicContentSize: NSSize { NSSize(width: 28, height: 28) }
    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        effect.layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: 14, cornerHeight: 14, transform: nil)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsLayout = true
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseDragged(with event: NSEvent) { pressed = bounds.contains(convert(event.locationInWindow, from: nil)) }
    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        if inside { onClick() }
    }
    override func accessibilityPerformPress() -> Bool { onClick(); return true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        isHidden || alphaValue < 0.1 ? nil : (frame.contains(point) ? self : nil)
    }
}

struct SelectionTranslationActions {
    var chooseService: (String) -> Void
    var retry: () -> Void
    var copy: () -> Void
    var addToNote: () -> Void
    var openSettings: () -> Void
}

/// The popover: the passage, its translation, and what to do with it.
struct SelectionTranslationView: View {
    @Bindable var state: SelectionTranslationState
    let actions: SelectionTranslationActions
    @State private var sourceExpanded = false

    private func languageName(_ code: String) -> String {
        TranslationOptions.commonLanguages.first { $0.code.lowercased() == code.lowercased() }?.name
            ?? Locale.current.localizedString(forLanguageCode: code) ?? code
    }

    private var serviceName: String {
        TranslationServiceCatalog.service(id: state.serviceID)?.displayName ?? state.serviceID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)
            Text(state.source)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(sourceExpanded ? 12 : 3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { withAnimation(.snappy) { sourceExpanded.toggle() } }
                .padding(.horizontal, 14)
            Divider()
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            result
                .padding(.horizontal, 14)
            footer
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 8)
        }
        .frame(width: 380)
        .animation(.snappy(duration: 0.22), value: state.phase)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("\(languageName(state.sourceLanguage)) → \(languageName(state.targetLanguage))")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Menu {
                ForEach(state.services) { service in
                    Button {
                        actions.chooseService(service.id)
                    } label: {
                        if service.id == state.serviceID {
                            Label(service.displayName, systemImage: "checkmark")
                        } else {
                            Text(service.displayName)
                        }
                    }
                }
                Divider()
                Button("翻译设置…", action: actions.openSettings)
            } label: {
                Text(serviceName)
                    .font(.caption.weight(.medium))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(String(localized: "选择翻译服务"))
        }
    }

    @ViewBuilder
    private var result: some View {
        switch state.phase {
        case .translating:
            VStack(alignment: .leading, spacing: 7) {
                ForEach([1.0, 0.92, 0.6], id: \.self) { fraction in
                    ShimmerLine().frame(maxWidth: .infinity, alignment: .leading)
                        .scaleEffect(x: fraction, anchor: .leading)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
            .accessibilityLabel(String(localized: "正在翻译"))
        case .done(let text):
            ScrollView {
                Text(text)
                    .font(.body)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 320)
            .fixedSize(horizontal: false, vertical: true)
            .transition(.opacity)
            .accessibilityIdentifier("selectionTranslationResult")
        case .failed(let message):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(message)
                    .font(.callout)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
        }
    }

    private var footer: some View {
        HStack(spacing: 2) {
            FooterButton(symbol: state.copied ? "checkmark" : "doc.on.doc", help: String(localized: "拷贝译文"), action: actions.copy)
                .disabled(state.translation == nil)
            FooterButton(symbol: state.addedToNote ? "checkmark" : "note.text.badge.plus", help: String(localized: "添加到笔记"), action: actions.addToNote)
                .disabled(state.translation == nil)
            Spacer()
            if case .failed = state.phase {
                Button("设置…", action: actions.openSettings)
                    .controlSize(.small)
            }
            FooterButton(symbol: "arrow.clockwise", help: String(localized: "重新翻译"), action: actions.retry)
                .disabled(state.phase == .translating)
        }
    }
}

private struct FooterButton: View {
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 28, height: 24)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(hovering && isEnabled ? Color.primary.opacity(0.08) : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .onHover { hovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A placeholder line that glows while the translation is on its way.
private struct ShimmerLine: View {
    @State private var phase: CGFloat = -1

    var body: some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous)
            .fill(Color.primary.opacity(0.08))
            .frame(height: 11)
            .overlay {
                GeometryReader { proxy in
                    LinearGradient(colors: [.clear, Color.primary.opacity(0.10), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: proxy.size.width * 0.5)
                        .offset(x: phase * proxy.size.width)
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .onAppear {
                withAnimation(.linear(duration: 1.1).repeatForever(autoreverses: false)) { phase = 1.5 }
            }
    }
}
