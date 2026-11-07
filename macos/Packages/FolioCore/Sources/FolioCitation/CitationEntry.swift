import FolioCore

/// One bibliographic record to render: the item's stable identifier, its
/// (editable) BibTeX-style citation key, and the metadata to format.
public struct CitationEntry: Sendable {
    public var id: String
    public var citationKey: String
    public var metadata: Metadata

    public init(id: String, citationKey: String, metadata: Metadata) {
        self.id = id
        self.citationKey = citationKey
        self.metadata = metadata
    }
}
