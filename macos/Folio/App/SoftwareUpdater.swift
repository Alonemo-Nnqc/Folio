import Foundation
import Observation
import Sparkle

/// In-app updates through Sparkle. The feed is the `appcast.xml` attached to the newest GitHub release
/// (`SUFeedURL` in Info.plist); every archive is verified against `SUPublicEDKey` before it is installed.
/// Sparkle's standard windows handle the rest: release notes, download progress, "安装并重新启动".
///
///   -FolioUpdateFeedURL <url>   reads the feed from another address (testing a release locally)
@Observable
final class SoftwareUpdater: NSObject, SPUUpdaterDelegate {
    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var observation: NSKeyValueObservation?
    private(set) var canCheckForUpdates = false

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        // UI tests and screenshot runs never talk to the update server, unless they test an update feed.
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "FolioUITesting") || defaults.string(forKey: "FolioUpdateFeedURL") != nil else { return }
        controller.startUpdater()
        observation = updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
    }

    private var updater: SPUUpdater { controller.updater }

    /// Stored by Sparkle in the app's defaults (`SUEnableAutomaticChecks`).
    var automaticallyChecks: Bool {
        get { access(keyPath: \.automaticallyChecks); return updater.automaticallyChecksForUpdates }
        set { withMutation(keyPath: \.automaticallyChecks) { updater.automaticallyChecksForUpdates = newValue } }
    }

    /// Downloads in the background and installs when Folio quits (`SUAutomaticallyUpdate`).
    var automaticallyDownloads: Bool {
        get { access(keyPath: \.automaticallyDownloads); return updater.automaticallyDownloadsUpdates }
        set { withMutation(keyPath: \.automaticallyDownloads) { updater.automaticallyDownloadsUpdates = newValue } }
    }

    var lastCheck: Date? { updater.lastUpdateCheckDate }

    /// "1.2.0 (148)"
    static var versionDescription: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    @objc func checkForUpdates(_ sender: Any?) {
        controller.checkForUpdates(sender)
    }

    // MARK: SPUUpdaterDelegate

    func feedURLString(for updater: SPUUpdater) -> String? {
        UserDefaults.standard.string(forKey: "FolioUpdateFeedURL")
    }

    /// Development builds only check when asked, so they don't keep offering the published release.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        #if DEBUG
        if updateCheck != .updates, UserDefaults.standard.string(forKey: "FolioUpdateFeedURL") == nil {
            throw NSError(domain: "com.nnqc.Folio.update", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: String(localized: "开发版本不自动检查更新")])
        }
        #endif
    }
}
