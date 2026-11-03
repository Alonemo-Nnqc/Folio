import Foundation

/// What Folio shows for a file under its paper, instead of the file name (which starts with the paper's
/// author, year and title): 原文, 双语对照 · Google, 译文 · DeepSeek · deepseek-chat. Other files — a
/// supplement, a second version — keep their own names.
public enum FileLabel {
    public static func kindName(_ kind: TranslationKind) -> String {
        switch kind {
        case .mono: String(localized: "译文", bundle: .module)
        case .dual: String(localized: "双语对照", bundle: .module)
        }
    }

    /// `files` are all the files of the paper, `defaultFileId` its default one.
    public static func title(of file: FileRecord, among files: [FileRecord], defaultFileId: String?) -> String {
        if let kind = file.translationKind {
            guard let by = file.translatedBy, !by.isEmpty else { return kindName(kind) }
            return "\(kindName(kind)) · \(by)"
        }
        return isOriginal(file, among: files, defaultFileId: defaultFileId)
            ? String(localized: "原文", bundle: .module) : file.fileName
    }

    /// The paper's own PDF: the one its translations were made from, its only PDF, or (among several) the default.
    static func isOriginal(_ file: FileRecord, among files: [FileRecord], defaultFileId: String?) -> Bool {
        guard file.isPDF else { return false }
        if files.contains(where: { $0.translationOf == file.id }) { return true }
        let pdfs = files.filter { $0.isPDF && $0.translationKind == nil }
        return pdfs.count == 1 || file.id == defaultFileId
    }
}
