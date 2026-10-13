import AppKit
import SafariServices

/// The browsers Folio's extension can be installed in, and how (WEB-05).
struct BrowserInfo: Identifiable, Hashable {
    enum Family: String { case safari, chromium, firefox }

    let id: String
    let name: String
    let family: Family
    let appURL: URL
    /// The browser's extensions page, opened after preparing the extension folder.
    let extensionsPage: String?
    /// Where the browser keeps its profiles (relative to ~/Library/Application Support), to tell
    /// whether the unpacked extension has been loaded.
    let profileFolder: String?
}

enum BrowserExtensions {
    nonisolated static let safariExtensionIdentifier = "com.nnqc.Folio.SafariExtension"
    /// Fixed by the `key` in the Chromium manifest, whatever folder the extension is loaded from.
    static let chromiumExtensionID = "ljlmdoodaogoghgikjgdbpigeamnjejd"

    /// The version of the extension inside this Folio.app (the popup asks for a reload when it is older).
    static var bundledVersion: String? {
        guard let url = Bundle.main.url(forResource: "BrowserExtension", withExtension: nil)?.appending(path: "chromium/manifest.json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return manifest["version"] as? String
    }

    enum InstallState: Equatable {
        case notInstalled
        case installed(enabled: Bool, version: String?)
    }

    private static let known: [(id: String, name: String, bundle: String, family: BrowserInfo.Family, page: String?, profiles: String?)] = [
        ("safari", "Safari", "Safari.app", .safari, nil, nil),
        ("chrome", "Google Chrome", "Google Chrome.app", .chromium, "chrome://extensions", "Google/Chrome"),
        ("edge", "Microsoft Edge", "Microsoft Edge.app", .chromium, "edge://extensions", "Microsoft Edge"),
        ("brave", "Brave", "Brave Browser.app", .chromium, "brave://extensions", "BraveSoftware/Brave-Browser"),
        ("arc", "Arc", "Arc.app", .chromium, "arc://extensions", "Arc/User Data"),
        ("vivaldi", "Vivaldi", "Vivaldi.app", .chromium, "vivaldi://extensions", "Vivaldi"),
        ("opera", "Opera", "Opera.app", .chromium, "opera://extensions", "com.operasoftware.Opera"),
        ("chromium", "Chromium", "Chromium.app", .chromium, "chrome://extensions", "Chromium"),
        ("firefox", "Firefox", "Firefox.app", .firefox, "about:debugging#/runtime/this-firefox", nil),
    ]

    /// Browsers installed on this Mac (Safari always is).
    static func detect() -> [BrowserInfo] {
        let folders = [URL(filePath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications"),
                       URL(filePath: "/System/Volumes/Preboot/Cryptexes/App/System/Applications")]
        return known.compactMap { entry in
            let app = folders.map { $0.appending(path: entry.bundle) }.first { FileManager.default.fileExists(atPath: $0.path) }
                ?? (entry.family == .safari ? URL(filePath: "/Applications/Safari.app") : nil)
            guard let app else { return nil }
            return BrowserInfo(id: entry.id, name: entry.name, family: entry.family, appURL: app,
                               extensionsPage: entry.page, profileFolder: entry.profiles)
        }
    }

    // MARK: Chromium / Firefox: an unpacked copy in a stable place

    static var installRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/Folio/BrowserExtension")
    }

    static func folder(for family: BrowserInfo.Family) -> URL { installRoot.appending(path: family.rawValue) }

    /// Copies the extension (shared files + the family's manifest) out of Folio.app.
    @discardableResult
    static func prepareCopy(for family: BrowserInfo.Family) throws -> URL {
        guard let source = Bundle.main.url(forResource: "BrowserExtension", withExtension: nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let target = folder(for: family)
        let staging = installRoot.appending(path: ".\(family.rawValue)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        for file in try FileManager.default.contentsOfDirectory(at: source.appending(path: "shared"), includingPropertiesForKeys: nil) {
            try FileManager.default.copyItem(at: file, to: staging.appending(path: file.lastPathComponent))
        }
        try FileManager.default.copyItem(at: source.appending(path: "\(family.rawValue)/manifest.json"),
                                         to: staging.appending(path: "manifest.json"))
        // Swap in place so the folder the browser loaded keeps its path.
        if FileManager.default.fileExists(atPath: target.path) {
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staging)
        } else {
            try FileManager.default.moveItem(at: staging, to: target)
        }
        return target
    }

    /// At launch: refresh copies made earlier, so browsers pick up the new extension on their next start.
    static func refreshInstalledCopy() {
        for family in [BrowserInfo.Family.chromium, .firefox] where FileManager.default.fileExists(atPath: folder(for: family).path) {
            try? prepareCopy(for: family)
        }
    }

    /// Whether a Chromium browser has Folio's extension, read from its profiles' preferences (where
    /// Chrome records every extension under `extensions.settings.<id>`).
    static func installState(in browser: BrowserInfo) -> InstallState {
        guard browser.family == .chromium, let profiles = browser.profileFolder else { return .notInstalled }
        let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support/\(profiles)")
        guard let entries = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return .notInstalled }
        var best = InstallState.notInstalled
        let profileFolders = [root] + entries.filter { $0.lastPathComponent == "Default" || $0.lastPathComponent.hasPrefix("Profile") }
        for profile in profileFolders {
            for name in ["Secure Preferences", "Preferences"] {
                guard let data = FileManager.default.contents(atPath: profile.appending(path: name).path),
                      data.range(of: Data(chromiumExtensionID.utf8)) != nil,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let settings = (json["extensions"] as? [String: Any])?["settings"] as? [String: Any],
                      let entry = settings[chromiumExtensionID] as? [String: Any] else { continue }
                let reasons = entry["disable_reasons"]
                let disabled = (reasons as? [Any]).map { !$0.isEmpty } ?? ((reasons as? Int).map { $0 != 0 } ?? false)
                    || (entry["state"] as? Int) == 0
                let version = (entry["manifest"] as? [String: Any])?["version"] as? String
                if !disabled { return .installed(enabled: true, version: version) }
                best = .installed(enabled: false, version: version)
            }
        }
        return best
    }

