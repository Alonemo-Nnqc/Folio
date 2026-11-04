/// Options controlling what `ZoteroReader` includes when reading a library.
public struct ZoteroReadOptions: Sendable {
    /// Zotero's automatically generated tags (`itemTags.type == 1`): publisher/database
    /// keywords and arXiv categories. Off by default (ZOT-02).
    public var includeAutomaticTags = false

    public init() {}
}

/// Counts produced by `ZoteroReader.probe()` and `ZoteroReader.read(options:)`, used to show
/// an import summary (ZOT-05).
public struct ZoteroReadReport: Sendable, Equatable {
    public var regularItems = 0
    public var standaloneFiles = 0
    public var collections = 0
    public var tags = 0
    /// Distinct automatic tag names available library-wide, regardless of
    /// `includeAutomaticTags` — used to label the import sheet's toggle.
    public var automaticTagsAvailable = 0
    public var skippedNotes = 0
    public var skippedSnapshots = 0
    public var skippedLinks = 0
    public var skippedTrashed = 0
    public var skippedAnnotations = 0

    public init() {}
}
