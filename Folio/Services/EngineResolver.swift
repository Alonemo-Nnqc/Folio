import FolioCore
import FolioMetadata
import Foundation

/// Adapts `MetadataEngine` to the app's `MetadataResolving` seam.
struct EngineResolver: MetadataResolving {
    let engine: MetadataEngine

    init(mailto: String, openAlexAPIKey: String, useZoteroRecognizer: Bool = true) {
        var configuration = MetadataEngineConfiguration()
        configuration.useZoteroRecognizer = useZoteroRecognizer
        configuration.mailto = mailto.isEmpty ? nil : mailto
        configuration.openAlexAPIKey = openAlexAPIKey.isEmpty ? nil : openAlexAPIKey
        engine = MetadataEngine(configuration: configuration)
    }

    func resolvePDF(at url: URL) async -> RetrievalResult {
        Self.map(await engine.resolve(pdfAt: url))
    }

    func resolve(identifier: String) async -> RetrievalResult {
        Self.map(await engine.resolve(identifier: identifier))
    }

    func search(_ query: String) async -> [Metadata] {
        await engine.search(query: query)
    }

    private static func map(_ result: ResolveResult) -> RetrievalResult {
        switch result {
        case .found(let metadata): .found(metadata)
        case .notFound: .notFound
        case .networkError: .networkError
        }
    }
}