    static func isInstalled(in browser: BrowserInfo) -> Bool {
        if case .installed = installState(in: browser) { return true }
        return false
    }

    /// Opens the browser's extensions page. Chromium browsers may refuse internal pages opened from
    /// another app; the install guide then offers the address to paste.
    static func openExtensionsPage(of browser: BrowserInfo) {
        guard let page = browser.extensionsPage, let url = URL(string: page) else { return }
        NSWorkspace.shared.open([url], withApplicationAt: browser.appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Prepares the folder and copies its path (the guide then walks through loading it).
    static func prepareInstall(for browser: BrowserInfo) throws -> URL {
        let folder = try prepareCopy(for: browser.family)
        copyToPasteboard(folder.path)
        return folder
    }

    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    // MARK: Safari

    /// Whether Folio's Safari extension is enabled; nil when Safari cannot say.
    ///
    /// The SDK imports this completion handler as `@MainActor` (NS_SWIFT_UI_ACTOR), but SafariServices
    /// invokes it on an XPC queue, so Swift's isolation check traps. Calling the selector through the
    /// Objective-C runtime with a plain block sidesteps the bogus annotation.
    nonisolated static func safariState() async -> Bool? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool?, Never>) in
            let reply: @convention(block) @Sendable (SFSafariExtensionState?, NSError?) -> Void = { state, error in
                continuation.resume(returning: error == nil ? state?.isEnabled : nil)
            }
            let selector = NSSelectorFromString("getStateOfSafariExtensionWithIdentifier:completionHandler:")
            guard SFSafariExtensionManager.responds(to: selector) else { return continuation.resume(returning: nil) }
            _ = (SFSafariExtensionManager.self as AnyObject).perform(selector, with: "com.nnqc.Folio.SafariExtension", with: reply)
        }
    }

    /// Opens Safari's settings at Folio's extension; returns why it could not (Safari does not list the
    /// extension until unsigned extensions are allowed). Called through the Objective-C runtime for the
    /// same reason as `safariState()`.
    nonisolated static func openSafariSettings() async -> String? {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let reply: @convention(block) @Sendable (NSError?) -> Void = { error in
                continuation.resume(returning: error?.localizedDescription)
            }
            let selector = NSSelectorFromString("showPreferencesForExtensionWithIdentifier:completionHandler:")
            guard SFSafariApplication.responds(to: selector) else { return continuation.resume(returning: "无法打开 Safari 设置") }
            _ = (SFSafariApplication.self as AnyObject).perform(selector, with: safariExtensionIdentifier, with: reply)
        }
    }
}
