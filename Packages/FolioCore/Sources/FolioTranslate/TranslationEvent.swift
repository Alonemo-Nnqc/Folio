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

/// What the stages of a translation are called. Views reserve room for the widest, so nothing moves as the count goes up.
public enum TranslationStageText {
    public static func paragraphs(done: Int, total: Int) -> String {
        String(localized: "翻译段落 \(done)/\(total)", bundle: .module)
    }

    public static var layout: String { String(localized: "排版译文", bundle: .module) }

    /// The stages' widest forms.
    public static var widest: [String] { [paragraphs(done: 888, total: 888), layout] }
}
