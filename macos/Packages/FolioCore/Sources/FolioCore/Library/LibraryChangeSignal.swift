import Foundation

/// Cross-process "the library changed" signal. GRDB observation only sees writes made through the
/// app's own connection, so the helper used by AI agents (folio-cli) posts this after writing and the
/// app reloads its snapshot.
public enum LibraryChangeSignal {
    public static let name = Notification.Name("com.nnqc.Folio.libraryDidChange")

    /// `root` identifies the library, so a test library never refreshes the user's app.
    public static func post(root: URL) {
        DistributedNotificationCenter.default().postNotificationName(
            name, object: root.standardizedFileURL.path, userInfo: nil, deliverImmediately: true)
    }
}
