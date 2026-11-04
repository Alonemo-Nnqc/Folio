import FolioCore

/// Outcome of a metadata lookup.
public enum ResolveResult: Sendable, Equatable {
    /// A trustworthy match was found.
    case found(Metadata)
    /// The sources answered, but nothing matched well enough. Retrying will not help.
    case notFound
    /// No source could be reached (offline, DNS, timeouts, overloaded servers). Worth retrying later.
    case networkError
}
