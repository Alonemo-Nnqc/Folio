import FolioCore

/// Builds a `Metadata` value from one regular item's raw field/creator data.
enum ZoteroMetadataBuilder {
    static func build(itemTypeName: String, fields: [String: String], creators: [RawCreator]) -> Metadata {
        let type = ZoteroItemTypeMapping.map(itemTypeName)
        var metadata = Metadata(title: fields["title"] ?? "")
        metadata.type = type
        metadata.authors = ZoteroCreatorMapping.authors(from: creators)
        if let dateRaw = fields["date"] {
            let parsed = ZoteroDate.parseFieldValue(dateRaw)
            metadata.year = parsed.year
            metadata.date = parsed.normalized
        }
        metadata.source = ZoteroFieldMapping.source(fields: fields, type: type)
        metadata.volume = fields["volume"]
        metadata.issue = fields["issue"]
        metadata.pages = fields["pages"]
        metadata.publisher = fields["publisher"]
        metadata.doi = ZoteroFieldMapping.doi(from: fields["DOI"])
        metadata.arxivId = ZoteroFieldMapping.arxivID(archiveID: fields["archiveID"], extra: fields["extra"], url: fields["url"])
        metadata.isbn = fields["ISBN"]
        metadata.url = fields["url"]
        metadata.abstract = fields["abstractNote"]
        return metadata
    }
}
