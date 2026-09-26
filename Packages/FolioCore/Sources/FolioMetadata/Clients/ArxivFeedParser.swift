import Foundation

/// Parses the Atom feed returned by `export.arxiv.org/api/query`.
final class ArxivFeedParser: NSObject, XMLParserDelegate {
    struct Entry: Equatable {
        var id = ""
        var title = ""
        var summary = ""
        var published = ""
        var authors: [String] = []
        var doi: String?
        var journalReference: String?
    }

    private var entries: [Entry] = []
    private var current: Entry?
    private var text = ""
    private var inAuthor = false

    /// Throws when the data is not well-formed XML.
    static func parse(_ data: Data) throws -> [Entry] {
        let delegate = ArxivFeedParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false
        guard parser.parse() else {
            throw parser.parserError ?? CocoaError(.coderReadCorrupt)
        }
        return delegate.entries
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        switch elementName {
        case "entry": current = Entry()
        case "author": inAuthor = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        guard current != nil else { return }
        switch elementName {
        case "id": current?.id = value
        case "title": current?.title = value
        case "summary": current?.summary = value
        case "published": current?.published = value
        case "name" where inAuthor: current?.authors.append(value)
        case "author": inAuthor = false
        case "arxiv:doi": current?.doi = value
        case "arxiv:journal_ref": current?.journalReference = value
        case "entry":
            if let entry = current { entries.append(entry) }
            current = nil
        default: break
        }
    }
}
