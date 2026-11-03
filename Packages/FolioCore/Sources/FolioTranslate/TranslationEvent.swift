import Foundation

/// Progress of one translation job.
public enum TranslationEvent: Sendable, Hashable {
    /// What the engine is doing, in the user's language ("翻译段落 34/120").
    case stage(String)
    /// Overall progress, 0…1, monotonically non-decreasing.
    case progress(Double)
    /// A translated PDF of the pages done so far (the rest still in the original), to read while the
    /// translation goes on. A new file each time; earlier ones may be deleted.
    case preview(URL)
    case finished(mono: URL?, dual: URL?)
    case failed(message: String, logURL: URL)
    case cancelled
}
