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
            let base = file.translatedBy.flatMap { $0.isEmpty ? nil : "\(kindName(kind)) · \($0)" } ?? kindName(kind)
            // Two of the same kind by the same service and model: the time each was made tells them apart.
            let alike = files.filter { $0.id != file.id && $0.translationKind == kind && $0.translatedBy == file.translatedBy
                && $0.translationOf == file.translationOf }
            guard !alike.isEmpty else { return base }
            return "\(base) · \(madeAt(file, among: alike))"
        }
        return isOriginal(file, among: files, defaultFileId: defaultFileId)
            ? String(localized: "原文", bundle: .module) : file.fileName
    }

    /// A reader tab's name: what tells the papers and their translations apart when tabs are narrow, so the kind of
    /// translation comes first and the paper's short title last: SnakeSAM, 译文 · SnakeSAM, 译文 · Google · SnakeSAM.
    public static func tabTitle(of file: FileRecord, item: Item?, among files: [FileRecord]) -> String {
        let stem = (file.fileName as NSString).deletingPathExtension
        guard let item else { return stem }
        var paper = shortTitle(item.title)
        if item.kind != .regular || paper.isEmpty {
            let source = files.first { $0.id == file.translationOf } ?? file
            paper = (source.fileName as NSString).deletingPathExtension
        }
        if let kind = file.translationKind {
            let others = files.filter { $0.id != file.id && $0.translationKind == kind }
            return ([kindName(kind)] + differences(of: file, from: others) + [paper]).joined(separator: " · ")
        }
        return isOriginal(file, among: files, defaultFileId: item.defaultFileId) ? paper : stem
    }

    /// Only what tells a translation from the others of its kind: the service, the model within a service, or the time.
    private static func differences(of file: FileRecord, from others: [FileRecord]) -> [String] {
        func parts(_ file: FileRecord) -> (service: String, model: String) {
            let parts = (file.translatedBy ?? "").components(separatedBy: " · ")
            return (parts[0], parts.dropFirst().joined(separator: " · "))
        }
        let own = parts(file)
        let sameService = others.filter { parts($0).service == own.service }
        let sameModel = sameService.filter { parts($0).model == own.model }
        var result: [String] = []
        if sameService.count < others.count, !own.service.isEmpty { result.append(own.service) }
        if sameModel.count < sameService.count, !own.model.isEmpty { result.append(own.model) }
        if !sameModel.isEmpty { result.append(madeAt(file, among: sameModel)) }
        return result
    }

    private static func madeAt(_ file: FileRecord, among alike: [FileRecord]) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.setLocalizedDateFormatFromTemplate(alike.contains { abs($0.dateAdded.timeIntervalSince(file.dateAdded)) < 60 } ? "MMMd HH:mm:ss" : "MMMd HH:mm")
        return formatter.string(from: file.dateAdded)
    }

    /// The tab's tooltip: the whole title, then who and which file.
    public static func tabToolTip(of file: FileRecord, item: Item?, among files: [FileRecord]) -> String {
        guard let item else { return file.fileName }
        let citation = item.authors.first.map { [$0.family, item.year.map(String.init)].compactMap { $0 }.joined(separator: " ") }
        let details = [citation, title(of: file, among: files, defaultFileId: item.defaultFileId)].compactMap { $0 }
        return "\(item.title)\n\(details.joined(separator: " · "))"
    }

    /// A paper's name before its subtitle ("SnakeSAM: A topology-preserving…" is SnakeSAM), or the whole title.
    public static func shortTitle(_ title: String) -> String {
        let whole = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let colon = whole.indices.first { index in
            if whole[index] == "：" { return true }
            guard whole[index] == ":" else { return false }
            let next = whole.index(after: index)
            return next == whole.endIndex || whole[next].isWhitespace
        }
        guard let colon else { return whole }
        let head = whole[..<colon].trimmingCharacters(in: .whitespaces)
        let rest = whole[whole.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        return (2...40).contains(head.count) && !rest.isEmpty ? head : whole
    }

    /// The paper's own PDF: the one its translations were made from, its only PDF, or (among several) the default.
    static func isOriginal(_ file: FileRecord, among files: [FileRecord], defaultFileId: String?) -> Bool {
        guard file.isPDF else { return false }
        if files.contains(where: { $0.translationOf == file.id }) { return true }
        let pdfs = files.filter { $0.isPDF && $0.translationKind == nil }
        return pdfs.count == 1 || file.id == defaultFileId
    }
}
