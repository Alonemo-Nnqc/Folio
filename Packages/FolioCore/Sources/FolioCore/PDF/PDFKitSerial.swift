import Foundation

/// PDFKit's text extraction is not safe to run on several threads at once: concurrent
/// `PDFPage.attributedString` calls crash inside PDFKit (an NSDictionary insert with a nil key in
/// its font-attribute cache). Background readers — retrieval (up to 4 at once), the recognizer
/// payload, full-text indexing, annotation summaries — take turns through this lock.
public enum PDFKitSerial {
    private static let lock = NSRecursiveLock()

    public static func run<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
