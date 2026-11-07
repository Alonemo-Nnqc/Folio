/// The rendered form of one or more citations.
///
/// `plainText` always holds one formatted entry per line. `html` is only
/// populated for styles that need inline formatting preserved (currently
/// APA, whose bibliography italicises journal/book titles).
public struct CitationOutput: Sendable, Equatable {
    public var plainText: String
    public var html: String?

    public init(plainText: String, html: String? = nil) {
        self.plainText = plainText
        self.html = html
    }
}
