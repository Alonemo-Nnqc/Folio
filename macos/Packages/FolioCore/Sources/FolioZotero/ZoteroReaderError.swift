import Foundation

/// Errors thrown while locating or reading a Zotero library.
public enum ZoteroReaderError: Error, Sendable, Equatable {
    /// `dataDirectory` does not contain a `zotero.sqlite` file.
    case sourceDatabaseNotFound(URL)
    /// The copied database has no `libraries` row of type `user`.
    case userLibraryNotFound
}
