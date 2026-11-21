import AppKit
import QuartzCore

/// Frame-time measurements for smoothness work, written to a log (no input events, nothing saved):
///   -FolioPerfProbe <log>   toggles the library's sidebar and inspector a few times, then scrolls each settings pane,
///                           recording the time between displayed frames; a frame over 25 ms is a hitch.
@MainActor
final class PerfProbe: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var frames: [Double] = []
    private var onTick: (() -> Void)?
    private let log: String
    private static var current: PerfProbe?

    init(log: String) { self.log = log }

    static func start(log: String) {
        let probe = PerfProbe(log: log)
        current = probe
        Task { @MainActor in await probe.run() }
    }

    private func write(_ line: String) { SimulatedDrop.append(line + "\n", to: log) }

    private func record(on view: NSView, seconds: Double, tick: (() -> Void)? = nil) async -> [Double] {
        frames = []
        last = 0
        onTick = tick
        let link = view.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        try? await Task.sleep(for: .seconds(seconds))
        link.invalidate()
        self.link = nil
        return frames
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if last > 0 { frames.append((now - last) * 1000) }
        last = now
        onTick?()
    }

    private func summary(_ name: String, _ frames: [Double]) {
        guard !frames.isEmpty else { write("\(name): no frames"); return }
        let sorted = frames.sorted()
        let hitches = frames.filter { $0 > 25 }
        let over8 = frames.filter { $0 > 8.3 }.count
        write(String(format: "%@: %d frames, median %.1f ms, p95 %.1f ms, max %.1f ms, hitches %d (%.0f ms lost), over 8.3 ms %d",
                     name, frames.count, sorted[sorted.count / 2], sorted[Int(Double(sorted.count) * 0.95)], sorted.last!,
                     hitches.count, hitches.reduce(0) { $0 + $1 - 16.7 }, over8))
    }

    private func run() async {
        try? await Task.sleep(for: .seconds(3))
        guard let library = AppDelegate.shared.libraryWindowController, let window = library.window,
              let content = window.contentView else { write("no library window"); return }
        let split = library.splitViewController
        // `-FolioPerfGhost YES`: on screen but practically invisible (1 % opacity, no shadow, mouse passes through,
        // never key), so WindowServer composites it and render costs show.
        if UserDefaults.standard.bool(forKey: "FolioPerfGhost") {
            window.alphaValue = 0.01
            window.hasShadow = false
            window.ignoresMouseEvents = true
            window.level = .floating
            window.orderFrontRegardless()
            try? await Task.sleep(for: .seconds(1))
        }
        write("ghost \(UserDefaults.standard.bool(forKey: "FolioPerfGhost")), arrangesAllSubviews \(split.splitView.arrangesAllSubviews), subviews \(split.splitView.subviews.count), arranged \(split.splitView.arrangedSubviews.count), occlusion visible \(window.occlusionState.contains(.visible))")
        // As in real use: a paper is selected (menu and toolbar validation depend on it).
        if let id = AppDelegate.shared.model.rows.first(where: { AppDelegate.shared.model.snapshot.items[$0]?.kind == .regular }) {
            AppDelegate.shared.model.selectedItemIDs = [id]
            try? await Task.sleep(for: .seconds(0.5))
        }
        let rounds = UserDefaults.standard.object(forKey: "FolioPerfProbeRounds") == nil ? 3 : UserDefaults.standard.integer(forKey: "FolioPerfProbeRounds")
        for round in 0..<rounds {
            for (name, item) in [("sidebar", split.splitViewItems.first!), ("inspector", split.splitViewItems.last!)] {
                var widths: [Int] = []
                let dump = UserDefaults.standard.string(forKey: "FolioPerfDumpFrames")
                var dumped = 0
                let frames = await record(on: content, seconds: 0.7) {
                    // The window's own layers, as composed by the app (glass and desktop blur are WindowServer's and
                    // do not show): what a frame of the slide is made of.
                    if let dump, round == 0, name == "sidebar", self.frames.count >= 2, dumped < 12,
                       let root = content.superview, let layer = root.layer {
                        let scale: CGFloat = 0.5
                        let size = root.bounds.size
                        if let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                                   bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                            context.setFillColor(CGColor(red: 1, green: 0, blue: 1, alpha: 1))
                            context.fill(CGRect(origin: .zero, size: CGSize(width: size.width * scale, height: size.height * scale)))
                            context.scaleBy(x: scale, y: scale)
                            (layer.presentation() ?? layer).render(in: context)
                            if let image = context.makeImage() {
                                let rep = NSBitmapImageRep(cgImage: image)
                                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dump + "-\(dumped).png"))
                            }
                        }
                        dumped += 1
                    }
                    let middle = split.splitView.arrangedSubviews[1]
                    widths.append(Int(middle.frame.minX) * 10000 + Int(split.sidebarUnderlay.isHidden ? 9999 : split.sidebarUnderlay.frame.width))
                    if self.frames.count == 2 {
                        let start = CACurrentMediaTime()
                        split.setCollapsed(item, !item.isCollapsed)
                        let call = (CACurrentMediaTime() - start) * 1000
                        window.contentView?.layoutSubtreeIfNeeded()
                        let layout = (CACurrentMediaTime() - start) * 1000 - call
                        window.displayIfNeeded()
                        let display = (CACurrentMediaTime() - start) * 1000 - call - layout
                        self.write(String(format: "   start: call %.1f ms, layout %.1f ms, display %.1f ms", call, layout, display))
                    }
                }
                summary("\(name) toggle \(round + 1)", Array(frames.prefix(24)))
                write("   widths " + widths.prefix(24).map(String.init).joined(separator: " "))
                write("   " + frames.prefix(24).map { String(format: "%.0f", $0) }.joined(separator: " "))
            }
        }
        // The inspector: a paper's information, scrolled.
        if let id = AppDelegate.shared.model.rows.first(where: { AppDelegate.shared.model.snapshot.items[$0]?.kind == .regular }) {
            AppDelegate.shared.model.selectedItemIDs = [id]
            AppDelegate.shared.model.inspectorTab = .metadata
            split.showInspector()
            try? await Task.sleep(for: .seconds(1.5))
            let inspectorView = split.splitViewItems.last!.viewController.view
            if let scroll = Self.scrollViews(in: inspectorView).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }) {
                await scrollTest("inspector", scroll: scroll, root: content)
            } else { write("inspector: no scroll view") }
        }
        if UserDefaults.standard.bool(forKey: "FolioPerfProbeSkipSettings") { write("done"); return }
        AppDelegate.shared.showSettings(nil)
        try? await Task.sleep(for: .seconds(1))
        guard let settings = AppDelegate.shared.settingsWindow else { write("no settings window"); return }
        ghost(settings.window)
        for pane in SettingsPane.allCases {
            settings.select(pane: pane.title)
            try? await Task.sleep(for: .seconds(1.2))
            guard let root = settings.window?.contentView,
                  let scroll = Self.scrollViews(in: root).max(by: { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }) else { continue }
            await scrollTest("settings \(pane.rawValue)", scroll: scroll, root: root)
        }
        write("done")
    }

    private func scrollTest(_ name: String, scroll: NSScrollView, root: NSView) async {
        let clip = scroll.contentView
        var direction: CGFloat = 1
        var work: [Double] = []
        let frames = await record(on: root, seconds: 2.5) {
            let start = CACurrentMediaTime()
            let maxY = max((scroll.documentView?.frame.height ?? 0) - clip.bounds.height, 0)
            var y = clip.bounds.origin.y + 24 * direction
            if y >= maxY { y = maxY; direction = -1 } else if y <= 0 { y = 0; direction = 1 }
            clip.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(clip)
            root.layoutSubtreeIfNeeded()
            root.displayIfNeeded()
            CATransaction.flush()
            work.append((CACurrentMediaTime() - start) * 1000)
        }
        summary("\(name) scroll (height \(Int(scroll.documentView?.frame.height ?? 0)))", frames)
        summary("   work per step", work)
    }

    private func ghost(_ window: NSWindow?) {
        guard UserDefaults.standard.bool(forKey: "FolioPerfGhost"), let window else { return }
        window.alphaValue = 0.01
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .floating
        window.orderFrontRegardless()
    }

    static func scrollViews(in view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(scrollViews)
    }
}
