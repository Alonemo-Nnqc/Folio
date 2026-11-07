import FolioCore
import Foundation

enum RetrievalResult: Sendable, Equatable {
    case found(Metadata)
    case notFound
    case networkError
}

/// The slice of the metadata engine the app depends on; lets the UI run before the engine is wired in.
protocol MetadataResolving: Sendable {
    func resolvePDF(at url: URL) async -> RetrievalResult
    func resolve(identifier: String) async -> RetrievalResult
    func search(_ query: String) async -> [Metadata]
}

struct UnavailableResolver: MetadataResolving {
    func resolvePDF(at url: URL) async -> RetrievalResult { .notFound }
    func resolve(identifier: String) async -> RetrievalResult { .notFound }
    func search(_ query: String) async -> [Metadata] { [] }
}
